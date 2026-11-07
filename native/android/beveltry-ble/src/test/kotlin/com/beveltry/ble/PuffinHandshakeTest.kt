package com.beveltry.ble

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

private class MockPuffinTransport : PuffinTransport {
    private val incoming = Channel<Pair<PuffinFrame, PuffinCharacteristic>>(Channel.UNLIMITED)
    val writes = mutableListOf<Pair<ByteArray, PuffinCharacteristic>>()
    val subscriptions = mutableListOf<PuffinCharacteristic>()
    val flagFrames = mutableListOf<PuffinFrame>()
    val clockSetFrames = mutableListOf<PuffinFrame>()
    val ackFrames = mutableListOf<PuffinFrame>()
    var initialClock = Instant.now().epochSecond.toUInt()
    var clockWillLatch = true
    var failClockSet = false
    var failFlagName: String? = null
    var withholdHelloAck = false
    var commandStatus = 1
    var clockStatus = 1
    var legacyAckLayout = false
    var historicalFrames: List<Pair<ByteArray, PuffinCharacteristic>> = listOf(
        historicalFrame(byteArrayOf(0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87.toByte())) to PuffinCharacteristic.DATA_FROM_STRAP,
    )
    private var clockReads = 0
    private var latchedClock: UInt? = null

    override fun incomingFrames() = incoming.receiveAsFlow()
    override suspend fun subscribe(characteristic: PuffinCharacteristic) { subscriptions += characteristic }

    override suspend fun write(frame: ByteArray, characteristic: PuffinCharacteristic) {
        writes += frame to characteristic
        val decoded = PuffinFrameCodec.decode(frame)
        val raw = decoded.rawPayload
        if (raw.size < 3) return
        val seq = raw[1].toInt() and 0xFF
        val opcode = raw[2].toInt() and 0xFF
        when (opcode) {
            0x91 -> if (!withholdHelloAck) emitAck(seq, opcode, commandStatus)
            0x0B -> {
                clockReads++
                val timestamp = when {
                    clockReads == 1 -> initialClock
                    clockWillLatch -> latchedClock ?: 0u
                    else -> 0u
                }
                val response = byteArrayOf(0x24, seq.toByte(), opcode.toByte(), 0x77, clockStatus.toByte()) + timestamp.toLittleEndian()
                emit(response, PuffinCharacteristic.CMD_FROM_STRAP)
            }
            0x0A -> {
                clockSetFrames += decoded
                latchedClock = readU32(raw, 4)
                emitAck(seq, opcode, if (failClockSet) 2 else commandStatus)
            }
            0x73 -> emitAck(seq, opcode, commandStatus)
            0x78 -> {
                flagFrames += decoded
                val name = raw.copyOfRange(4, 36).takeWhile { it != 0.toByte() }.toByteArray().toString(Charsets.US_ASCII)
                emitAck(seq, opcode, if (name == failFlagName) 2 else commandStatus)
            }
            0x22 -> emit(if (legacyAckLayout) byteArrayOf(0x24, seq.toByte(), opcode.toByte(), commandStatus.toByte())
                else byteArrayOf(0x24, seq.toByte(), opcode.toByte(), 0x77, commandStatus.toByte()), PuffinCharacteristic.CMD_FROM_STRAP)
            0x16 -> historicalFrames.forEach { (bytes, kind) -> emit(bytes, kind) }
            0x17 -> ackFrames += decoded
        }
    }

    private suspend fun emitAck(seq: Int, opcode: Int, status: Int) =
        emit(if (legacyAckLayout) byteArrayOf(0x24, seq.toByte(), opcode.toByte(), status.toByte())
            else byteArrayOf(0x24, seq.toByte(), opcode.toByte(), 0x77, status.toByte()), PuffinCharacteristic.CMD_FROM_STRAP)

    private suspend fun emit(payload: ByteArray, characteristic: PuffinCharacteristic) {
        incoming.send(PuffinFrameCodec.decode(PuffinFrameCodec.encode(1, payload)) to characteristic)
    }

    private fun readU32(bytes: ByteArray, offset: Int): UInt =
        (bytes[offset].toUInt() and 0xFFu) or ((bytes[offset + 1].toUInt() and 0xFFu) shl 8) or
            ((bytes[offset + 2].toUInt() and 0xFFu) shl 16) or ((bytes[offset + 3].toUInt() and 0xFFu) shl 24)

    private fun UInt.toLittleEndian() = byteArrayOf(
        (this and 0xFFu).toByte(), (this shr 8 and 0xFFu).toByte(),
        (this shr 16 and 0xFFu).toByte(), (this shr 24 and 0xFFu).toByte(),
    )
}

private fun historicalFrame(cursor: ByteArray): ByteArray {
    val payload = ByteArray(40)
    payload[0] = 0x31
    cursor.copyInto(payload, 13)
    return payload
}

private fun v18Frame(timestamp: UInt): ByteArray {
    val payload = ByteArray(112)
    payload[0] = 0x2F
    payload[1] = 0x12
    repeat(4) { payload[7 + it] = (timestamp shr (8 * it)).toByte() }
    return payload
}

private class MockHandshakeDelegate : PuffinHandshakeDelegate {
    val states = mutableListOf<HandshakeState>()
    val failures = mutableListOf<PuffinHandshakeError>()
    override fun didChangeState(handshake: PuffinHandshake, state: HandshakeState) { states += state }
    override fun didReceiveRawFrame(handshake: PuffinHandshake, frame: PuffinFrame) = Unit
    override fun didFail(handshake: PuffinHandshake, error: PuffinHandshakeError) { failures += error }
}

class PuffinHandshakeTest {
    @Test fun bootstrapAcceptsStatusOneAndLeavesReadyForStreaming() = runBlocking {
        val transport = MockPuffinTransport()
        val handshake = PuffinHandshake(transport, timeoutMillis = 500)
        handshake.start()
        assertEquals(HandshakeState.Ready, handshake.state)
        assertEquals(32, transport.flagFrames.size)
        assertTrue(transport.writes.none { PuffinFrameCodec.decode(it.first).rawPayload.getOrNull(2)?.toInt()?.and(0xFF) == 0x16 })
        assertEquals(listOf(0xAA, 1, 8, 0, 1, 0, 0x26, 0x21, 0x23, 1, 0x91, 1, 0x36, 0x3E, 0x5C, 0x8D),
            transport.writes.first().first.map { it.toInt() and 0xFF })
    }

    @Test fun statusZeroIsAcceptedAndClockUsesBytesFiveThroughEight() = runBlocking {
        val expected = 1_793_679_344u
        val transport = MockPuffinTransport().apply { initialClock = expected; commandStatus = 0; clockStatus = 0 }
        val handshake = PuffinHandshake(transport, timeoutMillis = 500)
        handshake.start()
        assertEquals(HandshakeState.Ready, handshake.state)
        assertEquals(1, transport.clockSetFrames.size)
    }

    @Test fun fourByteCommandResponseUsesByteThreeForStatus() = runBlocking {
        val transport = MockPuffinTransport().apply { commandStatus = 0; clockStatus = 0; legacyAckLayout = true }
        val handshake = PuffinHandshake(transport, timeoutMillis = 500)
        handshake.start()
        assertEquals(HandshakeState.Ready, handshake.state)
    }

    @Test fun zeroTimestampWarnsAndStillReachesReady() = runBlocking {
        val transport = MockPuffinTransport().apply { initialClock = 0u }
        val handshake = PuffinHandshake(transport, timeoutMillis = 500)
        handshake.start()
        assertEquals(HandshakeState.Ready, handshake.state)
    }

    @Test fun clockDifferenceWarnsAndStillReachesReady() = runBlocking {
        val transport = MockPuffinTransport().apply { clockWillLatch = false }
        val handshake = PuffinHandshake(transport, timeoutMillis = 500)
        handshake.start()
        assertEquals(HandshakeState.Ready, handshake.state)
    }

    @Test fun helloTimeoutFailsHandshake() = runBlocking {
        val transport = MockPuffinTransport().apply { withholdHelloAck = true }
        val delegate = MockHandshakeDelegate()
        val handshake = PuffinHandshake(transport, delegate, timeoutMillis = 20)
        val error = runCatching { handshake.start() }.exceptionOrNull()
        assertTrue(error is PuffinHandshakeError.AckTimeout && error.opcode == 0x91)
        assertEquals(HandshakeState.Failed(PuffinHandshakeError.AckTimeout(0x91)), handshake.state)
    }

    @Test fun optionalStepFailuresWarnAndContinueToReady() = runBlocking {
        val transport = MockPuffinTransport().apply { failClockSet = true }
        val handshake = PuffinHandshake(transport, timeoutMillis = 500)
        handshake.start()
        assertEquals(HandshakeState.Ready, handshake.state)

        val flagTransport = MockPuffinTransport().apply { failFlagName = "enable_r22_packets" }
        val flagHandshake = PuffinHandshake(flagTransport, timeoutMillis = 500)
        flagHandshake.start()
        assertEquals(HandshakeState.Ready, flagHandshake.state)
        assertEquals(32, flagTransport.flagFrames.size)
    }

    @Test fun helloStatusErrorFailsHandshake() = runBlocking {
        val transport = MockPuffinTransport().apply { commandStatus = 0xFF }
        val handshake = PuffinHandshake(transport, timeoutMillis = 500)
        val error = runCatching { handshake.start() }.exceptionOrNull()
        assertTrue(error is PuffinHandshakeError.AckStatusFailure && error.opcode == 0x91 && error.status == 0xFF)
    }

    @Test fun threeDistinctCursorsGetThreeAcknowledgements() = runBlocking {
        val cursors = (0..2).map { value -> ByteArray(8) { (value * 10 + it).toByte() } }
        val transport = MockPuffinTransport().apply {
            historicalFrames = cursors.map { historicalFrame(it) to PuffinCharacteristic.DATA_FROM_STRAP }
        }
        val handshake = PuffinHandshake(transport, timeoutMillis = 500)
        handshake.start()
        val progress = handshake.offloadHistorical(timeoutMillis = 250).toList()
        assertEquals(3, transport.ackFrames.size)
        assertEquals(cursors.map { it.toList() }, transport.ackFrames.map { it.rawPayload.copyOfRange(4, 12).toList() })
        assertEquals(3, progress.last().cursorsAcknowledged)
    }

    @Test fun duplicateCursorGetsOneAck() = runBlocking {
        val cursor = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8)
        val transport = MockPuffinTransport().apply {
            historicalFrames = listOf(
                historicalFrame(cursor) to PuffinCharacteristic.DATA_FROM_STRAP,
                historicalFrame(cursor) to PuffinCharacteristic.DATA_FROM_STRAP,
            )
        }
        val handshake = PuffinHandshake(transport, timeoutMillis = 500)
        handshake.start()
        handshake.offloadHistorical(timeoutMillis = 250).toList()
        assertEquals(1, transport.ackFrames.size)
    }

    @Test fun fiveV18RecordsAreDeliveredAndNeverAcknowledged() = runBlocking {
        val cursor = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8)
        val records = (1u..5u).map { v18Frame(it) to PuffinCharacteristic.DATA_FROM_STRAP }
        val transport = MockPuffinTransport().apply {
            historicalFrames = records + (historicalFrame(cursor) to PuffinCharacteristic.DATA_FROM_STRAP)
        }
        val delivered = mutableListOf<PuffinFrame>()
        val handshake = PuffinHandshake(transport, timeoutMillis = 500)
        handshake.start()
        val progress = handshake.offloadHistorical(timeoutMillis = 250, onRecord = delivered::add).toList()
        assertEquals(5, delivered.size)
        assertEquals(1, transport.ackFrames.size)
        assertEquals(5, progress.last().recordsReceived)
    }
}
