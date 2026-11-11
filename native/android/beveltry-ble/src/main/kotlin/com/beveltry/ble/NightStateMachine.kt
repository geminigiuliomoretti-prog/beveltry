package com.beveltry.ble

import android.util.Log

/**
 * Stati formali del ciclo di vita del sonno notturno (Task 08D).
 *
 * Rispetta l'architettura a stati descritta nel documento tecnico
 * «WHOOP Always On e automazione notturna».
 */
enum class NightState {
    NO_NIGHT,
    SLEEP_CANDIDATE,
    SLEEP_ACTIVE,
    WAKE_WITHIN_SLEEP,
    FINAL_WAKE_CANDIDATE,
    FINAL_WAKE_CONFIRMED,
    PROCESS_PENDING,
    PROCESSING,
    REPORT_READY,
    PROCESS_FAILED;

    val isSleepInProgress: Boolean
        get() = this == SLEEP_ACTIVE || this == WAKE_WITHIN_SLEEP || this == FINAL_WAKE_CANDIDATE
}

/**
 * Eventi che guidano le transizioni della Night State Machine.
 */
sealed class NightEvent {
    data class RestingDetected(val timestampUtc: Long, val reason: String = "FC basale/a riposo rilevata") : NightEvent()
    data class SleepOnsetConfirmed(val timestampUtc: Long, val reason: String = "Sonno continuo confermato (>= 20 min)") : NightEvent()
    data class WakeWithinSleep(val timestampUtc: Long, val reason: String = "Risveglio notturno intermedio") : NightEvent()
    data class ReturnToSleep(val timestampUtc: Long, val reason: String = "Ritorno al sonno dopo veglia (accumulo WASO)") : NightEvent()
    data class WakeProlonged(val timestampUtc: Long, val reason: String = "Veglia prolungata (> 30 min o orario mattutino)") : NightEvent()
    data class FinalWakeConfirmed(val timestampUtc: Long, val reason: String = "Risveglio finale confermato con isteresi temporale") : NightEvent()
    data class EnqueueProcessing(val timestampUtc: Long) : NightEvent()
    data class ProcessingStarted(val timestampUtc: Long) : NightEvent()
    data class ProcessingSuccess(val timestampUtc: Long) : NightEvent()
    data class ProcessingFailed(val timestampUtc: Long, val errorCode: String, val reason: String) : NightEvent()
    data class ReprocessRequested(val timestampUtc: Long, val reason: String = "Rianalisi o correzione confini manuali") : NightEvent()
    data class ResetToNoNight(val timestampUtc: Long, val reason: String = "Nuovo ciclo diurno") : NightEvent()
    data class BluetoothGap(val durationMs: Long) : NightEvent()
}

/**
 * Macchina a stati deterministica per la rivelazione del sonno e l'elaborazione mattutina.
 */
class NightStateMachine(
    initialState: NightState = NightState.NO_NIGHT,
    private val onTransition: (from: NightState, to: NightState, event: NightEvent) -> Unit = { _, _, _ -> },
) {
    var currentState: NightState = initialState
        private set

    private val lock = Any()

    fun transition(event: NightEvent): Boolean = synchronized(lock) {
        val from = currentState
        val to = when (from) {
            NightState.NO_NIGHT -> when (event) {
                is NightEvent.RestingDetected -> NightState.SLEEP_CANDIDATE
                is NightEvent.SleepOnsetConfirmed -> NightState.SLEEP_ACTIVE
                is NightEvent.BluetoothGap -> NightState.NO_NIGHT // GAP BLE NON è veglia né sonno
                else -> null
            }

            NightState.SLEEP_CANDIDATE -> when (event) {
                is NightEvent.SleepOnsetConfirmed -> NightState.SLEEP_ACTIVE
                is NightEvent.WakeProlonged, is NightEvent.WakeWithinSleep, is NightEvent.ResetToNoNight -> NightState.NO_NIGHT
                is NightEvent.BluetoothGap -> NightState.SLEEP_CANDIDATE
                else -> null
            }

            NightState.SLEEP_ACTIVE -> when (event) {
                is NightEvent.WakeWithinSleep -> NightState.WAKE_WITHIN_SLEEP
                is NightEvent.WakeProlonged -> NightState.FINAL_WAKE_CANDIDATE
                is NightEvent.FinalWakeConfirmed -> NightState.FINAL_WAKE_CONFIRMED
                is NightEvent.BluetoothGap -> NightState.SLEEP_ACTIVE // GAP BLE preserva lo stato
                is NightEvent.ResetToNoNight -> NightState.NO_NIGHT
                else -> null
            }

            NightState.WAKE_WITHIN_SLEEP -> when (event) {
                is NightEvent.ReturnToSleep -> NightState.SLEEP_ACTIVE // Ritorno al sonno: sessione conservata!
                is NightEvent.WakeProlonged -> NightState.FINAL_WAKE_CANDIDATE
                is NightEvent.FinalWakeConfirmed -> NightState.FINAL_WAKE_CONFIRMED
                is NightEvent.BluetoothGap -> NightState.WAKE_WITHIN_SLEEP
                is NightEvent.ResetToNoNight -> NightState.NO_NIGHT
                else -> null
            }

            NightState.FINAL_WAKE_CANDIDATE -> when (event) {
                is NightEvent.ReturnToSleep -> NightState.SLEEP_ACTIVE // Ritorno al sonno: sessione conservata, WASO accumulato!
                is NightEvent.FinalWakeConfirmed -> NightState.FINAL_WAKE_CONFIRMED
                is NightEvent.BluetoothGap -> NightState.FINAL_WAKE_CANDIDATE
                is NightEvent.ResetToNoNight -> NightState.NO_NIGHT
                else -> null
            }

            NightState.FINAL_WAKE_CONFIRMED -> when (event) {
                is NightEvent.EnqueueProcessing -> NightState.PROCESS_PENDING
                is NightEvent.ProcessingStarted -> NightState.PROCESSING
                is NightEvent.ProcessingFailed -> NightState.PROCESS_FAILED
                is NightEvent.ResetToNoNight -> NightState.NO_NIGHT
                else -> null
            }

            NightState.PROCESS_PENDING -> when (event) {
                is NightEvent.ProcessingStarted -> NightState.PROCESSING
                is NightEvent.ProcessingFailed -> NightState.PROCESS_FAILED
                is NightEvent.ProcessingSuccess -> NightState.REPORT_READY
                is NightEvent.ReprocessRequested -> NightState.PROCESS_PENDING
                is NightEvent.ResetToNoNight -> NightState.NO_NIGHT
                else -> null
            }

            NightState.PROCESSING -> when (event) {
                is NightEvent.ProcessingSuccess -> NightState.REPORT_READY
                is NightEvent.ProcessingFailed -> NightState.PROCESS_FAILED
                is NightEvent.ReprocessRequested -> NightState.PROCESS_PENDING
                else -> null
            }

            NightState.REPORT_READY -> when (event) {
                is NightEvent.ReprocessRequested -> NightState.PROCESS_PENDING
                is NightEvent.ResetToNoNight -> NightState.NO_NIGHT
                else -> null
            }

            NightState.PROCESS_FAILED -> when (event) {
                is NightEvent.ReprocessRequested -> NightState.PROCESS_PENDING
                is NightEvent.ResetToNoNight -> NightState.NO_NIGHT
                else -> null
            }
        }

        if (to != null && to != from) {
            currentState = to
            Log.i("NightStateMachine", "Transizione sonno: $from -> $to (evento: ${event.javaClass.simpleName})")
            onTransition(from, to, event)
            true
        } else {
            false
        }
    }
}
