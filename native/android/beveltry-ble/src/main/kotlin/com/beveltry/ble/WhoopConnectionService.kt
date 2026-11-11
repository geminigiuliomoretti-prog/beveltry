package com.beveltry.ble

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Android Foreground Service persistente per la gestione esclusiva e continua
 * del ciclo di vita BluetoothGatt, protocollo Puffin e persistenza SQLite con WHOOP 5.0.
 */
@SuppressLint("MissingPermission")
class WhoopConnectionService : Service() {

    private val binder = LocalBinder()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // Componenti architetturali proprietari del servizio
    private var gatt: BluetoothGatt? = null
    lateinit var stateMachine: ConnectionStateMachine
        private set
    lateinit var gattQueue: SerializedGattQueue
        private set
    lateinit var storageEngine: WhoopStorageEngine
        private set
    var coordinator: RecordingCoordinator? = null
        private set
    private var syncCoordinator: HistoricalSyncCoordinator? = null

    private var targetDeviceAddress: String? = null
    private var targetDeviceName: String = "WHOOP 5.0"
    private var strapSerial: String = "5AG0558675"

    private var isExplicitDisconnect = false
    private var reconnectJob: Job? = null
    private var reconnectAttempt = 0

    // Stato di autenticazione e Night Recorder (Task 07)
    var isPuffinReady: Boolean = false
        private set
    var isNightRecording: Boolean = false
        private set
    var activeNightSessionId: String? = null
        private set

    private val nightSamplesCount = AtomicInteger(0)
    private val nightRrCount = AtomicInteger(0)
    private var nightStartTimeMs: Long = 0L
    private var nightLastSampleTimeMs: Long = 0L
    private val nightDisconnectionsCount = AtomicInteger(0)
    private var lastNotificationUpdateMs: Long = 0L

    data class NightRecorderStatus(
        val sessionId: String?,
        val isRecording: Boolean,
        val totalSamples: Int,
        val totalRr: Int,
        val lastHrBpm: Int?,
        val lastSampleTimestampUtc: Long?,
        val durationSeconds: Long,
        val disconnectionsCount: Int,
        val connectionState: String,
    )

    private val _nightRecorderFlow = MutableSharedFlow<NightRecorderStatus>(extraBufferCapacity = 64)
    val nightRecorderFlow: SharedFlow<NightRecorderStatus> = _nightRecorderFlow.asSharedFlow()

    private fun emitNightRecorderStatus(lastHr: Int? = null) {
        val now = System.currentTimeMillis()
        val durationSec = if (nightStartTimeMs > 0L) (now - nightStartTimeMs) / 1000L else 0L
        val connState = when (stateMachine.currentState) {
            is ConnectionState.Ready -> "CONNECTED"
            is ConnectionState.Connecting, is ConnectionState.Discovering, is ConnectionState.NegotiatingMtu, is ConnectionState.Subscribing -> "CONNECTING"
            is ConnectionState.WaitingForDevice -> "RECONNECTING"
            is ConnectionState.Failed -> "ERROR"
            else -> "DISCONNECTED"
        }
        _nightRecorderFlow.tryEmit(
            NightRecorderStatus(
                sessionId = activeNightSessionId,
                isRecording = isNightRecording,
                totalSamples = nightSamplesCount.get(),
                totalRr = nightRrCount.get(),
                lastHrBpm = lastHr,
                lastSampleTimestampUtc = if (nightLastSampleTimeMs > 0L) nightLastSampleTimeMs else null,
                durationSeconds = durationSec,
                disconnectionsCount = nightDisconnectionsCount.get(),
                connectionState = connState,
            )
        )
    }

    private val seqCounter = AtomicInteger(1)

    // Frame reassemblers per canale
    private val reassemblers = mapOf(
        PuffinCharacteristic.CMD_FROM_STRAP to PuffinFrameReassembler(),
        PuffinCharacteristic.EVENTS_FROM_STRAP to PuffinFrameReassembler(),
        PuffinCharacteristic.DATA_FROM_STRAP to PuffinFrameReassembler(),
        PuffinCharacteristic.MEMFAULT to PuffinFrameReassembler(),
    )

    // Caratteristiche GATT scoperte
    val discoveredCharacteristics = ConcurrentHashMap<UUID, BluetoothGattCharacteristic>()

    // Flussi di eventi per Flutter UI
    private val _realtimeHrFlow = MutableSharedFlow<StandardHrMeasurement>(extraBufferCapacity = 64)
    val realtimeHrFlow: SharedFlow<StandardHrMeasurement> = _realtimeHrFlow.asSharedFlow()

    private val _live28Flow = MutableSharedFlow<Live28Measurement>(extraBufferCapacity = 64)
    val live28Flow: SharedFlow<Live28Measurement> = _live28Flow.asSharedFlow()

    private val _syncProgressFlow = MutableSharedFlow<SyncProgressUpdate>(extraBufferCapacity = 64)
    val syncProgressFlow: SharedFlow<SyncProgressUpdate> = _syncProgressFlow.asSharedFlow()

    private val _diagnosticFlow = MutableSharedFlow<String>(extraBufferCapacity = 64)
    val diagnosticFlow: SharedFlow<String> = _diagnosticFlow.asSharedFlow()

    data class RawFrameEvent(val characteristic: PuffinCharacteristic, val frame: PuffinFrame)

    private val _rawFramesFlow = MutableSharedFlow<RawFrameEvent>(extraBufferCapacity = 128)
    val rawFramesFlow: SharedFlow<RawFrameEvent> = _rawFramesFlow.asSharedFlow()

    fun logDiagnostic(message: String) {
        Log.i(TAG, "[DIAG] $message")
        _diagnosticFlow.tryEmit(message)
    }

    // Tracking risposte comandi 0x24
    private val pendingCommandAcks = ConcurrentHashMap<Int, CompletableDeferred<CommandResponse0x24>>()

    inner class LocalBinder : Binder() {
        fun getService(): WhoopConnectionService = this@WhoopConnectionService
    }

    // ID Generazionale per invalidare callback tardive di vecchie connessioni GATT (Task 08C.2)
    private val gattSessionGeneration = AtomicInteger(0)
    @Volatile
    private var activeCallbackGeneration: Int = 0

    // Receiver dinamico registrato a runtime per intercettare affidabilmente cambi stato Bluetooth (Task 08C.2)
    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent?) {
            if (intent?.action == BluetoothAdapter.ACTION_STATE_CHANGED) {
                val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                when (state) {
                    BluetoothAdapter.STATE_TURNING_OFF -> {
                        Log.w(TAG, "Bluetooth STATE_TURNING_OFF: inizio procedura chiusura pulita")
                        coordinator?.onBluetoothTurningOff()
                    }
                    BluetoothAdapter.STATE_OFF -> {
                        Log.w(TAG, "Bluetooth STATE_OFF: chip disattivato")
                        handleBluetoothDisabled()
                    }
                    BluetoothAdapter.STATE_TURNING_ON -> {
                        Log.i(TAG, "Bluetooth STATE_TURNING_ON")
                    }
                    BluetoothAdapter.STATE_ON -> {
                        Log.i(TAG, "Bluetooth STATE_ON: chip riattivato")
                        handleBluetoothEnabled()
                    }
                }
            }
        }
    }

    private fun handleBluetoothDisabled() {
        reconnectJob?.cancel()
        reconnectJob = null
        closeGatt()
        storageEngine.insertConnectionEvent(
            eventType = "GATT_CLOSED",
            reasonCode = 0,
            details = "GATT chiuso e code cancellate per spegnimento Bluetooth"
        )
        coordinator?.onBluetoothStateChanged(false)
        stateMachine.transitionTo(ConnectionState.Failed("Bluetooth disattivato", canRetry = false))
        updateNotification("Bluetooth disattivato sullo smartphone")
    }

    private fun handleBluetoothEnabled() {
        Log.i(TAG, "Ripristino connessione post riattivazione Bluetooth")
        coordinator?.onBluetoothStateChanged(true)
    }

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "WhoopConnectionService creato")
        instance = this

        storageEngine = WhoopStorageEngine(applicationContext)

        stateMachine = ConnectionStateMachine { oldState, newState ->
            onConnectionStateChanged(oldState, newState)
        }

        gattQueue = SerializedGattQueue(gattProvider = { gatt }, scope = scope)

        createNotificationChannel()

        coordinator = RecordingCoordinator(
            context = applicationContext,
            storageEngine = storageEngine,
            scope = scope,
            connectAction = { mac ->
                scope.launch { initiateConnection(mac) }
            },
            disconnectAction = {
                disconnectDevice()
            },
            updateNotificationAction = { title, text ->
                updateNotification(text, title = title)
            }
        )

        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(bluetoothStateReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(bluetoothStateReceiver, filter)
        }

        startForegroundWithNotification("Inizializzazione servizio BLE...")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        when (action) {
            ACTION_CONNECT -> {
                val mac = intent.getStringExtra(EXTRA_MAC_ADDRESS)
                val name = intent.getStringExtra(EXTRA_DEVICE_NAME) ?: "WHOOP 5.0"
                if (mac != null) {
                    connectToDevice(mac, name)
                }
            }
            ACTION_DISCONNECT -> {
                disconnectDevice()
            }
            ACTION_ENABLE_ALWAYS_ON -> {
                coordinator?.setAlwaysOnEnabled(true)
            }
            ACTION_DISABLE_ALWAYS_ON -> {
                coordinator?.setAlwaysOnEnabled(false)
            }
            ACTION_STOP_SERVICE -> {
                disconnectDevice()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onDestroy() {
        Log.i(TAG, "WhoopConnectionService onDestroy")
        try {
            unregisterReceiver(bluetoothStateReceiver)
        } catch (e: Exception) {
            Log.w(TAG, "Errore unregister bluetoothStateReceiver: ${e.message}")
        }
        disconnectDevice()
        storageEngine.close()
        scope.cancel()
        instance = null
        super.onDestroy()
    }

    // GESTIONE CONNESSIONE E RICONNESSIONE

    fun connectToDevice(macAddress: String, name: String = "WHOOP 5.0") {
        targetDeviceAddress = macAddress
        targetDeviceName = name
        isExplicitDisconnect = false
        reconnectAttempt = 0
        reconnectJob?.cancel()

        scope.launch {
            initiateConnection(macAddress)
        }
    }

    private suspend fun initiateConnection(macAddress: String) {
        targetDeviceAddress = macAddress
        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = bluetoothManager.adapter
        if (adapter == null || !adapter.isEnabled) {
            stateMachine.transitionTo(ConnectionState.Failed("Bluetooth disattivato", canRetry = true))
            return
        }

        val device: BluetoothDevice = try {
            adapter.getRemoteDevice(macAddress)
        } catch (e: Exception) {
            stateMachine.transitionTo(ConnectionState.Failed("Indirizzo MAC non valido: $macAddress", canRetry = false))
            return
        }

        closeGatt()
        val currentGen = gattSessionGeneration.incrementAndGet()
        activeCallbackGeneration = currentGen
        reassemblers.values.forEach(PuffinFrameReassembler::reset)
        discoveredCharacteristics.clear()

        stateMachine.transitionTo(ConnectionState.Connecting(macAddress))
        updateNotification("Connessione a $targetDeviceName...")

        val bondStateStr = when (device.bondState) {
            BluetoothDevice.BOND_BONDED -> "BOND_BONDED"
            BluetoothDevice.BOND_BONDING -> "BOND_BONDING"
            BluetoothDevice.BOND_NONE -> "BOND_NONE"
            else -> "UNKNOWN (${device.bondState})"
        }
        logDiagnostic("Device selected: $macAddress, bondState=$bondStateStr")
        Log.i(TAG, "connectGatt su $macAddress (bondState=$bondStateStr, autoConnect=false, transport=TRANSPORT_LE)")

        // autoConnect = false garantisce connessione immediata ad alta priorità senza latenze di 30s
        val openedGatt = if (Build.VERSION.SDK_INT >= 23) {
            device.connectGatt(applicationContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
            @Suppress("DEPRECATION")
            device.connectGatt(applicationContext, false, gattCallback)
        }

        if (openedGatt == null) {
            stateMachine.transitionTo(ConnectionState.Failed("Impossibile creare istanza BluetoothGatt", canRetry = true))
            scheduleReconnect()
            return
        }

        gatt = openedGatt
    }

    fun disconnectDevice() {
        isExplicitDisconnect = true
        reconnectJob?.cancel()
        syncCoordinator?.stopSync()
        closeGatt()
        stateMachine.transitionTo(ConnectionState.Disconnected)
        updateNotification("Disconnesso da WHOOP")
    }

    private fun closeGatt() {
        gattSessionGeneration.incrementAndGet()
        gattQueue.clear("Chiusura GATT")
        try {
            gatt?.disconnect()
            gatt?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Errore durante closeGatt: ${e.message}")
        } finally {
            gatt = null
        }
    }

    private fun scheduleReconnect() {
        if (isExplicitDisconnect || targetDeviceAddress == null) return

        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            reconnectAttempt++
            val backoffMs = (minOf(30, 2 * reconnectAttempt) * 1000L).coerceIn(2000L, 30_000L)
            stateMachine.transitionTo(ConnectionState.WaitingForDevice(targetDeviceAddress!!, reconnectAttempt))
            updateNotification("Riconnessione tra ${backoffMs / 1000}s (tentativo $reconnectAttempt)...")
            Log.i(TAG, "Programmata riconnessione tra ${backoffMs}ms")
            delay(backoffMs)
            if (!isExplicitDisconnect && targetDeviceAddress != null) {
                initiateConnection(targetDeviceAddress!!)
            }
        }
    }

    // GATT CALLBACK

    private val gattCallback = object : BluetoothGattCallback() {
        private fun isStale(gatt: BluetoothGatt?): Boolean {
            if (activeCallbackGeneration != gattSessionGeneration.get() || gatt === null || gatt !== this@WhoopConnectionService.gatt) {
                Log.w(TAG, "Callback GATT scartata per istanza obsoleta (gen=$activeCallbackGeneration vs current=${gattSessionGeneration.get()})")
                return true
            }
            return false
        }

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (isStale(gatt)) return
            Log.i(TAG, "onConnectionStateChange status=$status newState=$newState")
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(TAG, "Connessione terminata con status $status")
                coordinator?.onGattDisconnected(status, "GATT status $status")
                if (isNightRecording && activeNightSessionId != null) {
                    nightDisconnectionsCount.incrementAndGet()
                    storageEngine.insertNightEvent(
                        sessionId = activeNightSessionId!!,
                        timestampUtc = System.currentTimeMillis(),
                        monotonicMillis = System.nanoTime() / 1_000_000L,
                        eventType = "DISCONNECTED",
                        details = "GATT error status $status",
                    )
                    updateNotification("Night Recorder: DISCONNESSO (status $status). Riconnessione...")
                    emitNightRecorderStatus(lastHr = null)
                }
                scope.launch {
                    closeGatt()
                    stateMachine.transitionTo(ConnectionState.Failed("GATT status $status", canRetry = true, errorCode = status))
                    scheduleReconnect()
                }
                return
            }

            if (newState == BluetoothProfile.STATE_CONNECTED) {
                reconnectAttempt = 0
                coordinator?.onGattConnected(targetDeviceAddress ?: gatt.device.address)
                stateMachine.transitionTo(ConnectionState.Discovering)
                updateNotification("Ricerca servizi GATT...")
                scope.launch {
                    val result = gattQueue.discoverServices()
                    if (result !is GattOpResult.Success) {
                        Log.e(TAG, "Service discovery fallito: $result")
                        scheduleReconnect()
                    }
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                coordinator?.onGattDisconnected(status, "GATT connection lost")
                if (isNightRecording && activeNightSessionId != null) {
                    nightDisconnectionsCount.incrementAndGet()
                    storageEngine.insertNightEvent(
                        sessionId = activeNightSessionId!!,
                        timestampUtc = System.currentTimeMillis(),
                        monotonicMillis = System.nanoTime() / 1_000_000L,
                        eventType = "DISCONNECTED",
                        details = "GATT connection lost",
                    )
                    updateNotification("Night Recorder: DISCONNESSO. Riconnessione in corso...")
                    emitNightRecorderStatus(lastHr = null)
                }
                scope.launch {
                    closeGatt()
                    if (!isExplicitDisconnect) {
                        scheduleReconnect()
                    } else {
                        stateMachine.transitionTo(ConnectionState.Disconnected)
                    }
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (isStale(gatt)) return
            gattQueue.onServicesDiscovered(status)
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "onServicesDiscovered errore status=$status")
                scheduleReconnect()
                return
            }

            scope.launch {
                setupGattSession(gatt)
            }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (isStale(gatt)) return
            gattQueue.onCharacteristicWrite(characteristic, status)
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (isStale(gatt)) return
            gattQueue.onDescriptorWrite(descriptor, status)
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (isStale(gatt)) return
            @Suppress("DEPRECATION")
            val data = characteristic.value ?: ByteArray(0)
            gattQueue.onCharacteristicRead(characteristic, data, status)
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (isStale(gatt)) return
            Log.i(TAG, "onMtuChanged mtu=$mtu status=$status")
            gattQueue.onMtuChanged(mtu, status)
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (isStale(gatt)) return
            val value = characteristic.value ?: ByteArray(0)
            if (value.isNotEmpty()) {
                handleNotification(characteristic.uuid, value)
            }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            if (isStale(gatt)) return
            if (value.isNotEmpty()) {
                handleNotification(characteristic.uuid, value)
            }
        }
    }

    private suspend fun setupGattSession(gatt: BluetoothGatt) {
        val services = gatt.services
        val serviceCount = services.size
        val summary = services.joinToString("; ") { s ->
            val name = when (s.uuid) {
                HEART_RATE_SERVICE_UUID -> "HR(0x180D)"
                WHOOP_SERVICE_UUID -> "WHOOP_PRI(0xFD4B)"
                else -> s.uuid.toString().substring(0, 8)
            }
            "$name[${s.characteristics.size}]"
        }
        coordinator?.onServicesDiscovered(serviceCount, summary)
        logDiagnostic("Services discovered: $summary")

        // Indicizza TUTTE le caratteristiche di TUTTI i servizi disponibili
        for (service in services) {
            for (ch in service.characteristics) {
                discoveredCharacteristics[ch.uuid] = ch
            }
        }

        // =========================================================================
        // PRIORITÀ ASSOLUTA (TASK 08C.1): Sottoscrizione immediata a Heart Rate 0x2A37
        // =========================================================================
        val hrChar = discoveredCharacteristics[HEART_RATE_MEASUREMENT_UUID]
            ?: gatt.getService(HEART_RATE_SERVICE_UUID)?.getCharacteristic(HEART_RATE_MEASUREMENT_UUID)

        if (hrChar != null) {
            discoveredCharacteristics[HEART_RATE_MEASUREMENT_UUID] = hrChar
            coordinator?.onHrCharacteristicFound(hrChar.properties)
            coordinator?.onCccdWriteStarted()
            val hrSubOk = enableNotificationSerialized(gatt, hrChar)
            logDiagnostic("Sottoscrizione 0x2A37 immediata: ok=$hrSubOk")
            coordinator?.onHrSubscribed(if (hrSubOk) 0 else -1)
        } else {
            Log.e(TAG, "Caratteristica standard Heart Rate 0x2A37 non trovata nei servizi GATT!")
            logDiagnostic("Caratteristica Heart Rate 0x2A37 non trovata!")
            coordinator?.onHrSubscribed(status = 133)
        }

        // 1. Negozia MTU a 247 (come osservato nella cattura btsnoop_hci)
        stateMachine.transitionTo(ConnectionState.NegotiatingMtu)
        val mtuRes = gattQueue.requestMtu(247, timeoutMs = 3000L)
        logDiagnostic("MTU negoziato: $mtuRes")
        Log.i(TAG, "MTU negoziato: $mtuRes")

        // 2. Abilita sottoscrizioni CCCD secondarie Puffin se presenti
        val puffinSubUuids = listOf(
            CMD_FROM_STRAP_UUID,
            EVENTS_FROM_STRAP_UUID,
            DATA_FROM_STRAP_UUID,
            MEMFAULT_UUID,
        )

        var step = 0
        for (uuid in puffinSubUuids) {
            step++
            stateMachine.transitionTo(ConnectionState.Subscribing(step, puffinSubUuids.size))
            val ch = discoveredCharacteristics[uuid]
            if (ch != null) {
                val ok = enableNotificationSerialized(gatt, ch)
                logDiagnostic("CCCD write su $uuid: ok=$ok")
            }
        }

        // 3. Esegui Handshake documentato (FASE 3: Nessun blocco se fallisce!)
        stateMachine.transitionTo(ConnectionState.Handshaking("CLIENT_HELLO (0x91)"))
        updateNotification("Handshake Puffin in corso...")
        logDiagnostic("Avvio Puffin Handshake nativo...")
        val handshakeOk = executePuffinHandshake()
        if (handshakeOk) {
            isPuffinReady = true
            logDiagnostic("Puffin Handshake completato: protocollo autenticato e pronto")

            // 4. Inizializza Sync Coordinator
            syncCoordinator = HistoricalSyncCoordinator(
                strapSerial = strapSerial,
                gattQueue = gattQueue,
                storageEngine = storageEngine,
                writeCharacteristicProvider = { discoveredCharacteristics[CMD_TO_STRAP_UUID] },
                scope = scope,
            )

            scope.launch {
                syncCoordinator?.progress()?.collect { progress ->
                    _syncProgressFlow.emit(progress)
                    if (progress.isCompleted) {
                        stateMachine.transitionTo(ConnectionState.Ready)
                        updateNotification("WHOOP Connesso: Sincronizzazione completata (${progress.recordsSaved} record)")
                    } else if (progress.isAborted || progress.error != null) {
                        stateMachine.transitionTo(ConnectionState.Ready)
                        updateNotification("WHOOP Connesso: Sincronizzazione interrotta")
                    } else {
                        stateMachine.transitionTo(ConnectionState.Syncing(progress.recordsSaved, null))
                        updateNotification("Sincronizzazione in corso: ${progress.recordsSaved} record...")
                    }
                }
            }

            stateMachine.transitionTo(ConnectionState.Ready)
            if (!isNightRecording) {
                updateNotification("WHOOP Connesso e Pronto")
            }
            Log.i(TAG, "WHOOP 5.0 connesso, autenticato e pronto per le operazioni!")
        } else {
            isPuffinReady = false
            logDiagnostic("Handshake Puffin 0x91 non completato o timeout. Protocollo Puffin NON disponibile, ma canale BLE Standard HR (0x2A37) ATTIVO.")
            Log.w(TAG, "Handshake Puffin fallito. Connessione GATT e Standard HR mantenute attive.")
            stateMachine.transitionTo(ConnectionState.Ready)
            if (!isNightRecording) {
                updateNotification("WHOOP Connesso (Solo Battito HR Standard)")
            }
        }

        if (isNightRecording && activeNightSessionId != null) {
            storageEngine.insertNightEvent(
                sessionId = activeNightSessionId!!,
                timestampUtc = System.currentTimeMillis(),
                monotonicMillis = System.nanoTime() / 1_000_000L,
                eventType = "CONNECTED",
                details = "GATT riconnesso con successo",
            )
            updateNotification("Night Recorder: Riconnesso. Ripresa registrazione...")
            emitNightRecorderStatus(lastHr = null)
        }
    }

    private suspend fun enableNotificationSerialized(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic): Boolean {
        gatt.setCharacteristicNotification(ch, true)
        val cccd = ch.getDescriptor(CCCD_UUID) ?: run {
            logDiagnostic("CCCD non trovato per ${ch.uuid}")
            return false
        }
        val res = gattQueue.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE, timeoutMs = 3000L)
        val ok = res is GattOpResult.Success
        Log.i(TAG, "Sottoscrizione CCCD su ${ch.uuid}: $res")
        return ok
    }

    private suspend fun executePuffinHandshake(): Boolean {
        val cmdChar = discoveredCharacteristics[CMD_TO_STRAP_UUID] ?: run {
            logDiagnostic("Caratteristica CMD_TO_STRAP non trovata")
            return false
        }

        // 1. Invia GET_HELLO 0x91: [0x23, seq, 0x91, 0x01] con field = 0x0000
        val helloSeq = nextSeq()
        val helloPayload = byteArrayOf(0x23, helloSeq.toByte(), 0x91.toByte(), 0x01)
        val helloFrame = PuffinFrameCodec.encode(field = 0x0000, helloPayload)

        val helloDeferred = CompletableDeferred<CommandResponse0x24>()
        pendingCommandAcks[helloSeq] = helloDeferred

        logDiagnostic("HELLO TX: seq=$helloSeq, opcode=0x91, field=0x0000, frameLen=${helloFrame.size}")
        val helloWrite = gattQueue.writeCharacteristic(cmdChar, helloFrame, timeoutMs = 3000L)
        logDiagnostic("onCharacteristicWrite HELLO status=$helloWrite")

        if (helloWrite !is GattOpResult.Success) {
            Log.e(TAG, "Invio HELLO fallito: $helloWrite")
            pendingCommandAcks.remove(helloSeq)
            return false
        }

        var helloResp = withTimeoutOrNull(4000L) { helloDeferred.await() }
        if (helloResp == null) {
            logDiagnostic("HELLO prima risposta timeout, ritento una volta con nuova seq...")
            val retrySeq = nextSeq()
            val retryPayload = byteArrayOf(0x23, retrySeq.toByte(), 0x91.toByte(), 0x01)
            val retryFrame = PuffinFrameCodec.encode(field = 0x0000, retryPayload)
            val retryDeferred = CompletableDeferred<CommandResponse0x24>()
            pendingCommandAcks[retrySeq] = retryDeferred
            gattQueue.writeCharacteristic(cmdChar, retryFrame, timeoutMs = 3000L)
            helloResp = withTimeoutOrNull(4000L) { retryDeferred.await() }
            pendingCommandAcks.remove(retrySeq)
        }
        pendingCommandAcks.remove(helloSeq)

        if (helloResp == null || !helloResp.isSuccess) {
            logDiagnostic("Risposta HELLO non valida o timeout: $helloResp")
            Log.e(TAG, "Risposta HELLO non valida o timeout: $helloResp")
            return false
        }
        logDiagnostic("Risposta 0x91 confermata: status=${helloResp.status}, strapSeq=${helloResp.strapSeq}, echoSeq=${helloResp.echoSeq}")

        // 2. Invia GET_ADVERTISING_NAME 0x8D
        val nameSeq = nextSeq()
        val namePayload = byteArrayOf(0x23, nameSeq.toByte(), 0x8D.toByte(), 0x00)
        val nameFrame = PuffinFrameCodec.encode(field = 0x0000, namePayload)
        val nameDeferred = CompletableDeferred<CommandResponse0x24>()
        pendingCommandAcks[nameSeq] = nameDeferred
        gattQueue.writeCharacteristic(cmdChar, nameFrame, timeoutMs = 3000L)
        val nameResp = withTimeoutOrNull(3000L) { nameDeferred.await() }
        pendingCommandAcks.remove(nameSeq)
        if (nameResp != null && nameResp.isSuccess && nameResp.remainingBytes.isNotEmpty()) {
            val nameStr = String(nameResp.remainingBytes).trim { it <= ' ' || it == '\u0000' }
            if (nameStr.isNotEmpty()) {
                strapSerial = nameStr
                logDiagnostic("Strap Serial da 0x8D: $strapSerial")
            }
        }

        // 3. Invia GET_DATA_RANGE 0x22
        stateMachine.transitionTo(ConnectionState.Handshaking("GET_DATA_RANGE (0x22)"))
        val rangeSeq = nextSeq()
        val rangePayload = byteArrayOf(0x23, rangeSeq.toByte(), 0x22, 0x00)
        val rangeFrame = PuffinFrameCodec.encode(field = 0x0000, rangePayload)
        val rangeDeferred = CompletableDeferred<CommandResponse0x24>()
        pendingCommandAcks[rangeSeq] = rangeDeferred
        val rangeWrite = gattQueue.writeCharacteristic(cmdChar, rangeFrame, timeoutMs = 3000L)
        if (rangeWrite is GattOpResult.Success) {
            withTimeoutOrNull(3000L) { rangeDeferred.await() }
        }
        pendingCommandAcks.remove(rangeSeq)
        logDiagnostic("Handshake 0x22 completato con successo")
        return true
    }

    private fun nextSeq(): Int {
        val s = seqCounter.getAndIncrement()
        if (seqCounter.get() > 255) seqCounter.set(1)
        return s and 0xFF
    }

    // INOLTRO NOTIFICHE E DECODIFICA

    private fun handleNotification(uuid: UUID, value: ByteArray) {
        if (uuid == HEART_RATE_MEASUREMENT_UUID) {
            try {
                val hexPreview = value.take(8).joinToString(" ") { "%02X".format(it) }
                coordinator?.onHrNotificationReceived(value.size, hexPreview)

                val hr = PuffinProtocolDecoder.decodeStandardHr(value)
                coordinator?.onHrSampleDecoded(hr.hr, hr.rawRrIntervals.size)

                _realtimeHrFlow.tryEmit(hr)

                val flags = if (value.isNotEmpty()) value[0].toInt() and 0xFF else 0
                val sensorContact = hr.sensorContactDetected?.let { if (it) 1 else 0 } ?: -1

                // =========================================================================
                // INOLTRO UNICO E DIRETTO AL RECORDING COORDINATOR (TASK 08C.1 FIX BLOCCANTE)
                // =========================================================================
                coordinator?.onHrSampleReceived(
                    hrBpm = hr.hr,
                    rawRrIntervals = hr.rawRrIntervals,
                    flags = flags,
                    sensorContact = sensorContact,
                    origin = "GATT_0x2A37"
                )

                if (isNightRecording) {
                    nightSamplesCount.incrementAndGet()
                    if (hr.rawRrIntervals.isNotEmpty()) {
                        nightRrCount.addAndGet(hr.rawRrIntervals.size)
                    }
                    nightLastSampleTimeMs = System.currentTimeMillis()

                    val now = System.currentTimeMillis()
                    if (now - lastNotificationUpdateMs >= 1000L) {
                        lastNotificationUpdateMs = now
                        val elapsedSec = (now - nightStartTimeMs) / 1000L
                        val h = elapsedSec / 3600
                        val m = (elapsedSec % 3600) / 60
                        val s = elapsedSec % 60
                        val durStr = String.format("%02d:%02d:%02d", h, m, s)
                        val rrText = if (nightRrCount.get() > 0) " | ${nightRrCount.get()} RR" else ""
                        updateNotification("Night Recorder: ${hr.hr} BPM | ${nightSamplesCount.get()} campioni$rrText | $durStr")
                    }

                    emitNightRecorderStatus(lastHr = hr.hr)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Errore decodifica 0x2A37: ${e.message}")
            }
            return
        }

        val charKind = when (uuid) {
            CMD_FROM_STRAP_UUID -> PuffinCharacteristic.CMD_FROM_STRAP
            EVENTS_FROM_STRAP_UUID -> PuffinCharacteristic.EVENTS_FROM_STRAP
            DATA_FROM_STRAP_UUID -> PuffinCharacteristic.DATA_FROM_STRAP
            MEMFAULT_UUID -> PuffinCharacteristic.MEMFAULT
            else -> null
        } ?: return

        val reassembler = reassemblers[charKind] ?: return
        val frames = reassembler.feed(value)

        for (frame in frames) {
            _rawFramesFlow.tryEmit(RawFrameEvent(charKind, frame))
            val inner = frame.rawPayload
            if (inner.isEmpty()) continue

            when (charKind) {
                PuffinCharacteristic.CMD_FROM_STRAP -> {
                    val resp = PuffinProtocolDecoder.decodeCommandResponse0x24(inner)
                    if (resp != null) {
                        logDiagnostic("RX 0x24 su CMD_FROM_STRAP: cmd=0x${resp.cmd.toString(16)}, echoSeq=${resp.echoSeq}, strapSeq=${resp.strapSeq}, status=0x${resp.status.toString(16)}")
                        pendingCommandAcks[resp.echoSeq]?.complete(resp)
                    } else {
                        logDiagnostic("RX frame non-0x24 su CMD_FROM_STRAP: len=${inner.size}")
                    }
                }
                PuffinCharacteristic.DATA_FROM_STRAP -> {
                    val opcode = inner[0].toInt() and 0xFF
                    if (opcode == 0x28) {
                        try {
                            val live = PuffinProtocolDecoder.decodeLive28(inner)
                            _live28Flow.tryEmit(live)
                        } catch (e: Exception) {
                            Log.w(TAG, "Errore decodifica Live28: ${e.message}")
                        }
                    } else if (opcode == 0x2F || opcode == 0x31) {
                        syncCoordinator?.onDataReceived(inner)
                    }
                }
                else -> {
                    // Eventi e log meta/diagnostica
                }
            }
        }
    }

    // OPERAZIONI PUBBLICHE PER FLUTTER

    fun startHistoricalSync(timeoutMs: Long = 60_000L): Boolean {
        if (stateMachine.currentState !is ConnectionState.Ready) {
            Log.w(TAG, "Impossibile avviare sync: dispositivo non in stato Ready")
            return false
        }
        return syncCoordinator?.startSync(timeoutMs) ?: false
    }

    fun stopHistoricalSync() {
        syncCoordinator?.stopSync()
    }

    suspend fun sendRealtimeHrControl(enable: Boolean): Boolean {
        val cmdChar = discoveredCharacteristics[CMD_TO_STRAP_UUID] ?: return false
        val seq = nextSeq()
        val arg = if (enable) 0x01.toByte() else 0x00.toByte()
        val payload = byteArrayOf(0x23, seq.toByte(), 0x13, arg)
        val frame = PuffinFrameCodec.encode(field = 0x0000, payload)

        val deferred = CompletableDeferred<CommandResponse0x24>()
        pendingCommandAcks[seq] = deferred

        val res = gattQueue.writeCharacteristic(cmdChar, frame, timeoutMs = 3000L)
        if (res !is GattOpResult.Success) {
            pendingCommandAcks.remove(seq)
            return false
        }

        val resp = withTimeoutOrNull(3000L) { deferred.await() }
        pendingCommandAcks.remove(seq)
        return resp?.isSuccess ?: true
    }

    suspend fun writeRawFrame(frame: ByteArray): Boolean {
        val target = discoveredCharacteristics[CMD_TO_STRAP_UUID] ?: return false
        val opRes = gattQueue.writeCharacteristic(target, frame)
        return opRes is GattOpResult.Success
    }

    suspend fun sendVibration(pattern: Int = 0x02, loops: Int = 0x03): Boolean {
        val cmdChar = discoveredCharacteristics[CMD_TO_STRAP_UUID] ?: return false
        val seq = nextSeq()
        val innerCmd = byteArrayOf(
            0x23,
            seq.toByte(),
            0x13, // Opcode HAPTIC_TRIGGER
            (pattern and 0xFF).toByte(),
            (loops and 0xFF).toByte(),
            0x00,
            0x00,
            0x00,
        )
        val frame = PuffinFrameCodec.encode(field = 0x0000, innerCmd)
        val res = gattQueue.writeCharacteristic(cmdChar, frame, timeoutMs = 3000L)
        return res is GattOpResult.Success
    }

    // METODI NIGHT RECORDER (Task 07)

    fun startNightRecording(sessionId: String): Boolean {
        val address = targetDeviceAddress ?: "FD:49:44:66:1D:92"
        val name = targetDeviceName
        activeNightSessionId = sessionId
        isNightRecording = true
        nightSamplesCount.set(0)
        nightRrCount.set(0)
        nightDisconnectionsCount.set(0)
        nightStartTimeMs = System.currentTimeMillis()
        nightLastSampleTimeMs = 0L

        val started = coordinator?.startManualRecording(sessionId) ?: storageEngine.startNightSession(sessionId, address, name, nightStartTimeMs)
        logDiagnostic("Night Recording avviata: session=$sessionId, device=$address ($name), db_ok=$started")
        updateNotification("Night Recorder ATTIVO: In attesa primo battito...")
        emitNightRecorderStatus(lastHr = null)
        return started
    }

    fun setAlwaysOnEnabled(enabled: Boolean): Boolean {
        val ok = coordinator?.setAlwaysOnEnabled(enabled) ?: false
        if (enabled) {
            WhoopMaintenanceWorker.schedulePeriodic(applicationContext)
        }
        return ok
    }

    fun isAlwaysOnEnabled(): Boolean {
        return coordinator?.isAlwaysOnEnabled ?: false
    }

    fun getAlwaysOnDiagnostics(): Map<String, Any?> {
        return coordinator?.getDiagnostics() ?: emptyMap()
    }

    fun stopNightRecording(): Map<String, Any?> {
        val sessionId = activeNightSessionId ?: return emptyMap()
        val now = System.currentTimeMillis()
        isNightRecording = false
        storageEngine.endNightSession(sessionId, "COMPLETED", now)
        logDiagnostic("Night Recording terminata: session=$sessionId, totalSamples=${nightSamplesCount.get()}")
        updateNotification("Night Recorder Terminato (${nightSamplesCount.get()} campioni)")
        val summary = storageEngine.getNightSessionSummary(sessionId)
        activeNightSessionId = null
        emitNightRecorderStatus(lastHr = null)
        return summary
    }

    fun getNightRecordingStatus(): Map<String, Any?> {
        val sessionId = activeNightSessionId
        val now = System.currentTimeMillis()
        val durationSec = if (nightStartTimeMs > 0L) (now - nightStartTimeMs) / 1000L else 0L
        val connState = when (stateMachine.currentState) {
            is ConnectionState.Ready -> "CONNECTED"
            is ConnectionState.Connecting, is ConnectionState.Discovering, is ConnectionState.NegotiatingMtu, is ConnectionState.Subscribing -> "CONNECTING"
            is ConnectionState.WaitingForDevice -> "RECONNECTING"
            is ConnectionState.Failed -> "ERROR"
            else -> "DISCONNECTED"
        }
        return mapOf(
            "sessionId" to sessionId,
            "isRecording" to isNightRecording,
            "totalSamples" to nightSamplesCount.get(),
            "totalRr" to nightRrCount.get(),
            "lastSampleTimestampUtc" to if (nightLastSampleTimeMs > 0L) nightLastSampleTimeMs else null,
            "durationSeconds" to durationSec,
            "disconnectionsCount" to nightDisconnectionsCount.get(),
            "connectionState" to connState,
        )
    }

    fun getNightRecordingSummary(sessionId: String): Map<String, Any?> {
        return storageEngine.getNightSessionSummary(sessionId)
    }

    // NOTIFICHE FOREGROUND

    private fun onConnectionStateChanged(oldState: ConnectionState, newState: ConnectionState) {
        val text = when (newState) {
            is ConnectionState.Disconnected -> "Disconnesso"
            is ConnectionState.WaitingForDevice -> "In attesa di connessione..."
            is ConnectionState.Connecting -> "Connessione in corso..."
            is ConnectionState.Discovering -> "Ricerca caratteristiche GATT..."
            is ConnectionState.NegotiatingMtu -> "Negoziazione MTU..."
            is ConnectionState.Subscribing -> "Configurazione notifiche (${newState.step}/${newState.total})..."
            is ConnectionState.Handshaking -> "Autenticazione ${newState.stepName}..."
            is ConnectionState.Ready -> "Connesso e pronto"
            is ConnectionState.Syncing -> "Sincronizzazione (${newState.recordsSaved} record)..."
            is ConnectionState.Failed -> "Errore: ${newState.reason}"
        }
        updateNotification(text)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Connessione WHOOP 5.0",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Stato della sincronizzazione locale WHOOP"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(contentText: String, contentTitle: String? = null): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val disableIntent = Intent(this, WhoopConnectionService::class.java).apply {
            action = ACTION_DISABLE_ALWAYS_ON
        }
        val disablePendingIntent = PendingIntent.getService(
            this,
            1,
            disableIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val title = contentTitle ?: if (coordinator?.isAlwaysOnEnabled == true) {
            "Beveltry — Registrazione WHOOP attiva"
        } else {
            "WHOOP 5.0 — Beveltry"
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder.setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle(title)
            .setContentText(contentText)
            .setContentIntent(pendingIntent)
            .setOngoing(true)

        if (coordinator?.isAlwaysOnEnabled == true) {
            builder.addAction(
                Notification.Action.Builder(
                    null,
                    "Disattiva Always-On",
                    disablePendingIntent
                ).build()
            )
        }

        return builder.build()
    }

    private fun startForegroundWithNotification(text: String, title: String? = null) {
        val notification = buildNotification(text, title)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    fun updateNotification(text: String, title: String? = null) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        manager?.notify(NOTIFICATION_ID, buildNotification(text, title))
    }

    companion object {
        private const val TAG = "WhoopConnectionService"
        private const val CHANNEL_ID = "whoop_connection_service"
        private const val NOTIFICATION_ID = 5041

        const val ACTION_CONNECT = "com.beveltry.ble.action.CONNECT"
        const val ACTION_DISCONNECT = "com.beveltry.ble.action.DISCONNECT"
        const val ACTION_STOP_SERVICE = "com.beveltry.ble.action.STOP"
        const val ACTION_ENABLE_ALWAYS_ON = "com.beveltry.ble.action.ENABLE_ALWAYS_ON"
        const val ACTION_DISABLE_ALWAYS_ON = "com.beveltry.ble.action.DISABLE_ALWAYS_ON"

        const val EXTRA_MAC_ADDRESS = "extra_mac_address"
        const val EXTRA_DEVICE_NAME = "extra_device_name"

        val WHOOP_SERVICE_UUID: UUID = UUID.fromString("fd4b0001-cce1-4033-93ce-002d5875f58a")
        val CMD_TO_STRAP_UUID: UUID = UUID.fromString("fd4b0002-cce1-4033-93ce-002d5875f58a")
        val CMD_FROM_STRAP_UUID: UUID = UUID.fromString("fd4b0003-cce1-4033-93ce-002d5875f58a")
        val EVENTS_FROM_STRAP_UUID: UUID = UUID.fromString("fd4b0004-cce1-4033-93ce-002d5875f58a")
        val DATA_FROM_STRAP_UUID: UUID = UUID.fromString("fd4b0005-cce1-4033-93ce-002d5875f58a")
        val MEMFAULT_UUID: UUID = UUID.fromString("fd4b0007-cce1-4033-93ce-002d5875f58a")

        val HEART_RATE_SERVICE_UUID: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        val HEART_RATE_MEASUREMENT_UUID: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        @Volatile
        var instance: WhoopConnectionService? = null
            private set

        fun start(context: Context, macAddress: String? = null, name: String? = null) {
            val intent = Intent(context, WhoopConnectionService::class.java).apply {
                if (macAddress != null) {
                    action = ACTION_CONNECT
                    putExtra(EXTRA_MAC_ADDRESS, macAddress)
                    putExtra(EXTRA_DEVICE_NAME, name)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(Intent(context, WhoopConnectionService::class.java).setAction(ACTION_STOP_SERVICE))
        }
    }
}
