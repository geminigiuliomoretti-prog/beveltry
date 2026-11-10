package com.beveltry.ble

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PuffinProtocolDecoderTest {

    @Test
    fun decodeStandardHr_correctlyExtractsBpmAndDirectMsRrIntervals() {
        // Flag 0x14: 8-bit HR, sensor contact detected (bit 2 + bit 1), RR present (bit 4)
        // HR: 68 BPM (0x44)
        // RR 1: 850 ms (0x0352 -> 52 03)
        // RR 2: 865 ms (0x0361 -> 61 03)
        val payload = byteArrayOf(
            0x16.toByte(), // flags: 8-bit HR, contact detected (0x06), RR present (0x10)
            0x44.toByte(), // HR = 68 BPM
            0x52.toByte(), 0x03.toByte(), // 850 ms
            0x61.toByte(), 0x03.toByte(), // 865 ms
        )

        val decoded = PuffinProtocolDecoder.decodeStandardHr(payload)
        assertEquals(68, decoded.hr)
        assertEquals(2, decoded.rrIntervalsMs.size)
        // REGOLA 2: Nessuna conversione con formula 1/1024s. Millisecondi diretti!
        assertEquals(850, decoded.rrIntervalsMs[0])
        assertEquals(865, decoded.rrIntervalsMs[1])
        assertEquals(true, decoded.sensorContactDetected)
    }

    @Test
    fun decodeStandardHr_16BitHrAndEnergyExpended() {
        // Flag 0x19: 16-bit HR (bit 0), Energy Expended present (bit 3), RR present (bit 4)
        val payload = byteArrayOf(
            0x19.toByte(),
            0x90.toByte(), 0x00.toByte(), // HR = 144 BPM
            0x20.toByte(), 0x01.toByte(), // Energy = 288 kJ
            0xDC.toByte(), 0x01.toByte(), // RR = 476 ms
        )

        val decoded = PuffinProtocolDecoder.decodeStandardHr(payload)
        assertEquals(144, decoded.hr)
        assertEquals(288, decoded.energyExpended)
        assertEquals(listOf(476), decoded.rrIntervalsMs)
    }

    @Test
    fun decodeLive28_extractsBpmValidityAndRr() {
        // Cattura reale dal log: 28 03 63 96 F1 6A 14 22 40 00 00 00 00 00 00 00
        val payload = byteArrayOf(
            0x28.toByte(),
            0x03.toByte(),
            0x63.toByte(), 0x96.toByte(), 0xF1.toByte(), 0x6A.toByte(), // timestamp
            0x14.toByte(), 0x22.toByte(),
            0x40.toByte(), // HR = 64 BPM
            0x01.toByte(), // validity = 1
            0x50.toByte(), 0x03.toByte(), // RR = 848 ms
            0x00.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte(),
        )

        val decoded = PuffinProtocolDecoder.decodeLive28(payload)
        assertEquals(64, decoded.hr)
        assertEquals(1, decoded.validity)
        assertEquals(848, decoded.rrIntervalMs)
        assertEquals(1794217571L, decoded.timestampSeconds)
    }

    @Test
    fun decodeCursor0x31_matchesHciLogExactToken() {
        // Dalla cattura HCI ufficiale:
        // Inner (20B): 31 B7 01 31 96 F1 6A 33 33 31 00 00 0F 00 00 00 83 88 00 00
        val inner = byteArrayOf(
            0x31.toByte(), 0xB7.toByte(), 0x01.toByte(),
            0x31.toByte(), 0x96.toByte(), 0xF1.toByte(), 0x6A.toByte(),
            0x33.toByte(), 0x33.toByte(), 0x31.toByte(), 0x00.toByte(), 0x00.toByte(),
            0x0F.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte(),
            0x83.toByte(), 0x88.toByte(), 0x00.toByte(), 0x00.toByte(),
        )

        val capturedAckToken = byteArrayOf(
            0x0F.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte(),
            0x83.toByte(), 0x88.toByte(), 0x00.toByte(), 0x00.toByte(),
        )

        val result = PuffinProtocolDecoder.decodeCursor0x31(inner)
        assertTrue(result.requiresAck)
        assertFalse(result.isDumpComplete)
        assertFalse(result.isBlocked)
        assertEquals(CursorLayoutVariant.HCI_LOG_20B, result.layoutVariant)

        // Verifichiamo la condizione obbligatoria: extractedAckToken == capturedAckToken
        assertNotNull(result.cursorToken)
        assertArrayEquals(capturedAckToken, result.cursorToken)
    }

    @Test
    fun decodeCursor0x31_detectsDumpComplete() {
        // Dalla cattura HCI ufficiale:
        // Inner (8B): 31 DF 02 32 96 F1 6A 00
        val inner = byteArrayOf(
            0x31.toByte(), 0xDF.toByte(), 0x02.toByte(),
            0x32.toByte(), 0x96.toByte(), 0xF1.toByte(), 0x6A.toByte(),
            0x00.toByte(),
        )

        val result = PuffinProtocolDecoder.decodeCursor0x31(inner)
        assertFalse(result.requiresAck)
        assertTrue(result.isDumpComplete)
        assertFalse(result.isBlocked)
        assertNull(result.cursorToken)
        assertEquals(CursorLayoutVariant.HCI_LOG_8B_DUMP_COMPLETE, result.layoutVariant)
    }

    @Test
    fun decodeCursor0x31_matchesTask04Variant() {
        // Dalla cattura Task 04 (24B inner):
        // 31 64 02 C5 C9 EC 6A 28 5C 52 00 00 00 56 00 00 00 14 00 00 00 00 00 00
        val inner = byteArrayOf(
            0x31.toByte(), 0x64.toByte(), 0x02.toByte(),
            0xC5.toByte(), 0xC9.toByte(),
            0xEC.toByte(), 0x6A.toByte(), 0x28.toByte(), 0x5C.toByte(),
            0x52.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte(),
            0x56.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte(),
            0x14.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte(),
            0x00.toByte(), 0x00.toByte(), 0x00.toByte(),
        )

        val expectedToken = byteArrayOf(
            0xEC.toByte(), 0x6A.toByte(), 0x28.toByte(), 0x5C.toByte(),
            0x52.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte(),
        )

        val result = PuffinProtocolDecoder.decodeCursor0x31(inner)
        assertTrue(result.requiresAck)
        assertFalse(result.isDumpComplete)
        assertFalse(result.isBlocked)
        assertEquals(CursorLayoutVariant.TASK04_24B, result.layoutVariant)
        assertArrayEquals(expectedToken, result.cursorToken)
    }

    @Test
    fun decodeCursor0x31_blocksUnknownVariantForSafety() {
        // Variant con lunghezza non supportata (es. 15 byte non standard)
        val inner = ByteArray(15) { 0x31.toByte() }
        val result = PuffinProtocolDecoder.decodeCursor0x31(inner)
        assertTrue(result.isBlocked)
        assertFalse(result.requiresAck)
        assertNull(result.cursorToken)
        assertEquals(CursorLayoutVariant.UNKNOWN_BLOCKED, result.layoutVariant)
    }

    @Test
    fun decodeCommandResponse0x24_parsesStandardAndShort() {
        // [0x24, strap_seq=0x69, cmd=0x91, echo_seq=0x98, status=0x01]
        val payload = byteArrayOf(0x24, 0x69.toByte(), 0x91.toByte(), 0x98.toByte(), 0x01)
        val decoded = PuffinProtocolDecoder.decodeCommandResponse0x24(payload)
        assertNotNull(decoded)
        assertEquals(0x91, decoded!!.cmd)
        assertEquals(0x98, decoded.echoSeq)
        assertEquals(0x69, decoded.strapSeq)
        assertEquals(0x01, decoded.status)
        assertTrue(decoded.isSuccess)
    }

    @Test
    fun decodeCommandResponse0x24_acceptsStatus0x02SessionAlreadyActive() {
        val payload = byteArrayOf(0x24, 0x70.toByte(), 0x91.toByte(), 0x99.toByte(), 0x02)
        val decoded = PuffinProtocolDecoder.decodeCommandResponse0x24(payload)
        assertNotNull(decoded)
        assertEquals(0x91, decoded!!.cmd)
        assertEquals(0x99, decoded.echoSeq)
        assertEquals(0x02, decoded.status)
        assertTrue(decoded.isSuccess)
    }
}
