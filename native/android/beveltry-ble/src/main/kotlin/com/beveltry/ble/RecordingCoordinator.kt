package com.beveltry.ble

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Motore unico e centrale di coordinamento per l'acquisizione continua e resiliente (Task 08C).
 *
 * Responsabilità inviolabili:
 * 1. UN SOLO proprietario della sessione BLE: impedisce rigorosamente connessioni GATT
 *    simultanee, doppie sottoscrizioni CCCD o sessioni sovrapposte.
 * 2. Macchina a stati deterministica (BleStateMachine con 12 stati).
 * 3. Backoff controllato senza polling aggressivo (0s -> 2s -> 5s -> 15s -> 30s -> 60s).
 * 4. Tracciamento continuo di segmenti di registrazione, disconnessioni e gap (senza interpolazioni).
 * 5. Protezione da stop accidentale: se Always-On è attivo, lo stop manuale del Night Recorder
 *    non interrompe l'acquisizione automatica a meno di richiesta esplicita.
 */
class RecordingCoordinator(
    private val context: Context,
    private val storageEngine: WhoopStorageEngine,
    private val scope: CoroutineScope,
    private val connectAction: (macAddress: String) -> Unit,
    private val disconnectAction: () -> Unit,
    private val updateNotificationAction: (title: String, text: String) -> Unit,
) {
    private val stateLock = Any()

    // Configurazione target WHOOP B
    var targetMacAddress: String = "FD:49:44:66:1D:92"
        private set
    var targetDeviceName: String = "WBB5AP-5AG0558675"
        private set

    // Macchina a stati
    val stateMachine = BleStateMachine(
        initialState = BleState.Disabled,
        onTransition = { from, to, event ->
            handleStateTransition(from, to, event)
        }
    )

    val currentState: BleState
        get() = stateMachine.currentState

    // Sessione e segmenti attivi
    var activeSessionId: String? = null
        private set
    private var activeSegmentId: String? = null
    private var segmentStartedAtUtc: Long = 0L
    private var segmentHrCount = 0
    private var segmentRrCount = 0
    private var segmentMaxGapMs = 0L

    // Flag di modalità
    var isAlwaysOnEnabled: Boolean = false
        private set
    var isManualRecordingActive: Boolean = false
        private set

    // Telemetria e diagnostica
    val totalSamplesCount = AtomicInteger(0)
    val totalRrCount = AtomicInteger(0)
    val disconnectionsCount = AtomicInteger(0)
    val gapsDetectedCount = AtomicInteger(0)
    val maxGapMs = AtomicLong(0L)

    var lastHrBpm: Int? = null
        private set
    var lastRrMs: Int? = null
        private set
    var lastSampleTimestampUtc: Long = 0L
        private set
    var lastDisconnectTimeUtc: Long? = null
        private set
    var lastDisconnectReason: String? = null
        private set
    var reconnectAttempts: Int = 0
        private set

    private var reconnectJob: Job? = null
    var isBluetoothEnabled: Boolean = true
        private set
    private var hasRequiredPermissions: Boolean = true

    // Stati di ciclo di vita distinti (Task 08C.1 & 08C.2)
    var isGattConnected: Boolean = false
        private set
    var isSubscribed: Boolean = false
        private set
    var isStreaming: Boolean = false
        private set
    var isPersisting: Boolean = false
        private set
    var isStreamStale: Boolean = false
        private set
    var wasReconnected: Boolean = false
        private set

    private var lastNotificationMonotonicMs: Long = 0L
    private var freshnessWatchdogJob: Job? = null
    private var connectingTimeoutJob: Job? = null

    private var firstNotificationLogged = false
    private var firstDecodedLogged = false
    private var firstPersistedLogged = false

    // Eventi verso Flutter
    data class CoordinatorUpdate(
        val stateName: String,
        val isAlwaysOn: Boolean,
        val isManual: Boolean,
        val sessionId: String?,
        val totalSamples: Int,
        val totalRr: Int,
        val lastHr: Int?,
        val lastRr: Int?,
        val lastSampleTimeUtc: Long?,
        val disconnectionsCount: Int,
        val gapsCount: Int,
        val maxGapMs: Long,
        val isGattConnected: Boolean = false,
        val isSubscribed: Boolean = false,
        val isStreaming: Boolean = false,
        val isPersisting: Boolean = false,
        val isStreamStale: Boolean = false,
        val isBluetoothEnabled: Boolean = true,
    )

    private val _updatesFlow = MutableSharedFlow<CoordinatorUpdate>(extraBufferCapacity = 64)
    val updatesFlow: SharedFlow<CoordinatorUpdate> = _updatesFlow.asSharedFlow()

    init {
        // Carica impostazioni persistite da SQLite
        isAlwaysOnEnabled = storageEngine.isAlwaysOnEnabled()
        storageEngine.getSetting("target_mac")?.let { targetMacAddress = it }
        storageEngine.getSetting("target_name")?.let { targetDeviceName = it }

        Log.i(TAG, "RecordingCoordinator inizializzato. Always-On=$isAlwaysOnEnabled, target=$targetMacAddress ($targetDeviceName)")

        if (isAlwaysOnEnabled) {
            stateMachine.processEvent(BleEvent.DeviceConfigured(targetMacAddress, targetDeviceName))
        }

        startFreshnessWatchdog()
    }

    // ==========================================
    // API DI CONTROLLO ALWAYS-ON E MANUALE
    // ==========================================

    fun setAlwaysOnEnabled(enabled: Boolean): Boolean = synchronized(stateLock) {
        Log.i(TAG, "setAlwaysOnEnabled: $enabled (stato precedente: $isAlwaysOnEnabled)")
        isAlwaysOnEnabled = enabled
        storageEngine.setAlwaysOnEnabled(enabled)
        storageEngine.setSetting("target_mac", targetMacAddress)
        storageEngine.setSetting("target_name", targetDeviceName)

        storageEngine.insertConnectionEvent(
            eventType = if (enabled) "ALWAYS_ON_ENABLED" else "ALWAYS_ON_DISABLED",
            details = "Impostazione utente Always-On modificata",
            sessionId = activeSessionId
        )

        if (enabled) {
            stateMachine.processEvent(BleEvent.DeviceConfigured(targetMacAddress, targetDeviceName))
            ensureSessionStarted(reason = "ALWAYS_ON_ENABLE")
            triggerConnection()
        } else {
            if (!isManualRecordingActive) {
                // Se non c'è una sessione manuale in corso, disconnetti e chiudi
                reconnectJob?.cancel()
                reconnectJob = null
                closeActiveSegment("ALWAYS_ON_DISABLED")
                disconnectAction()
                stateMachine.processEvent(BleEvent.UserDisable)
            } else {
                Log.i(TAG, "Always-On disabilitato ma sessione manuale ancora attiva. Connessione mantenuta per Night Recorder.")
            }
        }
        emitUpdate()
        return true
    }

    fun startManualRecording(sessionId: String): Boolean = synchronized(stateLock) {
        Log.i(TAG, "startManualRecording: session=$sessionId (Always-On attivo: $isAlwaysOnEnabled)")
        isManualRecordingActive = true

        if (activeSessionId == null) {
            activeSessionId = sessionId
            storageEngine.startNightSession(
                sessionId = sessionId,
                deviceAddress = targetMacAddress,
                deviceName = targetDeviceName,
                startTimeUtc = System.currentTimeMillis()
            )
        }

        storageEngine.insertConnectionEvent(
            eventType = "MANUAL_RECORDING_START",
            details = "Avvio manuale Night Recorder",
            sessionId = activeSessionId
        )

        if (currentState is BleState.Streaming) {
            Log.i(TAG, "Connessione già in streaming; la vista manuale si aggancia alla sessione attiva.")
            emitUpdate()
            return true
        }

        if (currentState is BleState.Disabled) {
            stateMachine.processEvent(BleEvent.DeviceConfigured(targetMacAddress, targetDeviceName))
        }

        triggerConnection()
        emitUpdate()
        return true
    }

    fun stopManualRecording(disableAlwaysOn: Boolean = false): Map<String, Any?> = synchronized(stateLock) {
        val sessId = activeSessionId ?: "manual_stop_${System.currentTimeMillis()}"
        Log.i(TAG, "stopManualRecording: sessId=$sessId, disableAlwaysOn=$disableAlwaysOn, isAlwaysOnEnabled=$isAlwaysOnEnabled")

        isManualRecordingActive = false

        if (disableAlwaysOn) {
            isAlwaysOnEnabled = false
            storageEngine.setAlwaysOnEnabled(false)
            reconnectJob?.cancel()
            reconnectJob = null
            closeActiveSegment("MANUAL_STOP_AND_DISABLE")
            storageEngine.endNightSession(sessId, "COMPLETED", System.currentTimeMillis())
            disconnectAction()
            stateMachine.processEvent(BleEvent.UserDisable)
            activeSessionId = null
        } else if (isAlwaysOnEnabled) {
            // Always-On rimane attivo: finalizza snapshot ma mantieni BLE in background!
            storageEngine.insertConnectionEvent(
                eventType = "MANUAL_RECORDING_DETACHED",
                details = "Interfaccia Night Recorder chiusa; Always-On continua in background",
                sessionId = sessId
            )
            // Non chiudiamo la connessione GATT
        } else {
            // Né manuale né Always-On attivi
            reconnectJob?.cancel()
            reconnectJob = null
            closeActiveSegment("MANUAL_STOP")
            storageEngine.endNightSession(sessId, "COMPLETED", System.currentTimeMillis())
            disconnectAction()
            stateMachine.processEvent(BleEvent.UserDisable)
            activeSessionId = null
        }

        val summary = storageEngine.getNightSessionSummary(sessId)
        emitUpdate()
        return summary
    }

    // ==========================================
    // CALLBACK EVENTI BLE (GATT, SENSOR, LINK)
    // ==========================================

    fun onGattConnected(macAddress: String) {
        synchronized(stateLock) {
            Log.i(TAG, "onGattConnected su $macAddress")
            isGattConnected = true
            isStreamStale = false
            reconnectAttempts = 0
            reconnectJob?.cancel()
            reconnectJob = null
            startConnectingTimeout() // Riarma timeout per la fase di discovery/subscription

            storageEngine.insertConnectionEvent(
                eventType = "GATT_CONNECTED",
                reasonCode = 0,
                details = "Connessione stabilita con $macAddress",
                sessionId = activeSessionId
            )

            stateMachine.processEvent(BleEvent.GattConnectedSuccess(macAddress))
            emitUpdate()
        }
    }

    fun onServicesDiscovered(serviceCount: Int = 0, servicesInfo: String = "") {
        synchronized(stateLock) {
            Log.i(TAG, "onServicesDiscovered: $serviceCount servizi ($servicesInfo)")
            storageEngine.insertConnectionEvent(
                eventType = "SERVICES_DISCOVERED",
                reasonCode = serviceCount,
                details = if (servicesInfo.isNotEmpty()) servicesInfo else "$serviceCount servizi GATT scoperti",
                sessionId = activeSessionId
            )
            stateMachine.processEvent(BleEvent.ServicesDiscoveredSuccess)
            emitUpdate()
        }
    }

    fun onHrCharacteristicFound(properties: Int) {
        synchronized(stateLock) {
            val propsHex = "0x" + Integer.toHexString(properties).uppercase()
            Log.i(TAG, "onHrCharacteristicFound: props=$propsHex")
            storageEngine.insertConnectionEvent(
                eventType = "HR_CHAR_FOUND",
                reasonCode = properties,
                details = "Caratteristica Heart Rate 0x2A37 trovata (properties=$propsHex)",
                sessionId = activeSessionId
            )
            emitUpdate()
        }
    }

    fun onCccdWriteStarted() {
        synchronized(stateLock) {
            Log.i(TAG, "onCccdWriteStarted: scrittura 0x2902 su 0x2A37")
            storageEngine.insertConnectionEvent(
                eventType = "CCCD_WRITE_STARTED",
                reasonCode = 0,
                details = "Scrittura ENABLE_NOTIFICATION_VALUE (0x0001) su descrittore CCCD 0x2902",
                sessionId = activeSessionId
            )
            emitUpdate()
        }
    }

    fun onHrSubscribed(status: Int = 0, step: Int = 1, total: Int = 1) {
        synchronized(stateLock) {
            Log.i(TAG, "onHrSubscribed: status=$status ($step/$total)")
            if (status == 0) {
                isSubscribed = true
                storageEngine.insertConnectionEvent(
                    eventType = "CCCD_WRITE_SUCCESS",
                    reasonCode = 0,
                    details = "Sottoscrizione 0x2A37 confermata con GATT_SUCCESS (status=0)",
                    sessionId = activeSessionId
                )
                stateMachine.processEvent(BleEvent.SubscribedToHr(step, total))
            } else {
                isSubscribed = false
                storageEngine.insertConnectionEvent(
                    eventType = "CCCD_WRITE_FAILED",
                    reasonCode = status,
                    details = "Scrittura CCCD fallita con status GATT $status",
                    sessionId = activeSessionId
                )
            }
            emitUpdate()
        }
    }

    fun onHrNotificationReceived(byteCount: Int, hexPreview: String) {
        synchronized(stateLock) {
            if (!firstNotificationLogged) {
                firstNotificationLogged = true
                storageEngine.insertConnectionEvent(
                    eventType = "FIRST_HR_NOTIFICATION",
                    reasonCode = byteCount,
                    details = "Prima notifica raw 0x2A37 ($byteCount bytes): $hexPreview",
                    sessionId = activeSessionId
                )
                emitUpdate()
            }
        }
    }

    fun onHrSampleDecoded(hrBpm: Int, rrCount: Int) {
        synchronized(stateLock) {
            if (!firstDecodedLogged) {
                firstDecodedLogged = true
                storageEngine.insertConnectionEvent(
                    eventType = "FIRST_HR_DECODED",
                    reasonCode = hrBpm,
                    details = "Primo battito decodificato: $hrBpm BPM | $rrCount intervalli R-R",
                    sessionId = activeSessionId
                )
                emitUpdate()
            }
        }
    }

    fun onHrSampleReceived(
        hrBpm: Int,
        rawRrIntervals: List<Int>,
        flags: Int,
        sensorContact: Int,
        origin: String = "GATT_0x2A37"
    ) {
        synchronized(stateLock) {
            val nowUtc = System.currentTimeMillis()
            val monoMs = System.nanoTime() / 1_000_000L

            ensureSessionStarted(reason = "FIRST_SAMPLE")
            val sessId = activeSessionId ?: return

            // Rilevamento lacune temporali (gap nominale = 1000ms a 1Hz)
            if (lastSampleTimestampUtc > 0L) {
                val gapDelta = nowUtc - lastSampleTimestampUtc
                if (gapDelta > 2500L) {
                    gapsDetectedCount.incrementAndGet()
                    if (gapDelta > maxGapMs.get()) {
                        maxGapMs.set(gapDelta)
                    }
                    if (gapDelta > segmentMaxGapMs) {
                        segmentMaxGapMs = gapDelta
                    }
                    storageEngine.insertConnectionEvent(
                        eventType = "GAP_DETECTED",
                        reasonCode = gapDelta.toInt(),
                        details = "Gap temporale di ${gapDelta}ms tra campioni",
                        sessionId = sessId,
                        timestampUtc = nowUtc,
                        monotonicMillis = monoMs
                    )
                }
            }

            // Salva campione HR
            val sampleId = storageEngine.insertNightSample(
                sessionId = sessId,
                timestampUtc = nowUtc,
                monotonicMillis = monoMs,
                hrBpm = hrBpm,
                flags = flags,
                sensorContact = sensorContact,
                rrStatus = if (rawRrIntervals.isNotEmpty()) "AVAILABLE" else "NONE",
                origin = origin,
                connState = "STREAMING"
            )

            // Salva intervalli R-R con i valori in ms diretti (Regola Inviolabile 2)
            for ((idx, rawRr) in rawRrIntervals.withIndex()) {
                val rrMsDirect = rawRr
                val rrMs1024 = rawRr * 1000.0 / 1024.0
                storageEngine.insertNightRr(
                    sampleId = sampleId,
                    sessionId = sessId,
                    timestampUtc = nowUtc,
                    beatOrdinal = idx,
                    rrRaw = rawRr,
                    rrMsDirect = rrMsDirect,
                    rrMs1024 = rrMs1024
                )
            }

            if (!firstPersistedLogged) {
                firstPersistedLogged = true
                storageEngine.insertConnectionEvent(
                    eventType = "FIRST_HR_PERSISTED",
                    reasonCode = hrBpm,
                    details = "Primo record salvato in SQLite (sampleId=$sampleId, $hrBpm BPM)",
                    sessionId = sessId
                )
            }

            if (wasReconnected) {
                wasReconnected = false
                storageEngine.insertConnectionEvent(
                    eventType = "FIRST_HR_AFTER_RECONNECT",
                    reasonCode = hrBpm,
                    details = "Primo battito ricevuto dopo riconnessione ($hrBpm BPM)",
                    sessionId = sessId
                )
                storageEngine.insertConnectionEvent(
                    eventType = "FIRST_HR_PERSISTED_AFTER_RECONNECT",
                    reasonCode = hrBpm,
                    details = "Primo campione persistito in SQLite dopo riconnessione (sampleId=$sampleId)",
                    sessionId = sessId
                )
            }

            connectingTimeoutJob?.cancel()
            connectingTimeoutJob = null
            lastNotificationMonotonicMs = getMonotonicMs()
            isStreaming = true
            isPersisting = true
            isStreamStale = false
            totalSamplesCount.incrementAndGet()
            segmentHrCount++
            if (rawRrIntervals.isNotEmpty()) {
                totalRrCount.addAndGet(rawRrIntervals.size)
                segmentRrCount += rawRrIntervals.size
                lastRrMs = rawRrIntervals.last()
            }

            lastHrBpm = hrBpm
            lastSampleTimestampUtc = nowUtc

            // Se non ancora in STREAMING, questa notifica sancisce il passaggio ufficiale a STREAMING!
            if (currentState !is BleState.Streaming) {
                storageEngine.insertConnectionEvent(
                    eventType = "STREAMING",
                    reasonCode = hrBpm,
                    details = "Passaggio ufficiale allo stato STREAMING ($hrBpm BPM)",
                    sessionId = sessId
                )
                stateMachine.processEvent(
                    BleEvent.FirstValidHrNotification(
                        sessionId = sessId,
                        hrBpm = hrBpm,
                        totalSamples = totalSamplesCount.get()
                    )
                )
                // Avvia anche un segmento di registrazione se non attivo
                ensureSegmentStarted(reason = "STREAMING_STARTED")
            } else {
                stateMachine.processEvent(
                    BleEvent.HrSample(hrBpm = hrBpm, totalSamples = totalSamplesCount.get())
                )
            }

            // Aggiorna metriche del segmento corrente
            activeSegmentId?.let { segId ->
                storageEngine.updateRecordingSegmentMetrics(
                    segmentId = segId,
                    hrCount = segmentHrCount,
                    rrCount = segmentRrCount,
                    maxGapMs = segmentMaxGapMs
                )
            }

            emitUpdate()
        }
    }

    fun onGattDisconnected(status: Int, details: String? = null) {
        synchronized(stateLock) {
            val nowUtc = System.currentTimeMillis()
            Log.w(TAG, "onGattDisconnected: status=$status, details=$details")
            isGattConnected = false
            isSubscribed = false
            isStreaming = false
            isPersisting = false
            firstNotificationLogged = false
            firstDecodedLogged = false
            firstPersistedLogged = false

            lastDisconnectTimeUtc = nowUtc
            lastDisconnectReason = "GATT status $status: ${details ?: "Link loss"}"
            disconnectionsCount.incrementAndGet()

            closeActiveSegment("DISCONNECTED_STATUS_$status")

            storageEngine.insertConnectionEvent(
                eventType = "DISCONNECTED",
                reasonCode = status,
                details = lastDisconnectReason,
                sessionId = activeSessionId,
                timestampUtc = nowUtc
            )

            stateMachine.processEvent(BleEvent.Disconnection(status, details))

            if (isAlwaysOnEnabled || isManualRecordingActive) {
                scheduleReconnectBackoff()
            }
            emitUpdate()
        }
    }

    fun onBluetoothTurningOff() {
        synchronized(stateLock) {
            Log.w(TAG, "onBluetoothTurningOff: arresto operazioni in corso")
            storageEngine.insertConnectionEvent(
                eventType = "BLUETOOTH_TURNING_OFF",
                reasonCode = 0,
                details = "Adattatore Bluetooth in fase di disattivazione",
                sessionId = activeSessionId
            )
            isStreaming = false
            isPersisting = false
            isGattConnected = false
            isSubscribed = false
            isStreamStale = false
            reconnectJob?.cancel()
            reconnectJob = null
            connectingTimeoutJob?.cancel()
            connectingTimeoutJob = null
            emitUpdate()
        }
    }

    fun onBluetoothStateChanged(enabled: Boolean) {
        synchronized(stateLock) {
            Log.i(TAG, "onBluetoothStateChanged: enabled=$enabled")
            isBluetoothEnabled = enabled
            connectingTimeoutJob?.cancel()
            connectingTimeoutJob = null

            if (!enabled) {
                reconnectJob?.cancel()
                reconnectJob = null
                isGattConnected = false
                isSubscribed = false
                isStreaming = false
                isPersisting = false
                isStreamStale = false
                firstNotificationLogged = false
                firstDecodedLogged = false
                firstPersistedLogged = false

                closeActiveSegment("BLUETOOTH_OFF")
                storageEngine.insertConnectionEvent(
                    eventType = "BLUETOOTH_OFF",
                    details = "Adattatore Bluetooth disattivato",
                    sessionId = activeSessionId
                )
                stateMachine.processEvent(BleEvent.BluetoothTurnedOff)
            } else {
                storageEngine.insertConnectionEvent(
                    eventType = "BLUETOOTH_ON",
                    details = "Adattatore Bluetooth riattivato",
                    sessionId = activeSessionId
                )
                stateMachine.processEvent(BleEvent.BluetoothTurnedOn)
                if (isAlwaysOnEnabled || isManualRecordingActive) {
                    wasReconnected = true
                    reconnectAttempts = 0
                    storageEngine.insertConnectionEvent(
                        eventType = "RECONNECT_SCHEDULED",
                        reasonCode = 1,
                        details = "Riconnessione automatica programmata post riaccensione Bluetooth",
                        sessionId = activeSessionId
                    )
                    reconnectJob?.cancel()
                    reconnectJob = scope.launch {
                        delay(500L)
                        synchronized(stateLock) {
                            if (isBluetoothEnabled && hasRequiredPermissions && (isAlwaysOnEnabled || isManualRecordingActive)) {
                                triggerConnection()
                            }
                        }
                    }
                }
            }
            emitUpdate()
        }
    }

    fun onPermissionsStateChanged(hasPermissions: Boolean, missing: List<String>) {
        synchronized(stateLock) {
            hasRequiredPermissions = hasPermissions
            if (!hasPermissions) {
                reconnectJob?.cancel()
                reconnectJob = null
                closeActiveSegment("PERMISSIONS_REVOKED")
                storageEngine.insertConnectionEvent(
                    eventType = "PERMISSIONS_BLOCKED",
                    details = "Permessi mancanti: $missing",
                    sessionId = activeSessionId
                )
                stateMachine.processEvent(BleEvent.MissingPermissions(missing))
            } else if (currentState is BleState.PermissionBlocked) {
                stateMachine.processEvent(BleEvent.UserEnable)
                if (isAlwaysOnEnabled || isManualRecordingActive) {
                    triggerConnection()
                }
            }
            emitUpdate()
        }
    }

    // ==========================================
    // GESTIONE RICONNESSIONE E BACKOFF
    // ==========================================

    private fun scheduleReconnectBackoff() {
        if (!isBluetoothEnabled || !hasRequiredPermissions) return
        if (!isAlwaysOnEnabled && !isManualRecordingActive) return

        reconnectJob?.cancel()
        reconnectAttempts++

        // Backoff controllato: 0s -> 2s -> 5s -> 15s -> 30s -> 60s
        val backoffDelays = longArrayOf(0L, 2000L, 5000L, 15000L, 30000L, 60000L)
        val delayIndex = (reconnectAttempts - 1).coerceIn(0, backoffDelays.size - 1)
        val delayMs = backoffDelays[delayIndex]

        stateMachine.processEvent(BleEvent.ReconnectScheduled(reconnectAttempts, delayMs))

        storageEngine.insertConnectionEvent(
            eventType = "RECONNECT_SCHEDULED",
            reasonCode = reconnectAttempts,
            details = "Tentativo $reconnectAttempts programmato tra ${delayMs / 1000}s",
            sessionId = activeSessionId
        )

        Log.i(TAG, "Riconnessione programmata: tentativo=$reconnectAttempts, delay=${delayMs}ms")

        reconnectJob = scope.launch {
            if (delayMs > 0L) {
                delay(delayMs)
            }
            synchronized(stateLock) {
                if (isBluetoothEnabled && hasRequiredPermissions && (isAlwaysOnEnabled || isManualRecordingActive)) {
                    triggerConnection()
                }
            }
        }
    }

    fun triggerConnection() {
        if (!isBluetoothEnabled) {
            stateMachine.processEvent(BleEvent.BluetoothTurnedOff)
            return
        }
        if (!hasRequiredPermissions) {
            stateMachine.processEvent(BleEvent.MissingPermissions(listOf("BLUETOOTH_CONNECT")))
            return
        }

        // Prevenzione assoluta di connessioni GATT simultanee se già attive e non in stato stale
        if (currentState is BleState.Connecting || currentState is BleState.GattConnected ||
            currentState is BleState.DiscoveringServices || currentState is BleState.SubscribingHr ||
            (currentState is BleState.Streaming && !isStreamStale)) {
            Log.i(TAG, "triggerConnection ignorato: connessione già attiva o in corso (${currentState.name})")
            return
        }

        reconnectAttempts++
        storageEngine.insertConnectionEvent(
            eventType = "RECONNECT_ATTEMPT",
            reasonCode = reconnectAttempts,
            details = "Tentativo di connessione $reconnectAttempts verso $targetMacAddress",
            sessionId = activeSessionId
        )

        Log.i(TAG, "Avvio connessione GATT verso $targetMacAddress (tentativo $reconnectAttempts)")
        stateMachine.processEvent(BleEvent.StartConnecting(targetMacAddress))

        startConnectingTimeout()
        connectAction(targetMacAddress)
    }

    private fun startFreshnessWatchdog() {
        freshnessWatchdogJob?.cancel()
        freshnessWatchdogJob = scope.launch {
            while (isActive) {
                delay(FRESHNESS_CHECK_INTERVAL_MS)
                checkStreamFreshness()
            }
        }
    }

    fun checkStreamFreshness() {
        synchronized(stateLock) {
            if (isStreaming && lastNotificationMonotonicMs > 0L) {
                val elapsed = getMonotonicMs() - lastNotificationMonotonicMs
                if (elapsed > STREAM_FRESHNESS_TIMEOUT_MS) {
                    Log.w(TAG, "Flusso HR STALE: nessuna notifica da ${elapsed}ms (soglia: ${STREAM_FRESHNESS_TIMEOUT_MS}ms)")
                    handleStreamStale(elapsed)
                }
            }
        }
    }

    fun handleStreamStale(elapsedMs: Long) {
        synchronized(stateLock) {
            isStreaming = false
            isPersisting = false
            isStreamStale = true

            storageEngine.insertConnectionEvent(
                eventType = "STREAM_STALE",
                reasonCode = elapsedMs.toInt(),
                details = "Flusso HR interrotto: nessun campione ricevuto da ${elapsedMs}ms",
                sessionId = activeSessionId
            )

            closeActiveSegment("STREAM_STALE")
            stateMachine.processEvent(BleEvent.StreamStale(elapsedMs))

            wasReconnected = true
            disconnectAction()
            if (isAlwaysOnEnabled || isManualRecordingActive) {
                scheduleReconnectBackoff()
            }
            emitUpdate()
        }
    }

    private fun startConnectingTimeout() {
        connectingTimeoutJob?.cancel()
        connectingTimeoutJob = scope.launch {
            delay(CONNECTING_TIMEOUT_MS)
            synchronized(stateLock) {
                if (currentState is BleState.Connecting || currentState is BleState.GattConnected ||
                    currentState is BleState.DiscoveringServices || currentState is BleState.SubscribingHr) {
                    Log.w(TAG, "Timeout connessione/configurazione (${currentState.name})")
                    storageEngine.insertConnectionEvent(
                        eventType = "CONNECTION_TIMEOUT",
                        reasonCode = 0,
                        details = "Timeout dopo ${CONNECTING_TIMEOUT_MS / 1000}s nello stato ${currentState.name}",
                        sessionId = activeSessionId
                    )
                    stateMachine.processEvent(BleEvent.ConnectionTimeout(currentState.name))
                    disconnectAction()
                    if (isAlwaysOnEnabled || isManualRecordingActive) {
                        scheduleReconnectBackoff()
                    }
                    emitUpdate()
                }
            }
        }
    }

    private fun getMonotonicMs(): Long = try {
        android.os.SystemClock.elapsedRealtime()
    } catch (t: Throwable) {
        System.nanoTime() / 1_000_000L
    }

    // ==========================================
    // GESTIONE SESSIONE E SEGMENTI
    // ==========================================

    private fun ensureSessionStarted(reason: String) {
        if (activeSessionId == null) {
            val now = System.currentTimeMillis()
            val sessId = "night_${now}"
            activeSessionId = sessId
            storageEngine.startNightSession(
                sessionId = sessId,
                deviceAddress = targetMacAddress,
                deviceName = targetDeviceName,
                startTimeUtc = now
            )
            storageEngine.insertConnectionEvent(
                eventType = "SESSION_STARTED",
                details = "Nuova sessione logica: $sessId (motivo: $reason)",
                sessionId = sessId
            )
        }
    }

    private fun ensureSegmentStarted(reason: String) {
        if (activeSegmentId == null && activeSessionId != null) {
            val now = System.currentTimeMillis()
            val segId = "seg_${now}"
            activeSegmentId = segId
            segmentStartedAtUtc = now
            segmentHrCount = 0
            segmentRrCount = 0
            segmentMaxGapMs = 0L

            storageEngine.startRecordingSegment(
                segmentId = segId,
                sessionId = activeSessionId!!,
                startedAtUtc = now,
                startReason = reason
            )
            Log.i(TAG, "Aperto nuovo recording segment: $segId ($reason)")
        }
    }

    private fun closeActiveSegment(reason: String) {
        val segId = activeSegmentId ?: return
        val now = System.currentTimeMillis()
        storageEngine.endRecordingSegment(
            segmentId = segId,
            endedAtUtc = now,
            endReason = reason,
            hrCount = segmentHrCount,
            rrCount = segmentRrCount,
            maxGapMs = segmentMaxGapMs
        )
        Log.i(TAG, "Chiuso recording segment: $segId ($reason, campioni: $segmentHrCount, maxGap: ${segmentMaxGapMs}ms)")
        activeSegmentId = null
    }

    private fun handleStateTransition(from: BleState, to: BleState, event: BleEvent) {
        val title = if (isAlwaysOnEnabled) "Beveltry — Registrazione WHOOP attiva" else "WHOOP 5.0 — Beveltry"
        val text = when (to) {
            is BleState.Disabled -> "Registrazione automatica disattivata"
            is BleState.Associated -> "WHOOP B pronto per la connessione"
            is BleState.WaitingForDevice -> "In attesa del cinturino (tentativo ${to.attempt})..."
            is BleState.Connecting -> "Connessione in corso a ${to.macAddress}..."
            is BleState.GattConnected -> "Connessione stabilita. Configurazione..."
            is BleState.DiscoveringServices -> "Ricerca caratteristiche e notifiche..."
            is BleState.SubscribingHr -> "Configurazione canale battito 0x2A37..."
            is BleState.Streaming -> "ATTIVO: ${to.lastHrBpm} BPM | ${to.totalSamples} campioni"
            is BleState.ReconnectWait -> "Disconnesso. Riconnessione tra ${to.delayMs / 1000}s (tentativo ${to.attempt})..."
            is BleState.BluetoothDisabled -> "Bluetooth disattivato sullo smartphone"
            is BleState.PermissionBlocked -> "Permessi Bluetooth/Notifiche mancanti"
            is BleState.Error -> "Errore: ${to.reason}"
        }
        updateNotificationAction(title, text)
    }

    private fun emitUpdate() {
        val upd = CoordinatorUpdate(
            stateName = currentState.name,
            isAlwaysOn = isAlwaysOnEnabled,
            isManual = isManualRecordingActive,
            sessionId = activeSessionId,
            totalSamples = totalSamplesCount.get(),
            totalRr = totalRrCount.get(),
            lastHr = lastHrBpm,
            lastRr = lastRrMs,
            lastSampleTimeUtc = if (lastSampleTimestampUtc > 0L) lastSampleTimestampUtc else null,
            disconnectionsCount = disconnectionsCount.get(),
            gapsCount = gapsDetectedCount.get(),
            maxGapMs = maxGapMs.get(),
            isGattConnected = isGattConnected,
            isSubscribed = isSubscribed,
            isStreaming = isStreaming,
            isPersisting = isPersisting,
            isStreamStale = isStreamStale,
            isBluetoothEnabled = isBluetoothEnabled,
        )
        _updatesFlow.tryEmit(upd)
    }

    fun getDiagnostics(): Map<String, Any?> {
        val now = System.currentTimeMillis()
        val timeSinceLastSampleMs = if (lastSampleTimestampUtc > 0L) now - lastSampleTimestampUtc else null
        return mapOf(
            "isAlwaysOnEnabled" to isAlwaysOnEnabled,
            "isManualRecordingActive" to isManualRecordingActive,
            "bleState" to currentState.name,
            "isGattConnected" to isGattConnected,
            "isSubscribed" to isSubscribed,
            "isStreaming" to isStreaming,
            "isPersisting" to isPersisting,
            "isStreamStale" to isStreamStale,
            "isBluetoothEnabled" to isBluetoothEnabled,
            "hasPermissions" to hasRequiredPermissions,
            "activeSessionId" to activeSessionId,
            "activeSegmentId" to activeSegmentId,
            "totalSamples" to totalSamplesCount.get(),
            "totalRr" to totalRrCount.get(),
            "lastHrBpm" to lastHrBpm,
            "lastRrMs" to lastRrMs,
            "lastSampleTimestampUtc" to if (lastSampleTimestampUtc > 0L) lastSampleTimestampUtc else null,
            "timeSinceLastSampleMs" to timeSinceLastSampleMs,
            "disconnectionsCount" to disconnectionsCount.get(),
            "lastDisconnectTimeUtc" to lastDisconnectTimeUtc,
            "lastDisconnectReason" to lastDisconnectReason,
            "reconnectAttempts" to reconnectAttempts,
            "gapsDetectedCount" to gapsDetectedCount.get(),
            "maxGapMs" to maxGapMs.get(),
            "targetMacAddress" to targetMacAddress,
            "targetDeviceName" to targetDeviceName
        )
    }

    companion object {
        private const val TAG = "RecordingCoordinator"
        const val STREAM_FRESHNESS_TIMEOUT_MS = 6000L // 6s soglia freschezza WHOOP 5.0 (Task 08C.2)
        const val FRESHNESS_CHECK_INTERVAL_MS = 2000L // Verifica ogni 2s
        const val CONNECTING_TIMEOUT_MS = 20000L      // 20s timeout configurazione BLE
    }
}
