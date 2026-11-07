package com.beveltry.ble

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import android.os.ParcelUuid
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

data class WhoopDevice(
    val device: BluetoothDevice,
    val name: String,
    val rssi: Int,
    val advertisedServiceUuids: Set<UUID>,
)

class WhoopScanException(message: String, cause: Throwable? = null) : Exception(message, cause)

/** Ricerca WHOOP 5 con filtri UUID e una seconda scansione per prefisso nome. */
class WhoopScanner(
    context: Context,
    private val adapter: BluetoothAdapter? =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter,
) {
    private val appContext = context.applicationContext

    fun scan(timeoutMillis: Long = DEFAULT_TIMEOUT_MILLIS): Flow<WhoopDevice> = callbackFlow {
        require(timeoutMillis > 0) { "Il timeout scan deve essere positivo" }
        requireScanPermission()

        val scanner: BluetoothLeScanner = adapter?.bluetoothLeScanner
            ?: run {
                close(WhoopScanException("Bluetooth LE non disponibile"))
                return@callbackFlow
            }
        val seen = ConcurrentHashMap.newKeySet<String>()
        val loggedAdvertisements = ConcurrentHashMap.newKeySet<String>()
        var fallbackStarted = false
        var resultFound = false

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                handleResult(result)
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach(::handleResult)
            }

            override fun onScanFailed(errorCode: Int) {
                close(WhoopScanException("Scansione BLE fallita, codice $errorCode"))
            }

            private fun handleResult(result: ScanResult) {
                if (resultFound) return
                val device = result.device
                val advertisedName = result.scanRecord?.deviceName ?: safeDeviceName(device)
                val uuids = result.scanRecord?.serviceUuids.orEmpty().map { it.uuid }
                val logKey = "${advertisedName.orEmpty()}|${uuids.sortedBy(UUID::toString).joinToString()}"
                if (loggedAdvertisements.add(logKey)) {
                    Log.d(TAG, "ADV name=${advertisedName ?: "<none>"} rssi=${result.rssi} uuids=$uuids manufacturers=${manufacturerSummary(result)}")
                }
                if (!isWhoopCandidate(result)) return
                val name = advertisedName ?: "WHOOP 5.0"
                if (!seen.add(device.address)) return

                resultFound = true
                trySend(
                    WhoopDevice(
                        device = device,
                        name = name,
                        rssi = result.rssi,
                        advertisedServiceUuids = result.scanRecord?.serviceUuids
                            .orEmpty().mapTo(linkedSetOf()) { it.uuid },
                    ),
                )
                close()
            }
        }

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        try {
            scanner.startScan(SERVICE_FILTERS, settings, callback)
        } catch (error: SecurityException) {
            close(WhoopScanException("Permesso BLUETOOTH_SCAN mancante", error))
            return@callbackFlow
        } catch (error: IllegalStateException) {
            close(WhoopScanException("Impossibile avviare la scansione BLE", error))
            return@callbackFlow
        }

        val fallbackDelay = (timeoutMillis / 2).coerceAtLeast(1)
        val fallback = launch(start = CoroutineStart.UNDISPATCHED) {
            delay(fallbackDelay)
            if (!resultFound) {
                try {
                    scanner.stopScan(callback)
                    fallbackStarted = true
                    // Una scansione senza filtri consente il fallback sul nome.
                    scanner.startScan(null, settings, callback)
                } catch (error: SecurityException) {
                    close(WhoopScanException("Permesso BLUETOOTH_SCAN mancante", error))
                } catch (error: IllegalStateException) {
                    close(WhoopScanException("Impossibile avviare la scansione BLE di fallback", error))
                }
            }
        }
        val timeout = launch(start = CoroutineStart.UNDISPATCHED) {
            delay(timeoutMillis)
            if (!resultFound) {
                val stage = if (fallbackStarted) "UUID e prefisso nome" else "UUID"
                close(WhoopScanException("No WHOOP 5.0 found in pairing mode (filtro $stage)"))
            }
        }

        awaitClose {
            fallback.cancel()
            timeout.cancel()
            try {
                scanner.stopScan(callback)
            } catch (_: SecurityException) {
                // La scansione è già terminata o il permesso è stato revocato.
            }
        }
    }

    /** Scansione continua che emette tutti i dispositivi candidati trovati (senza chiudere dopo il primo). */
    fun scanAll(timeoutMillis: Long = DEFAULT_TIMEOUT_MILLIS): Flow<WhoopDevice> = callbackFlow {
        require(timeoutMillis > 0) { "Il timeout scan deve essere positivo" }
        requireScanPermission()

        val scanner: BluetoothLeScanner = adapter?.bluetoothLeScanner
            ?: run {
                close(WhoopScanException("Bluetooth LE non disponibile"))
                return@callbackFlow
            }
        val seen = ConcurrentHashMap.newKeySet<String>()

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                handleResult(result)
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach(::handleResult)
            }

            override fun onScanFailed(errorCode: Int) {
                close(WhoopScanException("Scansione BLE fallita, codice $errorCode"))
            }

            private fun handleResult(result: ScanResult) {
                val device = result.device
                val advertisedName = result.scanRecord?.deviceName ?: safeDeviceName(device)
                if (!isWhoopCandidate(result)) return
                val name = advertisedName ?: "WHOOP 5.0"
                if (!seen.add(device.address)) return

                trySend(
                    WhoopDevice(
                        device = device,
                        name = name,
                        rssi = result.rssi,
                        advertisedServiceUuids = result.scanRecord?.serviceUuids
                            .orEmpty().mapTo(linkedSetOf()) { it.uuid },
                    ),
                )
            }
        }

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        try {
            scanner.startScan(null, settings, callback)
        } catch (error: SecurityException) {
            close(WhoopScanException("Permesso BLUETOOTH_SCAN mancante", error))
            return@callbackFlow
        } catch (error: IllegalStateException) {
            close(WhoopScanException("Impossibile avviare la scansione BLE", error))
            return@callbackFlow
        }

        val timeout = launch(start = CoroutineStart.UNDISPATCHED) {
            delay(timeoutMillis)
            close()
        }

        awaitClose {
            timeout.cancel()
            try {
                scanner.stopScan(callback)
            } catch (_: SecurityException) {
            }
        }
    }

    private fun isWhoopCandidate(result: ScanResult): Boolean {
        val uuids = result.scanRecord?.serviceUuids.orEmpty().map { it.uuid }.toSet()
        if (uuids.any { it == WHOOP_16_BIT_SERVICE_UUID || it == WHOOP_SERVICE_UUID }) return true

        val advertisedName = result.scanRecord?.deviceName ?: safeDeviceName(result.device) ?: return false
        return KNOWN_NAME_PREFIXES.any { prefix -> advertisedName.startsWith(prefix, ignoreCase = true) }
    }

    private fun safeDeviceName(device: BluetoothDevice): String? = try {
        if (appContext.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED) {
            device.name
        } else {
            null
        }
    } catch (_: SecurityException) {
        null
    }

    private fun requireScanPermission() {
        if (appContext.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
            throw SecurityException("È necessario concedere BLUETOOTH_SCAN prima di avviare lo scan")
        }
    }

    private fun manufacturerSummary(result: ScanResult): String =
        result.scanRecord?.manufacturerSpecificData?.let { data ->
            (0 until data.size()).joinToString { index ->
                val id = data.keyAt(index)
                "$id:${data.valueAt(index)?.size ?: 0}B"
            }
        }.orEmpty()

    companion object {
        const val DEFAULT_TIMEOUT_MILLIS = 30_000L
        val WHOOP_SERVICE_UUID: UUID = UUID.fromString("fd4b0001-cce1-4033-93ce-002d5875f58a")
        val WHOOP_16_BIT_SERVICE_UUID: UUID = UUID.fromString("0000fd4b-0000-1000-8000-00805f9b34fb")
        val SERVICE_FILTERS: List<ScanFilter> = listOf(
            ScanFilter.Builder().setServiceUuid(ParcelUuid(WHOOP_16_BIT_SERVICE_UUID)).build(),
            ScanFilter.Builder().setServiceUuid(ParcelUuid(WHOOP_SERVICE_UUID)).build(),
        )
        val KNOWN_NAME_PREFIXES = listOf("WBB5AP", "5AG")
        private const val TAG = "WhoopScanner"
    }
}
