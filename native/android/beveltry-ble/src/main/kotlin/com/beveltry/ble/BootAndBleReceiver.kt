package com.beveltry.ble

import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Receiver di sistema per riavvio Android e modifiche allo stato Bluetooth (Task 08C).
 *
 * Gestisce:
 * - BOOT_COMPLETED: ripristina la registrazione se Always-On era attivo prima del riavvio.
 * - MY_PACKAGE_REPLACED: preserva lo stato dopo un aggiornamento dell'APK.
 * - BLUETOOTH STATE_CHANGED: notifica il coordinator dello spegnimento/riaccensione del chip BT.
 */
class BootAndBleReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        Log.i(TAG, "Ricevuto broadcast intent: $action")

        when (action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                handleBootOrUpdate(context, action)
            }
            BluetoothAdapter.ACTION_STATE_CHANGED -> {
                val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                handleBluetoothStateChanged(context, state)
            }
        }
    }

    private fun handleBootOrUpdate(context: Context, action: String) {
        val storage = WhoopStorageEngine(context)
        val alwaysOn = try {
            storage.isAlwaysOnEnabled()
        } catch (e: Exception) {
            false
        } finally {
            storage.close()
        }

        Log.i(TAG, "Ripristino $action: Always-On attivo = $alwaysOn")

        if (alwaysOn) {
            // Schedula controllo differito WorkManager
            WhoopMaintenanceWorker.schedulePeriodic(context)
            WhoopMaintenanceWorker.enqueueRecovery(context)

            // Tenta l'avvio del foreground service compatibilmente con le restrizioni Android
            try {
                WhoopConnectionService.start(context)
            } catch (e: Exception) {
                Log.w(TAG, "Impossibile avviare direttamente FGS da boot: ${e.message}. Recupero affidato a WorkManager.")
            }
        }
    }

    private fun handleBluetoothStateChanged(context: Context, state: Int) {
        val service = WhoopConnectionService.instance
        when (state) {
            BluetoothAdapter.STATE_TURNING_OFF -> {
                Log.w(TAG, "Bluetooth in fase di disattivazione (STATE_TURNING_OFF)")
                service?.coordinator?.onBluetoothTurningOff()
            }
            BluetoothAdapter.STATE_OFF -> {
                Log.w(TAG, "Bluetooth DISATTIVATO dal sistema (STATE_OFF)")
                service?.coordinator?.onBluetoothStateChanged(false)
            }
            BluetoothAdapter.STATE_ON -> {
                Log.i(TAG, "Bluetooth RIATTIVATO dal sistema (STATE_ON)")
                service?.coordinator?.onBluetoothStateChanged(true)
            }
        }
    }

    companion object {
        private const val TAG = "BootAndBleReceiver"
    }
}
