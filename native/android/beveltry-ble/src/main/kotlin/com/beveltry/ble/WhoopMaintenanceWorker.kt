package com.beveltry.ble

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * Worker periodico WorkManager per housekeeping, riconciliazione SQLite e recupero post-reboot (Task 08C).
 *
 * REGOLE ARCHITETTURALI INVIOLABILI:
 * 1. FAST-EXIT: Se i prerequisiti non sono soddisfatti o il sensore non è disponibile,
 *    termina IMMEDIATAMENTE (Result.success()). MAI attendere indefinitamente il dispositivo
 *    dentro un Worker (rischio wake-lock leak e timeout di sistema).
 * 2. NON campiona HR a 1Hz. Il flusso HR appartiene esclusivamente a BluetoothGatt in connectedDevice FGS.
 * 3. Usa Unique Work deterministico per prevenire schedulazioni duplicate.
 */
class WhoopMaintenanceWorker(
    appContext: Context,
    workerParams: WorkerParameters
) : CoroutineWorker(appContext, workerParams) {

    override suspend fun doWork(): Result {
        Log.i(TAG, "WhoopMaintenanceWorker avviato (id=$id)")
        val storage = WhoopStorageEngine(applicationContext)

        try {
            val alwaysOn = storage.isAlwaysOnEnabled()
            if (!alwaysOn) {
                Log.i(TAG, "Always-On non abilitato. Fast-exit immediato.")
                return Result.success()
            }

            val service = WhoopConnectionService.instance
            if (service == null) {
                Log.i(TAG, "Always-On abilitato ma WhoopConnectionService non attivo. Tentativo ripristino...")
                WhoopConnectionService.start(applicationContext)
            } else {
                val coordinator = service.coordinator
                val state = coordinator?.currentState?.name ?: "UNKNOWN"
                Log.i(TAG, "WhoopConnectionService attivo. Stato coordinator: $state")

                // Riconciliazione segmenti orfani se il servizio era morto
                storage.insertConnectionEvent(
                    eventType = "MAINTENANCE_CHECK",
                    details = "Controllo periodico WorkManager completato. Stato: $state"
                )
            }

            return Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "Errore durante esecuzione maintenance worker: ${e.message}")
            return Result.success() // Non bloccare il sistema
        } finally {
            storage.close()
        }
    }

    companion object {
        private const val TAG = "WhoopMaintenanceWorker"
        private const val UNIQUE_PERIODIC_WORK_NAME = "whoop_periodic_maintenance"
        private const val UNIQUE_ONE_TIME_RECOVERY_NAME = "whoop_recovery_work"

        fun schedulePeriodic(context: Context) {
            val constraints = Constraints.Builder().build()
            val request = PeriodicWorkRequestBuilder<WhoopMaintenanceWorker>(
                15, TimeUnit.MINUTES,
                5, TimeUnit.MINUTES
            ).setConstraints(constraints).build()

            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                UNIQUE_PERIODIC_WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request
            )
            Log.i(TAG, "Schedulato Unique Periodic Work ($UNIQUE_PERIODIC_WORK_NAME)")
        }

        fun enqueueRecovery(context: Context) {
            val request = OneTimeWorkRequestBuilder<WhoopMaintenanceWorker>().build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                UNIQUE_ONE_TIME_RECOVERY_NAME,
                ExistingWorkPolicy.REPLACE,
                request
            )
            Log.i(TAG, "Accodato Unique Recovery Work ($UNIQUE_ONE_TIME_RECOVERY_NAME)")
        }

        fun cancelAll(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_PERIODIC_WORK_NAME)
            WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_ONE_TIME_RECOVERY_NAME)
            Log.i(TAG, "Cancellati tutti i worker schedulati")
        }
    }
}
