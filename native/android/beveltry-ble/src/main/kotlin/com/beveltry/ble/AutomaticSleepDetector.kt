package com.beveltry.ble

import android.content.Context
import android.util.Log
import java.util.concurrent.atomic.AtomicLong

/**
 * Rivelatore sperimentale continuo del ciclo sonno/veglia per Beveltry Always-On (Task 08D).
 *
 * Basato esclusivamente sui segnali cardiaci reali (HR a 1Hz e intervalli R-R)
 * memorizzati in SQLite. Non richiede alcun intervento o pressione manuale da parte dell'utente.
 *
 * REGOLE ARCHITETTURALI INVIOLABILI:
 * 1. Non confonde un'interruzione BLE o un gap con un risveglio (un gap mantiene lo stato).
 * 2. Non confonde una pausa di registrazione con la fine del sonno.
 * 3. Non termina una notte dopo una singola epoca Wake (isteresi e finestra di conferma).
 * 4. Se l'utente torna a dormire, conserva la medesima sessione e contabilizza l'intervallo come WASO.
 * 5. All'accertamento del risveglio finale (FINAL_WAKE_CONFIRMED), accoda un lavoro univoco
 *    WorkManager (SleepAnalysisWorker) senza bloccare il recorder BLE.
 */
class AutomaticSleepDetector(
    private val context: Context,
    private val storageEngine: WhoopStorageEngine,
    val nightKey: String,
    val sessionId: String,
    initialState: NightState = NightState.NO_NIGHT,
    private val onStateChange: (NightState) -> Unit = {},
) {
    companion object {
        private const val TAG = "AutomaticSleepDetector"
        const val ALGORITHM_VERSION = "1.0.0-cardiac-only"

        // Soglie temporali di isteresi (in millisecondi)
        const val SLEEP_ONSET_CONFIRMATION_MS = 20 * 60 * 1000L   // 20 minuti di calma per confermare addormentamento
        const val BRIEF_WAKE_THRESHOLD_MS = 30 * 60 * 1000L       // fino a 30 minuti di veglia considerata WASO interna
        const val FINAL_WAKE_CONFIRMATION_MS = 20 * 60 * 1000L    // 20 minuti di veglia continuata per confermare risveglio finale
        const val MINIMUM_SLEEP_FOR_FINAL_WAKE_MS = 60 * 60 * 1000L // Minimo 1h di sonno per poter considerare un risveglio finale
    }

    val stateMachine = NightStateMachine(
        initialState = initialState,
        onTransition = { from, to, event ->
            persistState(to, event)
            onStateChange(to)
        }
    )

    val currentState: NightState
        get() = stateMachine.currentState

    var candidateOnsetUtc: Long? = null
        private set
    var candidateOffsetUtc: Long? = null
        private set
    var baselineHrBpm: Double = 58.0
        private set
    var lastSampleTimestampUtc: Long = 0L
        private set

    private var lowHrRunStartUtc: Long? = null
    private var highHrRunStartUtc: Long? = null
    private var sleepOnsetTimestampUtc: Long? = null
    private var totalWasoMs: Long = 0L
    private var lastWakeStartUtc: Long? = null

    init {
        // Recupera eventuale stato salvato dal DB
        val existing = storageEngine.getNightProcessing(nightKey)
        if (existing != null) {
            candidateOnsetUtc = existing["candidateOnset"] as? Long
            candidateOffsetUtc = existing["candidateOffset"] as? Long
        }
    }

    /**
     * Valuta un campione HR valido notificato a 1Hz.
     */
    fun onSampleReceived(timestampUtc: Long, hrBpm: Int) {
        lastSampleTimestampUtc = timestampUtc

        // Aggiorna baseline stima adattiva
        if (hrBpm in 35..120) {
            baselineHrBpm = (baselineHrBpm * 0.995) + (hrBpm * 0.005)
        }

        val isCalm = hrBpm <= (baselineHrBpm + 8.0)
        val isElevated = hrBpm >= (baselineHrBpm + 14.0)

        when (currentState) {
            NightState.NO_NIGHT -> {
                if (isCalm) {
                    if (lowHrRunStartUtc == null) lowHrRunStartUtc = timestampUtc
                    val runDuration = timestampUtc - lowHrRunStartUtc!!
                    if (runDuration >= 15 * 60 * 1000L) { // 15 min calmi
                        candidateOnsetUtc = lowHrRunStartUtc
                        stateMachine.transition(NightEvent.RestingDetected(timestampUtc))
                    }
                } else {
                    lowHrRunStartUtc = null
                }
            }

            NightState.SLEEP_CANDIDATE -> {
                if (isCalm) {
                    val runDuration = timestampUtc - (lowHrRunStartUtc ?: timestampUtc)
                    if (runDuration >= SLEEP_ONSET_CONFIRMATION_MS) {
                        sleepOnsetTimestampUtc = candidateOnsetUtc ?: lowHrRunStartUtc ?: timestampUtc
                        stateMachine.transition(NightEvent.SleepOnsetConfirmed(timestampUtc))
                    }
                } else if (isElevated) {
                    // Falso allarme pre-sonno, utente si è riattivato
                    lowHrRunStartUtc = null
                    stateMachine.transition(NightEvent.WakeProlonged(timestampUtc, "Attività elevata durante candidate"))
                }
            }

            NightState.SLEEP_ACTIVE -> {
                if (isElevated) {
                    if (highHrRunStartUtc == null) highHrRunStartUtc = timestampUtc
                    val elevatedDuration = timestampUtc - highHrRunStartUtc!!
                    if (elevatedDuration >= 3 * 60 * 1000L) { // 3 min elevati
                        lastWakeStartUtc = highHrRunStartUtc
                        stateMachine.transition(NightEvent.WakeWithinSleep(timestampUtc))
                    }
                } else {
                    highHrRunStartUtc = null
                }
            }

            NightState.WAKE_WITHIN_SLEEP -> {
                if (isCalm) {
                    // L'utente torna a dormire! Accumula WASO e ripristina SLEEP_ACTIVE
                    val wakeDur = timestampUtc - (lastWakeStartUtc ?: timestampUtc)
                    totalWasoMs += wakeDur
                    highHrRunStartUtc = null
                    stateMachine.transition(NightEvent.ReturnToSleep(timestampUtc))
                } else {
                    val wakeDuration = timestampUtc - (lastWakeStartUtc ?: timestampUtc)
                    val timeAsleep = timestampUtc - (sleepOnsetTimestampUtc ?: timestampUtc)

                    // Se la veglia dura più della soglia breve (> 30 min) e abbiamo dormito a sufficienza
                    if (wakeDuration >= BRIEF_WAKE_THRESHOLD_MS && timeAsleep >= MINIMUM_SLEEP_FOR_FINAL_WAKE_MS) {
                        candidateOffsetUtc = lastWakeStartUtc ?: timestampUtc
                        stateMachine.transition(NightEvent.WakeProlonged(timestampUtc))
                    }
                }
            }

            NightState.FINAL_WAKE_CANDIDATE -> {
                if (isCalm) {
                    // L'utente si è riaddormentato durante la finestra di conferma!
                    // Conserva la stessa sessione e contabilizza come WASO
                    val wakeDur = timestampUtc - (candidateOffsetUtc ?: timestampUtc)
                    totalWasoMs += wakeDur
                    highHrRunStartUtc = null
                    stateMachine.transition(NightEvent.ReturnToSleep(timestampUtc))
                } else {
                    val candOffset = candidateOffsetUtc ?: timestampUtc
                    val confirmationElapsed = timestampUtc - candOffset
                    if (confirmationElapsed >= FINAL_WAKE_CONFIRMATION_MS) {
                        // Risveglio finale confermato!
                        stateMachine.transition(NightEvent.FinalWakeConfirmed(timestampUtc))
                        triggerAutomaticProcessing(timestampUtc)
                    }
                }
            }

            NightState.FINAL_WAKE_CONFIRMED -> {
                // Già confermato, transiziona a PROCESS_PENDING se non ancora fatto
                triggerAutomaticProcessing(timestampUtc)
            }

            NightState.PROCESS_PENDING, NightState.PROCESSING, NightState.REPORT_READY, NightState.PROCESS_FAILED -> {
                // Stati gestiti dal Worker / processing downstream
            }
        }
    }

    /**
     * Gestisce un gap o interruzione Bluetooth.
     * REQUISITO INVIOLABILE: un'interruzione BLE NON deve essere confusa con un risveglio!
     */
    fun onBluetoothGap(durationMs: Long) {
        Log.i(TAG, "Gap BLE rilevato ($durationMs ms). Nessun cambio verso Wake.")
        stateMachine.transition(NightEvent.BluetoothGap(durationMs))
    }

    /**
     * Forza o attiva l'elaborazione automatica della notte accodando Unique WorkManager.
     */
    fun triggerAutomaticProcessing(timestampUtc: Long) {
        if (stateMachine.transition(NightEvent.EnqueueProcessing(timestampUtc)) || currentState == NightState.PROCESS_PENDING) {
            Log.i(TAG, "Accodamento lavoro WorkManager per notte: $nightKey (session=$sessionId)")
            SleepAnalysisWorker.enqueue(context, nightKey, sessionId)
        }
    }

    private fun persistState(newState: NightState, event: NightEvent) {
        val reason = when (event) {
            is NightEvent.RestingDetected -> event.reason
            is NightEvent.SleepOnsetConfirmed -> event.reason
            is NightEvent.WakeWithinSleep -> event.reason
            is NightEvent.ReturnToSleep -> event.reason
            is NightEvent.WakeProlonged -> event.reason
            is NightEvent.FinalWakeConfirmed -> event.reason
            is NightEvent.ProcessingFailed -> "Errore: ${event.errorCode} - ${event.reason}"
            is NightEvent.ReprocessRequested -> event.reason
            else -> "Transizione a ${newState.name}"
        }

        val errCode = if (event is NightEvent.ProcessingFailed) event.errorCode else null
        val conf = when (newState) {
            NightState.REPORT_READY -> 0.95
            NightState.FINAL_WAKE_CONFIRMED, NightState.PROCESS_PENDING -> 0.90
            NightState.SLEEP_ACTIVE -> 0.85
            NightState.SLEEP_CANDIDATE, NightState.FINAL_WAKE_CANDIDATE -> 0.65
            else -> 0.50
        }

        storageEngine.saveNightProcessingState(
            nightKey = nightKey,
            sessionId = sessionId,
            state = newState.name,
            candidateOnset = candidateOnsetUtc,
            candidateOffset = candidateOffsetUtc,
            algorithmVersion = ALGORITHM_VERSION,
            errorCode = errCode,
            confidence = conf,
            decisionReason = reason
        )
    }
}
