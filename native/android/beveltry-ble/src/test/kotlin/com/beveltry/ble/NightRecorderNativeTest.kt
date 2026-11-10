package com.beveltry.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NightRecorderNativeTest {

    @Test
    fun decodeStandardHr_extractsFlagsSensorContactAndRawRr() {
        // Flags: 0x16 -> bits:
        // bit 0: 0 (8-bit HR)
        // bit 1: 1 (Sensor contact detected)
        // bit 2: 1 (Sensor contact supported)
        // bit 4: 1 (RR present)
        // HR: 77 bpm (0x4D)
        // RR: 779 ms (0x030B -> 0x0B, 0x03)
        val payload = byteArrayOf(0x16, 0x4D, 0x0B, 0x03)
        val decoded = PuffinProtocolDecoder.decodeStandardHr(payload)

        assertEquals(77, decoded.hr)
        assertEquals(0x16, decoded.flags)
        assertEquals(true, decoded.sensorContactDetected)
        assertEquals(listOf(779), decoded.rawRrIntervals)
        assertEquals(listOf(779), decoded.rrIntervalsMs)
    }

    @Test
    fun decodeStandardHr_handlesMissingRrWithoutFailing() {
        // Flags: 0x06 (No RR flag, sensor contact supported & detected)
        // HR: 82 bpm
        val payload = byteArrayOf(0x06, 0x52)
        val decoded = PuffinProtocolDecoder.decodeStandardHr(payload)

        assertEquals(82, decoded.hr)
        assertEquals(0x06, decoded.flags)
        assertEquals(true, decoded.sensorContactDetected)
        assertTrue(decoded.rawRrIntervals.isEmpty())
        assertTrue(decoded.rrIntervalsMs.isEmpty())
    }

    @Test
    fun decodeStandardHr_preservesMultipleRrIntervalsInDirectMs() {
        // Flags: 0x10 (RR present, 8-bit HR)
        // HR: 60 bpm
        // RR1: 1000 ms (0x03E8 -> E8 03)
        // RR2: 950 ms (0x03B6 -> B6 03)
        val payload = byteArrayOf(
            0x10, 0x3C,
            0xE8.toByte(), 0x03,
            0xB6.toByte(), 0x03,
        )
        val decoded = PuffinProtocolDecoder.decodeStandardHr(payload)

        assertEquals(60, decoded.hr)
        assertEquals(0x10, decoded.flags)
        assertEquals(listOf(1000, 950), decoded.rawRrIntervals)
        assertEquals(listOf(1000, 950), decoded.rrIntervalsMs)
    }

    @Test
    fun connectionState_transitionsPermitDecoupledStandardHrReady() {
        val sm = ConnectionStateMachine()
        assertEquals(ConnectionState.Disconnected, sm.currentState)

        assertTrue(sm.transitionTo(ConnectionState.Connecting("FD:49:44:66:1D:92")))
        assertTrue(sm.transitionTo(ConnectionState.Discovering))
        assertTrue(sm.transitionTo(ConnectionState.NegotiatingMtu))
        assertTrue(sm.transitionTo(ConnectionState.Subscribing(5, 5)))
        assertTrue(sm.transitionTo(ConnectionState.Handshaking("CLIENT_HELLO (0x91)")))
        // FASE 3: Transizione autorizzata a Ready anche se l'handshake Puffin fallisce
        assertTrue(sm.transitionTo(ConnectionState.Ready))
        assertEquals(ConnectionState.Ready, sm.currentState)
    }
}
