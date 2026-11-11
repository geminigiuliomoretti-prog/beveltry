package com.beveltry.ble

import android.companion.CompanionDeviceService
import android.os.Build
import android.util.Log

/**
 * Servizio di monitoraggio presenza Companion Device per WHOOP 5.0 (Task 08C).
 *
 * Riceve eventi di prossimità BLE e connessione periferica dall'OS Android:
 * - Su Android 12-15 (API 31-35): onDeviceAppeared / onDeviceDisappeared.
 * - Su Android 16+ (API 36): ObservingDevicePresenceRequest ed eventi presence/nearby.
 *
 * Quando WHOOP B entra nel raggio d'azione BLE, risveglia tempestivamente
 * il servizio di acquisizione continua senza richiedere scansioni aggressive.
 */
@Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
class WhoopCompanionService : CompanionDeviceService() {

    @Suppress("DEPRECATION")
    override fun onDeviceAppeared(address: String) {
        Log.i(TAG, "CompanionDevice appeared: $address")
        notifyDevicePresent(address)
    }

    @Suppress("DEPRECATION")
    override fun onDeviceDisappeared(address: String) {
        Log.i(TAG, "CompanionDevice disappeared: $address")
    }

    private fun notifyDevicePresent(address: String) {
        val service = WhoopConnectionService.instance
        if (service != null) {
            val coordinator = service.coordinator
            if (coordinator != null && coordinator.isAlwaysOnEnabled) {
                Log.i(TAG, "WHOOP B rilevato da CompanionService. Notifico RecordingCoordinator...")
                service.connectToDevice(address)
            }
        } else {
            Log.i(TAG, "WhoopConnectionService non attivo. Avvio servizio per Always-On...")
            WhoopConnectionService.start(applicationContext, macAddress = address)
        }
    }

    companion object {
        private const val TAG = "WhoopCompanionService"
    }
}
