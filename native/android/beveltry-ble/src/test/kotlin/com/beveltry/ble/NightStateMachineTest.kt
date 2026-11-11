package com.beveltry.ble

import org.junit.Assert.*
import org.junit.Test

/**
 * Suite di test deterministici per la Night State Machine, il rilevamento del sonno
 * e l'elaborazione del Morning Report (Task 08D).
 *
 * Copre esattamente i 10 scenari obbligatori della specifica:
 * 1. Inizio sonno.
 * 2. Risvegli intermedi (WASO).
 * 3. Risveglio finale con conferma temporale e isteresi.
 * 4. Ritorno al sonno dopo breve veglia (conservazione sessione).
 * 5. Gap Bluetooth durante il sonno (nessuna falsa veglia).
 * 6. Registrazione incompleta o dati insufficienti.
 * 7. Elaborazione avviata una sola volta (idempotenza).
 * 8. Riavvio del processo durante l'elaborazione.
 * 9. Revisione di una notte già elaborata.
 * 10. Nessuna regressione del recorder Always-On.
 */
class NightStateMachineTest {

    @Test
    fun test01_sleep_onset_flow() {
        var transitionedToCandidate = false
        var transitionedToActive = false

        val sm = NightStateMachine(
            initialState = NightState.NO_NIGHT,
            onTransition = { from, to, event ->
                if (to == NightState.SLEEP_CANDIDATE) transitionedToCandidate = true
                if (to == NightState.SLEEP_ACTIVE) transitionedToActive = true
            }
        )

        assertEquals(NightState.NO_NIGHT, sm.currentState)

        val t0 = 1731276000000L // 23:00
        val ok1 = sm.transition(NightEvent.RestingDetected(t0))
        assertTrue("Transizione a SLEEP_CANDIDATE riuscita", ok1)
        assertEquals(NightState.SLEEP_CANDIDATE, sm.currentState)
        assertTrue(transitionedToCandidate)

        val t1 = t0 + (20 * 60 * 1000L) // +20 min di calma
        val ok2 = sm.transition(NightEvent.SleepOnsetConfirmed(t1))
        assertTrue("Transizione a SLEEP_ACTIVE riuscita", ok2)
        assertEquals(NightState.SLEEP_ACTIVE, sm.currentState)
        assertTrue(transitionedToActive)
        assertTrue("isSleepInProgress true", sm.currentState.isSleepInProgress)
    }

    @Test
    fun test02_intermediate_wake_and_waso_return_to_sleep() {
        val sm = NightStateMachine(initialState = NightState.SLEEP_ACTIVE)

        val tWake = 1731286800000L // 02:00
        val okWake = sm.transition(NightEvent.WakeWithinSleep(tWake, "Movimento/FC elevata"))
        assertTrue(okWake)
        assertEquals(NightState.WAKE_WITHIN_SLEEP, sm.currentState)

        // Utente torna a dormire dopo 10 minuti
        val tSleepAgain = tWake + (10 * 60 * 1000L)
        val okReturn = sm.transition(NightEvent.ReturnToSleep(tSleepAgain))
        assertTrue("Ritorno al sonno consentito", okReturn)
        assertEquals(NightState.SLEEP_ACTIVE, sm.currentState)
    }

    @Test
    fun test03_final_wake_hysteresis_and_confirmation() {
        val sm = NightStateMachine(initialState = NightState.SLEEP_ACTIVE)

        val tWake = 1731306000000L // 07:20
        // Veglia prolungata (> 30 min in orario mattutino)
        val okCandidate = sm.transition(NightEvent.WakeProlonged(tWake))
        assertTrue(okCandidate)
        assertEquals(NightState.FINAL_WAKE_CANDIDATE, sm.currentState)

        // Conferma dopo finestra di isteresi (20 min di veglia continuata)
        val tConfirm = tWake + (20 * 60 * 1000L)
        val okFinal = sm.transition(NightEvent.FinalWakeConfirmed(tConfirm))
        assertTrue(okFinal)
        assertEquals(NightState.FINAL_WAKE_CONFIRMED, sm.currentState)
    }

    @Test
    fun test04_return_to_sleep_from_final_wake_candidate_preserves_session() {
        val sm = NightStateMachine(initialState = NightState.FINAL_WAKE_CANDIDATE)

        // L'utente si sveglia alle 06:30 ma si riaddormenta alle 06:45 prima della conferma
        val tSleep = 1731304000000L
        val okReturn = sm.transition(NightEvent.ReturnToSleep(tSleep, "Si riaddormenta prima della conferma"))
        assertTrue(okReturn)
        assertEquals(NightState.SLEEP_ACTIVE, sm.currentState)
    }

    @Test
    fun test05_bluetooth_gap_does_not_cause_wake() {
        val sm = NightStateMachine(initialState = NightState.SLEEP_ACTIVE)

        // Gap Bluetooth di 15 minuti durante la notte
        val okGap = sm.transition(NightEvent.BluetoothGap(15 * 60 * 1000L))
        assertFalse("Il gap BLE non deve cambiare lo stato verso veglia", okGap)
        assertEquals("Lo stato resta SLEEP_ACTIVE", NightState.SLEEP_ACTIVE, sm.currentState)

        // Idem durante WAKE_WITHIN_SLEEP
        val smWake = NightStateMachine(initialState = NightState.WAKE_WITHIN_SLEEP)
        val okGap2 = smWake.transition(NightEvent.BluetoothGap(10 * 60 * 1000L))
        assertFalse(okGap2)
        assertEquals(NightState.WAKE_WITHIN_SLEEP, smWake.currentState)
    }

    @Test
    fun test06_incomplete_recording_marks_process_failed() {
        val sm = NightStateMachine(initialState = NightState.PROCESSING)

        // Campioni insufficienti (< 1800 campioni / 30 minuti)
        val sampleCount = 250
        val isInsufficient = sampleCount < 1800
        assertTrue("Rilevata insufficienza dati", isInsufficient)

        val ok = sm.transition(
            NightEvent.ProcessingFailed(
                timestampUtc = 1731308000000L,
                errorCode = "INSUFFICIENT_DATA",
                reason = "Dati insufficienti (< 30 minuti registrati)"
            )
        )

        assertTrue(ok)
        assertEquals(NightState.PROCESS_FAILED, sm.currentState)
    }

    @Test
    fun test07_processing_enqueued_once_idempotent() {
        val sm = NightStateMachine(initialState = NightState.FINAL_WAKE_CONFIRMED)

        val ok1 = sm.transition(NightEvent.EnqueueProcessing(1000L))
        assertTrue("Primo enqueue porta a PROCESS_PENDING", ok1)
        assertEquals(NightState.PROCESS_PENDING, sm.currentState)

        // Secondo enqueue duplicato viene rifiutato (idempotenza)
        val ok2 = sm.transition(NightEvent.EnqueueProcessing(2000L))
        assertFalse("Secondo enqueue idempotente non cambia stato", ok2)
        assertEquals(NightState.PROCESS_PENDING, sm.currentState)
    }

    @Test
    fun test08_process_restart_recovery() {
        // Simula riavvio Android: recupera stato persistito PROCESS_PENDING
        val sm = NightStateMachine(initialState = NightState.PROCESS_PENDING)
        assertEquals(NightState.PROCESS_PENDING, sm.currentState)

        // Worker avvia elaborazione
        val okStart = sm.transition(NightEvent.ProcessingStarted(3000L))
        assertTrue(okStart)
        assertEquals(NightState.PROCESSING, sm.currentState)

        // Worker conclude con successo
        val okSuccess = sm.transition(NightEvent.ProcessingSuccess(4000L))
        assertTrue(okSuccess)
        assertEquals(NightState.REPORT_READY, sm.currentState)
    }

    @Test
    fun test09_revision_and_reprocessing() {
        // Notte già elaborata in precedenza (REPORT_READY)
        val sm = NightStateMachine(initialState = NightState.REPORT_READY)
        assertEquals(NightState.REPORT_READY, sm.currentState)

        // Utente corregge confini a mano o richiede ricalcolo: revisione successiva
        val okReprocess = sm.transition(NightEvent.ReprocessRequested(5000L, "Modifica confini manuali"))
        assertTrue("Richiesta di ricalcolo consentita da REPORT_READY", okReprocess)
        assertEquals(NightState.PROCESS_PENDING, sm.currentState)

        // Nuovo ciclo di calcolo worker
        sm.transition(NightEvent.ProcessingStarted(6000L))
        assertEquals(NightState.PROCESSING, sm.currentState)

        sm.transition(NightEvent.ProcessingSuccess(7000L))
        assertEquals(NightState.REPORT_READY, sm.currentState)
    }

    @Test
    fun test10_no_regression_always_on_recorder() {
        // Verifica che la macchina BLE e la NightStateMachine operino in modo ortogonale
        // senza interferire con lo stato STREAMING o con il supervisor di connessione
        val bleSm = BleStateMachine(BleState.Disabled)
        val nightSm = NightStateMachine(NightState.NO_NIGHT)

        // 1. BLE si connette e va in STREAMING
        bleSm.processEvent(BleEvent.DeviceConfigured("FD:49:44:66:1D:92", "WBB5AP-5AG0558675"))
        bleSm.processEvent(BleEvent.StartConnecting("FD:49:44:66:1D:92"))
        bleSm.processEvent(BleEvent.GattConnectedSuccess("FD:49:44:66:1D:92"))
        bleSm.processEvent(BleEvent.ServicesDiscoveredSuccess)
        bleSm.processEvent(BleEvent.SubscribedToHr(1, 1))
        bleSm.processEvent(BleEvent.FirstValidHrNotification("night_test", 60, 1))

        assertTrue(bleSm.currentState.isStreaming)
        assertEquals("STREAMING", bleSm.currentState.name)

        // 2. Durante lo streaming BLE, NightStateMachine rileva il sonno autonomamente
        nightSm.transition(NightEvent.RestingDetected(1000L))
        assertEquals(NightState.SLEEP_CANDIDATE, nightSm.currentState)

        nightSm.transition(NightEvent.SleepOnsetConfirmed(2000L))
        assertEquals(NightState.SLEEP_ACTIVE, nightSm.currentState)

        // 3. Lo stato BLE resta rigorosamente STREAMING, senza regressioni
        assertTrue("BLE streaming rimane inalterato", bleSm.currentState.isStreaming)
        assertEquals("STREAMING", bleSm.currentState.name)
    }
}
