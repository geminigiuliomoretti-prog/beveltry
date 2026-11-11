package com.beveltry.ble

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Worker WorkManager per l'elaborazione deterministica e atomica del sonno (Task 08D).
 *
 * REQUISITI FONDAMENTALI:
 * 1. Idempotente: può essere rieseguito senza creare report duplicati.
 * 2. Crash-safe: riprende o aggiorna lo stato atomico in SQLite (whoop_local.db).
 * 3. Indipendente dal recorder BLE: non interrompe né rallenta l'acquisizione continua.
 * 4. Non invia notifiche di successo se l'elaborazione fallisce o i dati sono insufficienti.
 * 5. Se i dati sono insufficienti (< 30 min registrati), marca lo stato come PROCESS_FAILED
 *    con codice INSUFFICIENT_DATA e non genera falsi report.
 */
class SleepAnalysisWorker(
    appContext: Context,
    workerParams: WorkerParameters
) : CoroutineWorker(appContext, workerParams) {

    override suspend fun doWork(): Result {
        val nightKey = inputData.getString(KEY_NIGHT_KEY) ?: return Result.failure()
        val sessionId = inputData.getString(KEY_SESSION_ID) ?: nightKey

        Log.i(TAG, "Avvio elaborazione notturna automatica per $nightKey (session=$sessionId)")
        val storage = WhoopStorageEngine(applicationContext)

        try {
            // 1. Aggiorna stato in PROCESSING
            storage.saveNightProcessingState(
                nightKey = nightKey,
                sessionId = sessionId,
                state = NightState.PROCESSING.name,
                decisionReason = "Elaborazione matematica delle epoche in corso"
            )

            // 2. Estrazione campioni da SQLite
            val hrSamples = storage.getSamplesForSession(sessionId)
            val rrIntervals = storage.getRrIntervalsForSession(sessionId)

            // Controllo dati sufficienti (almeno 30 minuti / 1800 campioni nominali o 60 epoche)
            if (hrSamples.size < 1800) {
                Log.w(TAG, "Dati insufficienti per elaborazione sonno: ${hrSamples.size} campioni (minimo 1800)")
                storage.saveNightProcessingState(
                    nightKey = nightKey,
                    sessionId = sessionId,
                    state = NightState.PROCESS_FAILED.name,
                    errorCode = "INSUFFICIENT_DATA",
                    decisionReason = "Dati insufficienti (< 30 minuti registrati)"
                )
                // Non generare alcuna notifica di successo
                return Result.success()
            }

            // 3. Ricostruzione deterministica epoche da 30 secondi
            val firstTs = hrSamples.first().timestampUtc
            val lastTs = hrSamples.last().timestampUtc
            val totalEpochsCount = ((lastTs - firstTs) / 30000L).toInt() + 1

            data class EpochData(
                val index: Int,
                val startUtc: Long,
                val endUtc: Long,
                val hrMean: Double?,
                val hrStd: Double?,
                val hrSlope: Double,
                val isUsable: Boolean
            )

            val epochs = mutableListOf<EpochData>()
            var sampleIdx = 0
            val nSamples = hrSamples.size

            for (eIdx in 0 until totalEpochsCount) {
                val epStart = firstTs + (eIdx * 30000L)
                val epEnd = epStart + 30000L

                val epSamples = mutableListOf<Int>()
                while (sampleIdx < nSamples && hrSamples[sampleIdx].timestampUtc < epEnd) {
                    if (hrSamples[sampleIdx].timestampUtc >= epStart) {
                        epSamples.add(hrSamples[sampleIdx].hrBpm)
                    }
                    sampleIdx++
                }

                if (epSamples.size >= 10) { // Almeno 10 campioni su 30 nominali
                    val mean = epSamples.average()
                    var sumSq = 0.0
                    for (h in epSamples) sumSq += (h - mean) * (h - mean)
                    val std = sqrt(sumSq / epSamples.size)
                    val slope = (epSamples.last() - epSamples.first()).toDouble() / epSamples.size

                    epochs.add(EpochData(eIdx, epStart, epEnd, mean, std, slope, true))
                } else {
                    epochs.add(EpochData(eIdx, epStart, epEnd, null, null, 0.0, false))
                }
            }

            val usableEpochs = epochs.filter { it.isUsable && it.hrMean != null }
            if (usableEpochs.size < 60) {
                storage.saveNightProcessingState(
                    nightKey = nightKey,
                    sessionId = sessionId,
                    state = NightState.PROCESS_FAILED.name,
                    errorCode = "INSUFFICIENT_DATA",
                    decisionReason = "Epoche utilizzabili insufficienti (< 60 epoche)"
                )
                return Result.success()
            }

            // 4. Baseline notturna (20° percentile epoche valide)
            val sortedMeans = usableEpochs.map { it.hrMean!! }.sorted()
            val idx20 = ((sortedMeans.size * 0.20).toInt()).coerceIn(0, sortedMeans.size - 1)
            val baselineHr = sortedMeans[idx20]

            // 5. Probabilità logistica sleep/wake e smoothing a 5 epoche
            val rawProbs = epochs.map { ep ->
                if (!ep.isUsable || ep.hrMean == null) {
                    0.0
                } else {
                    val hrElev = ep.hrMean - baselineHr
                    val hrStd = ep.hrStd ?: 0.0
                    val posSlope = max(0.0, ep.hrSlope)
                    val z = 1.8 - (0.28 * hrElev) - (0.45 * hrStd) - (0.35 * posSlope)
                    1.0 / (1.0 + exp(-z.coerceIn(-10.0, 10.0)))
                }
            }

            val smoothedProbs = mutableListOf<Double>()
            val nE = epochs.size
            for (i in 0 until nE) {
                val wStart = max(0, i - 2)
                val wEnd = min(nE, i + 3)
                var sum = 0.0
                var count = 0
                for (k in wStart until wEnd) {
                    sum += rawProbs[k]
                    count++
                }
                smoothedProbs.add(if (count > 0) sum / count else rawProbs[i])
            }

            val isAsleepList = smoothedProbs.map { it >= 0.50 }

            // 6. Onset (10 epoche consecutive sonno) e Offset (5 epoche consecutive sonno)
            var onsetIdx: Int? = null
            for (i in 0..nE - 10) {
                if ((0 until 10).all { isAsleepList[i + it] }) {
                    onsetIdx = i
                    break
                }
            }

            var offsetIdx: Int? = null
            for (i in nE - 1 downTo 5) {
                if ((0 until 5).all { isAsleepList[i - it] }) {
                    offsetIdx = i
                    break
                }
            }

            val onsetUtc = onsetIdx?.let { epochs[it].startUtc } ?: firstTs
            val offsetUtc = offsetIdx?.let { epochs[it].endUtc } ?: lastTs

            var tstSec = 0
            var wasoSec = 0
            for (i in 0 until nE) {
                val ep = epochs[i]
                if (ep.startUtc in onsetUtc..offsetUtc) {
                    if (isAsleepList[i]) {
                        tstSec += 30
                    } else {
                        wasoSec += 30
                    }
                }
            }

            val totalBedSec = tstSec + wasoSec
            val efficiency = if (totalBedSec > 0) (tstSec.toDouble() / totalBedSec * 100.0).coerceIn(0.0, 100.0) else 0.0

            // 7. Calcolo HRV RMSSD gap-aware (in ms diretti, Regola Inviolabile 2)
            val sleepRr = rrIntervals.filter {
                it.timestampUtc in onsetUtc..offsetUtc && it.rrMsDirect in 300..2000
            }

            var rmssdSum = 0.0
            var rmssdPairs = 0
            for (i in 0 until sleepRr.size - 1) {
                val r1 = sleepRr[i]
                val r2 = sleepRr[i + 1]
                val dt = abs(r2.timestampUtc - r1.timestampUtc)
                // Se i battiti sono fisiologicamente continui (gap < 2500ms)
                if (dt <= 2500L) {
                    val diff = r2.rrMsDirect - r1.rrMsDirect
                    if (abs(diff) < 300) { // filtro battiti ectopici
                        rmssdSum += (diff * diff).toDouble()
                        rmssdPairs++
                    }
                }
            }
            val rmssdDirect = if (rmssdPairs >= 30) sqrt(rmssdSum / rmssdPairs) else null

            // 8. Calcolo RHR (minimo mobile su 5 min)
            val rhrMin5m = usableEpochs.filter { it.startUtc in onsetUtc..offsetUtc }
                .windowed(size = 10, step = 1, partialWindows = false)
                .map { win -> win.mapNotNull { it.hrMean }.average().toInt() }
                .minOrNull() ?: baselineHr.toInt()

            // 9. Qualità e Copertura
            val coverage = ((hrSamples.size.toDouble() / ((lastTs - firstTs) / 1000.0 + 1.0)) * 100.0).coerceIn(0.0, 100.0)

            // 10. Persistenza atomica dei risultati
            storage.saveSleepLabAnalysis(
                nightKey = nightKey,
                sessionId = sessionId,
                revision = 1,
                state = NightState.REPORT_READY.name,
                algorithmVersion = "1.0.0-cardiac-only",
                sleepOnsetUtc = onsetUtc,
                sleepEndUtc = offsetUtc,
                tstSeconds = tstSec,
                wasoSeconds = wasoSec,
                sleepEfficiency = efficiency,
                hrvRmssdMs = rmssdDirect,
                hrvRollingMedianMs = rmssdDirect,
                rhrBpm = rhrMin5m,
                respirationRate = null, // RSA respirazione richiede SNR >= 2.0
                respirationSnr = null,
                usableEpochsCount = usableEpochs.size,
                totalEpochsCount = totalEpochsCount,
                coveragePercent = coverage,
                gapsCount = 0,
                maxGapSeconds = 0.0,
                qualityFlags = "USABLE_CARDIAC_ONLY",
                classificationLabel = "EXPERIMENTAL_CARDIAC_ONLY"
            )

            storage.saveNightProcessingState(
                nightKey = nightKey,
                sessionId = sessionId,
                state = NightState.REPORT_READY.name,
                candidateOnset = onsetUtc,
                candidateOffset = offsetUtc,
                lastProcessedAt = System.currentTimeMillis(),
                decisionReason = "Elaborazione completata con successo"
            )

            // 11. Invia la notifica «Beveltry — Analisi della notte pronta»
            sendMorningReportNotification(
                tstSeconds = tstSec,
                rhrBpm = rhrMin5m,
                hrvMs = rmssdDirect?.toInt()
            )

            Log.i(TAG, "Elaborazione completata con successo per $nightKey. TST: ${tstSec / 60}m, RHR: $rhrMin5m BPM, HRV: $rmssdDirect ms")
            return Result.success()

        } catch (e: Exception) {
            Log.e(TAG, "Errore fatale elaborazione worker per $nightKey: ${e.message}", e)
            storage.saveNightProcessingState(
                nightKey = nightKey,
                sessionId = sessionId,
                state = NightState.PROCESS_FAILED.name,
                errorCode = "WORKER_EXCEPTION",
                decisionReason = "Eccezione: ${e.message}"
            )
            return Result.failure()
        } finally {
            storage.close()
        }
    }

    private fun sendMorningReportNotification(tstSeconds: Int, rhrBpm: Int, hrvMs: Int?) {
        val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID_MORNING,
                "Report Notturno Beveltry",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifiche del report automatico del sonno al risveglio"
            }
            manager.createNotificationChannel(channel)
        }

        val hours = tstSeconds / 3600
        val mins = (tstSeconds % 3600) / 60
        val durationStr = if (hours > 0) "${hours}h ${mins}m" else "${mins}m"
        val hrvStr = if (hrvMs != null) "$hrvMs ms" else "N/D"

        val contentText = "Sonno stimato: $durationStr | RHR: $rhrBpm BPM | HRV: $hrvStr"

        val launchIntent = applicationContext.packageManager.getLaunchIntentForPackage(applicationContext.packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("route", "/sleep_lab")
        }
        val pendingIntent = if (launchIntent != null) {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            PendingIntent.getActivity(applicationContext, 8042, launchIntent, flags)
        } else null

        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(applicationContext, CHANNEL_ID_MORNING)
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(applicationContext)
        }.apply {
            setContentTitle("Beveltry — Analisi della notte pronta")
            setContentText(contentText)
            setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            setAutoCancel(true)
            if (pendingIntent != null) setContentIntent(pendingIntent)
        }.build()

        manager.notify(NOTIFICATION_ID_MORNING, notification)
        Log.i(TAG, "Inviata notifica 'Beveltry — Analisi della notte pronta': $contentText")
    }

    companion object {
        private const val TAG = "SleepAnalysisWorker"
        const val CHANNEL_ID_MORNING = "beveltry_morning_report"
        const val NOTIFICATION_ID_MORNING = 8042

        const val KEY_NIGHT_KEY = "night_key"
        const val KEY_SESSION_ID = "session_id"

        /**
         * Accoda un Unique Work deterministico per l'analisi notturna.
         * Nome univoco: sleep-analysis-<night-key>
         */
        fun enqueue(context: Context, nightKey: String, sessionId: String) {
            val uniqueWorkName = "sleep-analysis-$nightKey"
            val inputData = Data.Builder()
                .putString(KEY_NIGHT_KEY, nightKey)
                .putString(KEY_SESSION_ID, sessionId)
                .build()

            val request = OneTimeWorkRequestBuilder<SleepAnalysisWorker>()
                .setInputData(inputData)
                .build()

            WorkManager.getInstance(context).enqueueUniqueWork(
                uniqueWorkName,
                ExistingWorkPolicy.KEEP, // Idempotente: se già in coda non duplica
                request
            )
            Log.i(TAG, "Accodato Unique Work $uniqueWorkName")
        }
    }
}
