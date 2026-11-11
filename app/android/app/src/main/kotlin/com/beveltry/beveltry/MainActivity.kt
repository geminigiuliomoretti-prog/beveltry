package com.beveltry.beveltry

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.beveltry.ble.ConnectionState
import com.beveltry.ble.PuffinCharacteristic
import com.beveltry.ble.PuffinFrameCodec
import com.beveltry.ble.WhoopConnectionService
import com.beveltry.ble.WhoopScanner
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

class MainActivity : FlutterActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var channel: MethodChannel? = null

    private var scanner: WhoopScanner? = null
    private var scanJob: Job? = null

    private var connectionService: WhoopConnectionService? = null
    private var isServiceBound = false
    private var serviceEventsJob: Job? = null

    private var pendingPermissionResult: MethodChannel.Result? = null

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val binder = service as? WhoopConnectionService.LocalBinder
            connectionService = binder?.getService()
            isServiceBound = true
            Log.i(TAG, "WhoopConnectionService collegato a MainActivity")
            subscribeToServiceEvents()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            connectionService = null
            isServiceBound = false
            serviceEventsJob?.cancel()
            Log.i(TAG, "WhoopConnectionService scollegato da MainActivity")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel = ch

        // Assicura l'avvio e binding del servizio foreground nativo
        bindConnectionService()

        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkAndRequestPermissions" -> {
                    if (hasBlePermissions()) {
                        result.success(true)
                    } else {
                        pendingPermissionResult = result
                        requestBlePermissions()
                    }
                }

                "startScan" -> {
                    if (!hasBlePermissions()) {
                        pendingPermissionResult = result
                        requestBlePermissions()
                        return@setMethodCallHandler
                    }
                    startBleScan(call.argument<Int>("timeoutMillis")?.toLong() ?: 15_000L, result)
                }

                "stopScan" -> {
                    stopBleScan()
                    result.success(true)
                }

                "connectAndBond", "connect" -> {
                    val address = call.argument<String>("macAddress")
                    val name = call.argument<String>("name") ?: "WHOOP 5.0"
                    if (address == null) {
                        result.error("INVALID_ARG", "macAddress richiesto", null)
                        return@setMethodCallHandler
                    }
                    connectToDevice(address, name, result)
                }

                "disconnect" -> {
                    disconnectDevice()
                    result.success(true)
                }

                "startSync" -> {
                    val timeoutMs = call.argument<Int>("timeoutMillis")?.toLong() ?: 60_000L
                    val started = connectionService?.startHistoricalSync(timeoutMs) ?: false
                    result.success(started)
                }

                "stopSync" -> {
                    connectionService?.stopHistoricalSync()
                    result.success(true)
                }

                "sendVibration" -> {
                    val pattern = call.argument<Int>("pattern") ?: 0x02
                    val loops = call.argument<Int>("loops") ?: 0x03
                    scope.launch {
                        val ok = connectionService?.sendVibration(pattern, loops) ?: false
                        withContext(Dispatchers.Main) {
                            result.success(ok)
                        }
                    }
                }

                "setRealtimeHr" -> {
                    val enable = call.argument<Boolean>("enable") ?: true
                    scope.launch {
                        val ok = connectionService?.sendRealtimeHrControl(enable) ?: false
                        withContext(Dispatchers.Main) {
                            result.success(ok)
                        }
                    }
                }

                "getConnectionState" -> {
                    val state = connectionService?.stateMachine?.currentState
                    val stateName = state?.javaClass?.simpleName ?: "Disconnected"
                    val isConnected = state is ConnectionState.Ready || state is ConnectionState.Syncing
                    result.success(mapOf(
                        "state" to stateName,
                        "isConnected" to isConnected,
                    ))
                }

                "writeFrame" -> {
                    val frame = call.argument<ByteArray>("frame")
                    if (frame == null) {
                        result.error("INVALID_ARG", "frame binario richiesto", null)
                        return@setMethodCallHandler
                    }
                    scope.launch {
                        try {
                            val service = connectionService
                            if (service == null) {
                                result.error("NOT_BOUND", "Servizio BLE nativo non collegato", null)
                                return@launch
                            }
                            val ok = service.writeRawFrame(frame)
                            withContext(Dispatchers.Main) {
                                result.success(ok)
                            }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) {
                                result.error("WRITE_ERROR", e.message, null)
                            }
                        }
                    }
                }

                // Chiamate Night Recorder (Task 07)
                "startNightRecording" -> {
                    val sessionId = call.argument<String>("sessionId") ?: "night_${System.currentTimeMillis()}"
                    val ok = connectionService?.startNightRecording(sessionId) ?: false
                    result.success(ok)
                }

                "stopNightRecording" -> {
                    val summary = connectionService?.stopNightRecording() ?: emptyMap<String, Any?>()
                    result.success(summary)
                }

                "getNightRecordingStatus" -> {
                    val status = connectionService?.getNightRecordingStatus() ?: emptyMap<String, Any?>()
                    result.success(status)
                }

                "getNightRecordingSummary" -> {
                    val sessionId = call.argument<String>("sessionId")
                    if (sessionId == null) {
                        result.error("INVALID_ARG", "sessionId richiesto", null)
                        return@setMethodCallHandler
                    }
                    val summary = connectionService?.getNightRecordingSummary(sessionId) ?: emptyMap<String, Any?>()
                    result.success(summary)
                }

                // Chiamate Always-On Recorder (Task 08C)
                "setAlwaysOnEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val ok = connectionService?.setAlwaysOnEnabled(enabled) ?: false
                    result.success(ok)
                }

                "isAlwaysOnEnabled" -> {
                    val enabled = connectionService?.isAlwaysOnEnabled() ?: false
                    result.success(enabled)
                }

                "getAlwaysOnDiagnostics" -> {
                    val diag = connectionService?.getAlwaysOnDiagnostics() ?: emptyMap<String, Any?>()
                    result.success(diag)
                }

                "getRecordingSegments" -> {
                    val sessionId = call.argument<String>("sessionId")
                    if (sessionId == null) {
                        result.error("INVALID_ARG", "sessionId richiesto", null)
                        return@setMethodCallHandler
                    }
                    val segments = connectionService?.storageEngine?.getRecordingSegments(sessionId) ?: emptyList<Map<String, Any?>>()
                    result.success(segments)
                }

                "getConnectionEvents" -> {
                    val limit = call.argument<Int>("limit") ?: 50
                    val events = connectionService?.storageEngine?.getRecentConnectionEvents(limit) ?: emptyList<Map<String, Any?>>()
                    result.success(events)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun bindConnectionService() {
        val intent = Intent(this, WhoopConnectionService::class.java)
        // Avvia il servizio se non già attivo
        WhoopConnectionService.start(applicationContext)
        bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
    }

    private fun subscribeToServiceEvents() {
        val service = connectionService ?: return
        serviceEventsJob?.cancel()

        serviceEventsJob = scope.launch {
            launch {
                service.stateMachine.state.collect { state ->
                    val isConnected = state is ConnectionState.Ready || state is ConnectionState.Syncing
                    val isPuffin = service.isPuffinReady
                    channel?.invokeMethod("onConnectionChanged", isConnected)
                    channel?.invokeMethod(
                        "onConnectionStateChanged",
                        mapOf(
                            "state" to state.javaClass.simpleName,
                            "description" to state.toString(),
                            "isConnected" to isConnected,
                            "isPuffinReady" to isPuffin,
                        ),
                    )
                }
            }

            launch {
                service.nightRecorderFlow.collect { status ->
                    channel?.invokeMethod(
                        "onNightRecorderUpdate",
                        mapOf(
                            "sessionId" to status.sessionId,
                            "isRecording" to status.isRecording,
                            "totalSamples" to status.totalSamples,
                            "totalRr" to status.totalRr,
                            "lastHrBpm" to status.lastHrBpm,
                            "lastSampleTimestampUtc" to status.lastSampleTimestampUtc,
                            "durationSeconds" to status.durationSeconds,
                            "disconnectionsCount" to status.disconnectionsCount,
                            "connectionState" to status.connectionState,
                        ),
                    )
                }
            }

            launch {
                service.realtimeHrFlow.collect { hr ->
                    channel?.invokeMethod(
                        "onStandardHr",
                        mapOf(
                            "hr" to hr.hr,
                            "rrIntervalsMs" to hr.rrIntervalsMs,
                            "energyExpended" to hr.energyExpended,
                        ),
                    )
                }
            }

            launch {
                service.live28Flow.collect { live ->
                    channel?.invokeMethod(
                        "onLive28",
                        mapOf(
                            "hr" to live.hr,
                            "rrIntervalMs" to live.rrIntervalMs,
                            "validity" to live.validity,
                            "timestamp" to live.timestampSeconds,
                        ),
                    )
                }
            }

            service.coordinator?.let { coord ->
                launch {
                    coord.updatesFlow.collect { upd ->
                        channel?.invokeMethod(
                            "onAlwaysOnUpdate",
                            mapOf(
                                "stateName" to upd.stateName,
                                "isAlwaysOn" to upd.isAlwaysOn,
                                "isManual" to upd.isManual,
                                "sessionId" to upd.sessionId,
                                "totalSamples" to upd.totalSamples,
                                "totalRr" to upd.totalRr,
                                "lastHr" to upd.lastHr,
                                "lastRr" to upd.lastRr,
                                "lastSampleTimeUtc" to upd.lastSampleTimeUtc,
                                "disconnectionsCount" to upd.disconnectionsCount,
                                "gapsCount" to upd.gapsCount,
                                "maxGapMs" to upd.maxGapMs,
                                "isGattConnected" to upd.isGattConnected,
                                "isSubscribed" to upd.isSubscribed,
                                "isStreaming" to upd.isStreaming,
                                "isPersisting" to upd.isPersisting,
                                "isStreamStale" to upd.isStreamStale,
                                "isBluetoothEnabled" to upd.isBluetoothEnabled,
                            )
                        )
                    }
                }
            }

            launch {
                service.syncProgressFlow.collect { progress ->
                    channel?.invokeMethod(
                        "onSyncProgress",
                        mapOf(
                            "recordsSaved" to progress.recordsSaved,
                            "lastTimestamp" to progress.lastTimestampSeconds,
                            "isCompleted" to progress.isCompleted,
                            "isAborted" to progress.isAborted,
                            "error" to progress.error,
                        ),
                    )
                }
            }

            launch {
                service.rawFramesFlow.collect { rawEvent ->
                    channel?.invokeMethod(
                        "onFrameReceived",
                        mapOf(
                            "characteristic" to rawEvent.characteristic.name,
                            "payload" to rawEvent.frame.rawPayload,
                            "field" to rawEvent.frame.field,
                        ),
                    )
                }
            }
        }
    }

    private fun hasBlePermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val scan = ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
            val connect = ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
            val notif = if (Build.VERSION.SDK_INT >= 33) {
                ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
            } else true
            scan && connect && notif
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestBlePermissions() {
        val permissions = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions.add(Manifest.permission.BLUETOOTH_SCAN)
            permissions.add(Manifest.permission.BLUETOOTH_CONNECT)
            if (Build.VERSION.SDK_INT >= 33) {
                permissions.add(Manifest.permission.POST_NOTIFICATIONS)
            }
        } else {
            permissions.add(Manifest.permission.ACCESS_FINE_LOCATION)
            permissions.add(Manifest.permission.BLUETOOTH)
            permissions.add(Manifest.permission.BLUETOOTH_ADMIN)
        }
        ActivityCompat.requestPermissions(this, permissions.toTypedArray(), PERMISSION_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST_CODE) {
            val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    private fun startBleScan(timeoutMillis: Long, result: MethodChannel.Result) {
        scanJob?.cancel()
        val whoopScanner = WhoopScanner(applicationContext)
        scanner = whoopScanner

        scanJob = scope.launch(Dispatchers.IO) {
            try {
                whoopScanner.scanAll(timeoutMillis).collect { discovered ->
                    withContext(Dispatchers.Main) {
                        channel?.invokeMethod(
                            "onDeviceDiscovered",
                            mapOf(
                                "name" to discovered.name,
                                "macAddress" to discovered.device.address,
                                "rssi" to discovered.rssi,
                            ),
                        )
                    }
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    channel?.invokeMethod("onScanError", e.message)
                }
            }
        }
        result.success(true)
    }

    private fun stopBleScan() {
        scanJob?.cancel()
        scanJob = null
    }

    private fun connectToDevice(macAddress: String, name: String, result: MethodChannel.Result) {
        stopBleScan()
        WhoopConnectionService.start(applicationContext, macAddress, name)

        scope.launch {
            try {
                // Attende il binding del servizio se non ancora completato
                var service = connectionService
                var attempts = 0
                while (service == null && attempts < 25) {
                    delay(100)
                    service = connectionService
                    attempts++
                }

                if (service == null) {
                    withContext(Dispatchers.Main) {
                        result.error("SERVICE_UNAVAILABLE", "Servizio BLE WhoopConnectionService non disponibile", null)
                    }
                    return@launch
                }

                service.connectToDevice(macAddress, name)

                // Attende fino a 35s che la FSM raggiunga Ready (successo) o Failed (errore)
                val terminalState = withTimeoutOrNull(35_000L) {
                    service.stateMachine.state.first { state ->
                        state is ConnectionState.Ready || state is ConnectionState.Failed
                    }
                }

                withContext(Dispatchers.Main) {
                    when (terminalState) {
                        is ConnectionState.Ready -> {
                            Log.i(TAG, "Connessione e handshake completati con successo")
                            result.success(true)
                        }
                        is ConnectionState.Failed -> {
                            Log.e(TAG, "Connessione fallita: ${terminalState.reason}")
                            result.error("CONNECT_FAILED", terminalState.reason, terminalState.errorCode)
                        }
                        null -> {
                            Log.e(TAG, "Timeout connessione GATT/Handshake (35s)")
                            result.error("TIMEOUT", "Timeout connessione GATT o Handshake Puffin (35s)", null)
                        }
                        else -> result.error("UNKNOWN", "Stato non gestito: $terminalState", null)
                    }
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    result.error("CONNECT_EXCEPTION", e.message, null)
                }
            }
        }
    }

    private fun disconnectDevice() {
        stopBleScan()
        connectionService?.disconnectDevice()
        channel?.invokeMethod("onDisconnected", null)
    }

    /**
     * REGOLA ARCHITETTURALE FONDAMENTALE:
     * La distruzione e ricreazione di MainActivity (rotazione, background, sleep)
     * NON devono chiudere BluetoothGatt!
     * Eseguiamo solo l'unbinding del service, lasciando il servizio foreground
     * in esecuzione continua per la persistenza dei dati e della connessione.
     */
    override fun onDestroy() {
        Log.i(TAG, "MainActivity onDestroy: unbinding service senza chiudere BluetoothGatt")
        serviceEventsJob?.cancel()
        if (isServiceBound) {
            try {
                unbindService(serviceConnection)
            } catch (e: Exception) {
                Log.w(TAG, "Errore unbindService in onDestroy: ${e.message}")
            }
            isServiceBound = false
        }
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "MainActivity"
        private const val CHANNEL_NAME = "com.beveltry/ble"
        private const val PERMISSION_REQUEST_CODE = 4107
    }
}
