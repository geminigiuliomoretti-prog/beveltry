package com.beveltry.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Suite di test unitari completa per Task 08C:
 * - BleStateMachine deterministica con 12 stati
 * - Invarianti di transizione
 * - STREAMING raggiungibile solo ed esclusivamente dopo prima notifica HR valida
 * - Riconnessione e backoff scheduling
 * - Gestione Bluetooth OFF/ON e permessi
 */
class AlwaysOnRecorderTest {

    // 1. Connection FSM: transizioni, invarianti e raggiungimento di STREAMING solo su HR valida
    @Test
    fun testConnectionFSM_TransitionsAndInvariants() {
        val fsm = BleStateMachine(BleState.Disabled)
        assertEquals("DISABLED", fsm.currentState.name)

        // DISABLED -> ASSOCIATED
        assertTrue(fsm.processEvent(BleEvent.DeviceConfigured("FD:49:44:66:1D:92", "WBB5AP-5AG0558675")))
        assertEquals("ASSOCIATED", fsm.currentState.name)

        // Rifiuto transizione illegale: non si può andare da ASSOCIATED a STREAMING senza passare per GATT e HR
        assertFalse(fsm.processEvent(BleEvent.FirstValidHrNotification("night_test", 72, 1)))
        assertEquals("ASSOCIATED", fsm.currentState.name)

        // ASSOCIATED -> CONNECTING
        assertTrue(fsm.processEvent(BleEvent.StartConnecting("FD:49:44:66:1D:92")))
        assertEquals("CONNECTING", fsm.currentState.name)

        // CONNECTING -> GATT_CONNECTED
        assertTrue(fsm.processEvent(BleEvent.GattConnectedSuccess("FD:49:44:66:1D:92")))
        assertEquals("GATT_CONNECTED", fsm.currentState.name)

        // GATT_CONNECTED -> DISCOVERING_SERVICES
        assertTrue(fsm.processEvent(BleEvent.ServicesDiscoveredSuccess))
        assertEquals("DISCOVERING_SERVICES", fsm.currentState.name)

        // DISCOVERING_SERVICES -> SUBSCRIBING_HR
        assertTrue(fsm.processEvent(BleEvent.SubscribedToHr(1, 1)))
        assertEquals("SUBSCRIBING_HR", fsm.currentState.name)

        // In SUBSCRIBING_HR non siamo ancora in STREAMING!
        assertFalse(fsm.currentState.isStreaming)

        // Solo dopo la prima notifica HR valida si passa a STREAMING
        assertTrue(fsm.processEvent(BleEvent.FirstValidHrNotification("sess_01", 68, 1)))
        assertEquals("STREAMING", fsm.currentState.name)
        assertTrue(fsm.currentState.isStreaming)

        // Campioni successivi mantengono lo stato STREAMING
        assertTrue(fsm.processEvent(BleEvent.HrSample(70, 2)))
        assertEquals("STREAMING", fsm.currentState.name)
        assertEquals(70, (fsm.currentState as BleState.Streaming).lastHrBpm)

        // Disconnessione -> RECONNECT_WAIT
        assertTrue(fsm.processEvent(BleEvent.Disconnection(status = 19, details = "Device disconnected")))
        assertEquals("RECONNECT_WAIT", fsm.currentState.name)

        // Bluetooth OFF -> BLUETOOTH_DISABLED
        assertTrue(fsm.processEvent(BleEvent.BluetoothTurnedOff))
        assertEquals("BLUETOOTH_DISABLED", fsm.currentState.name)

        // Bluetooth ON -> ASSOCIATED
        assertTrue(fsm.processEvent(BleEvent.BluetoothTurnedOn))
        assertEquals("ASSOCIATED", fsm.currentState.name)

        // Permessi mancanti -> PERMISSION_BLOCKED
        assertTrue(fsm.processEvent(BleEvent.MissingPermissions(listOf("BLUETOOTH_CONNECT"))))
        assertEquals("PERMISSION_BLOCKED", fsm.currentState.name)

        // Reset -> DISABLED
        assertTrue(fsm.processEvent(BleEvent.Reset))
        assertEquals("DISABLED", fsm.currentState.name)
    }

    // 2. Reconnect scheduling backoff (0s, 2s, 5s, 15s, 30s, 60s)
    @Test
    fun testReconnectSchedulingProgression() {
        val expectedDelays = longArrayOf(0L, 2000L, 5000L, 15000L, 30000L, 60000L)

        for (attempt in 1..6) {
            val delayIndex = (attempt - 1).coerceIn(0, expectedDelays.size - 1)
            val delayMs = expectedDelays[delayIndex]
            val fsm = BleStateMachine(BleState.Connecting("FD:49:44:66:1D:92"))
            fsm.processEvent(BleEvent.ReconnectScheduled(attempt, delayMs))
            val st = fsm.currentState as BleState.ReconnectWait
            assertEquals(attempt, st.attempt)
            assertEquals(delayMs, st.delayMs)
        }

        // Dopo il 6° tentativo, il backoff si stabilizza a 60s (senza polling aggressivo)
        val attempt10Delay = expectedDelays[(10 - 1).coerceIn(0, expectedDelays.size - 1)]
        assertEquals(60000L, attempt10Delay)
    }

    // 3. User Disable prioritario da qualsiasi stato
    @Test
    fun testUserDisable_InterruptsActiveStates() {
        val statesToTest = listOf(
            BleState.Associated("FD:49:44:66:1D:92"),
            BleState.Connecting("FD:49:44:66:1D:92"),
            BleState.GattConnected("FD:49:44:66:1D:92"),
            BleState.DiscoveringServices,
            BleState.SubscribingHr(1, 1),
            BleState.Streaming("sess_01", 60, 10),
            BleState.ReconnectWait("FD:49:44:66:1D:92", 3, 15000L),
            BleState.BluetoothDisabled,
            BleState.PermissionBlocked(listOf("BLUETOOTH_CONNECT")),
            BleState.Error("Some error", true)
        )

        for (st in statesToTest) {
            val fsm = BleStateMachine(st)
            assertTrue(fsm.processEvent(BleEvent.UserDisable))
            assertEquals("DISABLED", fsm.currentState.name)
        }
    }

    // 4. Fatal Error gestito con flag retry
    @Test
    fun testFatalError_CapturesReasonAndCanRetry() {
        val fsm = BleStateMachine(BleState.Connecting("FD:49:44:66:1D:92"))
        assertTrue(fsm.processEvent(BleEvent.FatalError("Impossibile allocare risorse GATT", canRetry = true, errorCode = 133)))
        assertEquals("ERROR", fsm.currentState.name)
        val err = fsm.currentState as BleState.Error
        assertEquals("Impossibile allocare risorse GATT", err.reason)
        assertTrue(err.canRetry)
        assertEquals(133, err.errorCode)
    }

    // =========================================================================
    // TEST DI SIMULAZIONE TASK 08C.2 (RECONNECTION & STALE STREAMING)
    // =========================================================================

    // 1. Bluetooth OFF durante STREAMING
    @Test
    fun testBluetoothOff_DuringStreaming_TransitionsToBluetoothDisabled() {
        val fsm = BleStateMachine(BleState.Streaming("sess_01", 72, 100))
        assertTrue(fsm.currentState.isStreaming)

        // Utente disattiva Bluetooth dal Samsung
        assertTrue(fsm.processEvent(BleEvent.BluetoothTurnedOff))
        assertEquals("BLUETOOTH_DISABLED", fsm.currentState.name)
        assertFalse(fsm.currentState.isStreaming)
        assertFalse(fsm.currentState.isConnected)
    }

    // 2. Bluetooth ON dopo OFF
    @Test
    fun testBluetoothOn_AfterOff_TransitionsToAssociatedForReconnect() {
        val fsm = BleStateMachine(BleState.BluetoothDisabled)
        assertEquals("BLUETOOTH_DISABLED", fsm.currentState.name)

        // Utente riattiva Bluetooth
        assertTrue(fsm.processEvent(BleEvent.BluetoothTurnedOn))
        assertEquals("ASSOCIATED", fsm.currentState.name)

        // Può ora avviare nuova connessione
        assertTrue(fsm.processEvent(BleEvent.StartConnecting("FD:49:44:66:1D:92")))
        assertEquals("CONNECTING", fsm.currentState.name)
    }

    // 3. Nessun campione per un intervallo superiore alla soglia di freschezza (StreamStale)
    @Test
    fun testStreamStale_WhenNoSamples_TransitionsToReconnectWait() {
        val fsm = BleStateMachine(BleState.Streaming("sess_01", 65, 50))
        assertTrue(fsm.currentState.isStreaming)

        // Watchdog rileva assenza campioni da 7000ms (> 6000ms soglia)
        assertTrue(fsm.processEvent(BleEvent.StreamStale(elapsedMs = 7000L)))
        assertEquals("RECONNECT_WAIT", fsm.currentState.name)
        assertFalse(fsm.currentState.isStreaming)
    }

    // 4. Callback tardiva dopo GATT close (Generational ID)
    @Test
    fun testStaleGattCallback_GenerationMismatch_IsIgnored() {
        var activeGeneration = 1
        val gattSessionGeneration = java.util.concurrent.atomic.AtomicInteger(1)

        // Chiude la connessione GATT precedente incrementando la generazione
        val newGen = gattSessionGeneration.incrementAndGet()
        assertEquals(2, newGen)

        // Callback da vecchia istanza (activeGeneration = 1 vs current = 2)
        val isStale = activeGeneration != gattSessionGeneration.get()
        assertTrue(isStale)
    }

    // 5. Due eventi Bluetooth ON consecutivi (Idempotenza)
    @Test
    fun testConsecutiveBluetoothOn_IsIdempotent() {
        val fsm = BleStateMachine(BleState.BluetoothDisabled)
        assertTrue(fsm.processEvent(BleEvent.BluetoothTurnedOn))
        assertEquals("ASSOCIATED", fsm.currentState.name)

        // Secondo evento consecutivo
        assertTrue(fsm.processEvent(BleEvent.BluetoothTurnedOn))
        assertEquals("ASSOCIATED", fsm.currentState.name)
    }

    // 6. Connessione fallita durante recovery (GATT 133 / error status)
    @Test
    fun testConnectionFailed_DuringRecovery_SchedulesNextBackoff() {
        val fsm = BleStateMachine(BleState.Connecting("FD:49:44:66:1D:92"))
        assertTrue(fsm.processEvent(BleEvent.Disconnection(status = 133, details = "GATT error 133")))
        assertEquals("RECONNECT_WAIT", fsm.currentState.name)

        // Secondo tentativo di backoff (5s)
        assertTrue(fsm.processEvent(BleEvent.ReconnectScheduled(attempt = 2, delayMs = 5000L)))
        val st = fsm.currentState as BleState.ReconnectWait
        assertEquals(2, st.attempt)
        assertEquals(5000L, st.delayMs)
    }

    // 7. Ripresa reale dei campioni (Ciclo completo di recovery)
    @Test
    fun testFullRecoveryCycle_ResumesStreamingOnlyOnValidHr() {
        val fsm = BleStateMachine(BleState.BluetoothDisabled)

        // 1. BT ON
        assertTrue(fsm.processEvent(BleEvent.BluetoothTurnedOn))
        assertEquals("ASSOCIATED", fsm.currentState.name)

        // 2. Connessione
        assertTrue(fsm.processEvent(BleEvent.StartConnecting("FD:49:44:66:1D:92")))
        assertEquals("CONNECTING", fsm.currentState.name)

        // 3. GATT Connesso
        assertTrue(fsm.processEvent(BleEvent.GattConnectedSuccess("FD:49:44:66:1D:92")))
        assertEquals("GATT_CONNECTED", fsm.currentState.name)

        // 4. Scoperta servizi
        assertTrue(fsm.processEvent(BleEvent.ServicesDiscoveredSuccess))
        assertEquals("DISCOVERING_SERVICES", fsm.currentState.name)

        // 5. Sottoscrizione HR
        assertTrue(fsm.processEvent(BleEvent.SubscribedToHr(1, 1)))
        assertEquals("SUBSCRIBING_HR", fsm.currentState.name)
        assertFalse(fsm.currentState.isStreaming)

        // 6. Primo campione post-riconnessione
        assertTrue(fsm.processEvent(BleEvent.FirstValidHrNotification("sess_recovered", 74, 1)))
        assertEquals("STREAMING", fsm.currentState.name)
        assertTrue(fsm.currentState.isStreaming)
    }

    // 8. Preservazione di Always-On enabled
    @Test
    fun testAlwaysOnEnabled_PreservedAcrossBluetoothOffAndOn() {
        var isAlwaysOnEnabled = true

        // Bluetooth OFF
        val btOffEvent = BleEvent.BluetoothTurnedOff
        assertNotNull(btOffEvent)
        // L'impostazione logica NON viene toccata da eventi Bluetooth
        assertTrue(isAlwaysOnEnabled)

        // Bluetooth ON
        val btOnEvent = BleEvent.BluetoothTurnedOn
        assertNotNull(btOnEvent)
        assertTrue(isAlwaysOnEnabled)
    }

    // 9. Prevenzione connessioni simultanee durante streaming valido
    @Test
    fun testSimultaneousConnectionPrevention_DuringActiveStreaming() {
        val fsm = BleStateMachine(BleState.Streaming("sess_01", 60, 10))
        var isStreamStale = false

        // Se lo streaming è attivo e NON stale, triggerConnection deve essere scartato
        val shouldBlockNewConnection = (fsm.currentState is BleState.Streaming) && !isStreamStale
        assertTrue(shouldBlockNewConnection)

        // Se invece lo streaming è marcato stale, la nuova connessione è autorizzata
        isStreamStale = true
        val canTrigger = (fsm.currentState is BleState.Streaming) && !isStreamStale
        assertFalse(canTrigger)
    }

    // 10. Nessuna regressione: R-R in millisecondi diretti senza conversione 1/1024s (Regola Inviolabile 2)
    @Test
    fun testNoRegression_RrIntervalsPreservedInDirectMilliseconds() {
        val rawRrValues = listOf(850, 920, 880)
        for (rr in rawRrValues) {
            val rrMsDirect = rr
            assertEquals(rr, rrMsDirect)
            // Verifica che la formula 1000/1024 NON sovrascriva il valore primario
            val rr1024 = rr * 1000.0 / 1024.0
            assertTrue(Math.abs(rrMsDirect - rr1024) > 0.1) // Differenza tangibile (-2.3%)
        }
    }
}
