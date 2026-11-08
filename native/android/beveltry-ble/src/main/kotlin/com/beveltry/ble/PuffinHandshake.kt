package com.beveltry.ble

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import java.time.Instant
import java.security.SecureRandom

sealed interface HandshakeState {
    data object Idle : HandshakeState
    data object Connecting : HandshakeState
    data object Bonding : HandshakeState
    data object Subscribing : HandshakeState
    data object SendingHello : HandshakeState
    data object ReadingClock : HandshakeState
    data object SettingClock : HandshakeState
    data object VerifyingClock : HandshakeState
    data object KeyExchange : HandshakeState
    data class SettingFlags(val current: Int, val total: Int) : HandshakeState
    data object QueryingRange : HandshakeState
    data object StartingHistorical : HandshakeState
    data object Ready : HandshakeState
    data object OffloadStarted : HandshakeState
    data class Failed(val error: PuffinHandshakeError) : HandshakeState
}

sealed class PuffinHandshakeError(message: String) : Exception(message) {
    data class AckTimeout(val opcode: Int) : PuffinHandshakeError("Timeout ACK opcode 0x${opcode.toString(16)}")
    data class AckStatusFailure(val opcode: Int, val status: Int) :
        PuffinHandshakeError("ACK opcode 0x${opcode.toString(16)} con status 0x${status.toString(16)}")
    data object ClockNotLatched : PuffinHandshakeError("Il clock del cinturino non è stato aggiornato")
    data class UnexpectedResponse(val opcode: Int) :
        PuffinHandshakeError("Risposta inattesa opcode 0x${opcode.toString(16)}")
    data object Cancelled : PuffinHandshakeError("Handshake annullato")
    data class TransportFailure(val reason: String) : PuffinHandshakeError(reason)
}

data class OffloadProgress(
    val recordsReceived: Int,
    val cursorsAcknowledged: Int,
    val lastSeenTimestamp: Instant?,
    val completed: Boolean,
    val timedOut: Boolean,
)

interface PuffinHandshakeDelegate {
    fun didChangeState(handshake: PuffinHandshake, state: HandshakeState)
    fun didReceiveRawFrame(handshake: PuffinHandshake, frame: PuffinFrame)
    fun didFail(handshake: PuffinHandshake, error: PuffinHandshakeError)
}

class PuffinHandshake(
    private val transport: PuffinTransport,
    private val delegate: PuffinHandshakeDelegate? = null,
    private val timeoutMillis: Long = 30_000,
) {
    @Volatile var state: HandshakeState = HandshakeState.Idle
        private set

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val random = SecureRandom()
    private var sequence = 1
    private var operation: Deferred<Unit>? = null
    @Volatile private var offloadStop: Channel<Unit>? = null
    private var didReportFailure = false

    private val flags = listOf(
        "enable_r22_packets" to 2,
        "enable_r22_v2_packets" to 2,
        "enable_r22_v3_packets" to 2,
        "enable_r22_v4_packets" to 1,
        "enable_r22_v5_packets" to 2,
        "enable_r22_v6_packets" to 2,
        "enable_r22_v8_packets" to 2,
        "make_hrfm_visible" to 2,
        "disable_pip_r26_packets" to 2,
        "wear_detect_bias" to 2,
        "hr_ch_switching" to 2,
        "ir_hw_switching" to 2,
        "enable_passive_strap_fit_gen5" to 1,
        "enable_sig11_during_sleep" to 2,
        "dorset_inhibit_wpt" to 2,
        "enable_sig12" to 2,
    )

    /** Il trasporto deve essere già connesso e bonded prima di chiamare start(). */
    suspend fun start() {
        check(state == HandshakeState.Idle) { "Handshake già avviato" }
        val task = scope.async { run() }
        operation = task
        try {
            task.await()
        } catch (error: PuffinHandshakeError) {
            fail(error)
            throw error
        } catch (_: CancellationException) {
            fail(PuffinHandshakeError.Cancelled)
            throw PuffinHandshakeError.Cancelled
        } catch (error: Throwable) {
            val failure = PuffinHandshakeError.TransportFailure(error.message ?: error.toString())
            fail(failure)
            throw failure
        } finally {
            operation = null
            scope.cancel()
        }
    }

    fun cancel() {
        operation?.cancel(CancellationException("Richiesta di annullamento"))
    }

    fun stop() {
        offloadStop?.trySend(Unit)
    }

    private suspend fun run() {
        val inbox = Channel<Pair<PuffinFrame, PuffinCharacteristic>>(Channel.UNLIMITED)
        val collector = scope.launch {
            transport.incomingFrames().collect { inbox.send(it) }
        }
        try {
            transition(HandshakeState.Subscribing)
            transport.subscribe(PuffinCharacteristic.CMD_FROM_STRAP)
            transport.subscribe(PuffinCharacteristic.EVENTS_FROM_STRAP)
            transport.subscribe(PuffinCharacteristic.DATA_FROM_STRAP)

            transition(HandshakeState.SendingHello)
            val helloSequence = nextSequence()
            sendAndAcknowledge(
                byteArrayOf(0x23, helloSequence.toByte(), 0x91.toByte(), 0x01),
                0x91, helloSequence, inbox, field = 1, retryOnce = true,
                allowedStatuses = setOf(0x00, 0x01, 0x02),
            )

            transition(HandshakeState.ReadingClock)
            val initialClock = try {
                readClock(inbox)
            } catch (e: Exception) {
                android.util.Log.w("BeveltryBLE", "Warning lettura Clock cinturino (0x0B): $e")
                0u
            }

            transition(HandshakeState.SettingClock)
            val setTimestamp = Instant.now().epochSecond.toUInt()
            try {
                val clockSequence = nextSequence()
                val clockPayload = byteArrayOf(0x23, clockSequence.toByte(), 0x0A, 0x01) + setTimestamp.toLittleEndian()
                sendAndAcknowledge(clockPayload, 0x0A, clockSequence, inbox, allowedStatuses = setOf(0x00, 0x01, 0x02))

                transition(HandshakeState.VerifyingClock)
                val verifiedClock = readClock(inbox)
                val delta = verifiedClock.toLong() - setTimestamp.toLong()
                android.util.Log.i("BeveltryBLE", "CLOCK check: set=$setTimestamp verified=$verifiedClock delta=${delta}s")
            } catch (e: Exception) {
                android.util.Log.w("BeveltryBLE", "Warning allineamento Clock (0x0A): $e (proseguo)")
            }

            transition(HandshakeState.KeyExchange)
            try {
                val keySequence = nextSequence()
                val keyPayload = byteArrayOf(0x23, keySequence.toByte(), 0x73, 0x01, 0x01) + ByteArray(32).also(random::nextBytes)
                sendAndAcknowledge(keyPayload, 0x73, keySequence, inbox, allowedStatuses = setOf(0x00, 0x01, 0x02))
            } catch (e: Exception) {
                android.util.Log.w("BeveltryBLE", "Warning Key Exchange (0x73): $e (proseguo)")
            }

            flags.forEachIndexed { index, (name, value) ->
                transition(HandshakeState.SettingFlags(index + 1, flags.size))
                repeat(2) {
                    try {
                        val flagSequence = nextSequence()
                        val nameBytes = name.encodeToByteArray().take(32).toByteArray()
                        val payload = byteArrayOf(0x23, flagSequence.toByte(), 0x78, 0x01) +
                            nameBytes + ByteArray(32 - nameBytes.size) + byteArrayOf(value.toByte())
                        sendAndAcknowledge(payload, 0x78, flagSequence, inbox, retryOnce = true, allowedStatuses = setOf(0x00, 0x01, 0x02))
                    } catch (e: Exception) {
                        android.util.Log.w("BeveltryBLE", "Warning flag $name (0x78): $e (proseguo)")
                    }
                }
            }

            transition(HandshakeState.QueryingRange)
            try {
                val rangeSequence = nextSequence()
                transport.write(encode(byteArrayOf(0x23, rangeSequence.toByte(), 0x22, 0x00)), PuffinCharacteristic.CMD_TO_STRAP)
                waitForResponse(0x22, rangeSequence, inbox, allowedStatuses = setOf(0x00, 0x01, 0x02))
            } catch (e: Exception) {
                android.util.Log.w("BeveltryBLE", "Warning query range (0x22): $e")
            }

            transition(HandshakeState.Ready)
        } catch (error: PuffinHandshakeError) {
            fail(error)
            throw error
        } catch (_: CancellationException) {
            fail(PuffinHandshakeError.Cancelled)
            throw PuffinHandshakeError.Cancelled
        } catch (error: Throwable) {
            val failure = PuffinHandshakeError.TransportFailure(error.message ?: error.toString())
            fail(failure)
            throw failure
        } finally {
            collector.cancel()
            inbox.close()
        }
    }

    /** Inoltra record storici e conferma un solo ACK per cursor consecutivo distinto. */
    fun offloadHistorical(
        endTimestamp: Instant? = null,
        timeoutMillis: Long = 60_000,
        onRecord: (PuffinFrame) -> Unit = {},
    ): Flow<OffloadProgress> = flow {
        require(timeoutMillis > 0) { "Il timeout offload deve essere positivo" }
        check(state == HandshakeState.Ready || state == HandshakeState.OffloadStarted) {
            "Eseguire start() prima dell'offload storico"
        }
        coroutineScope {
            val inbox = Channel<Pair<PuffinFrame, PuffinCharacteristic>>(Channel.UNLIMITED)
            val stop = Channel<Unit>(Channel.CONFLATED)
            offloadStop = stop
            val collector = launch { transport.incomingFrames().collect { inbox.send(it) } }
            var recordsReceived = 0
            var cursorsAcknowledged = 0
            var lastSeenTimestamp: Instant? = null
            var lastCursor: ByteArray? = null
            var completed = false
            var timedOut = false
            try {
                transition(HandshakeState.StartingHistorical)
                sendCommand(0x16, byteArrayOf(0x00))
                transition(HandshakeState.OffloadStarted)
                val endedByTimeout = withTimeoutOrNull(timeoutMillis) {
                    while (true) {
                        val incoming = select<Pair<PuffinFrame, PuffinCharacteristic>?> {
                            inbox.onReceiveCatching { it.getOrNull() }
                            stop.onReceive { null }
                        }
                        if (incoming == null) { completed = true; break }
                        val (frame, characteristic) = incoming
                        val bytes = frame.rawPayload
                        when (bytes.firstOrNull()?.toInt()?.and(0xFF)) {
                            0x2F -> {
                                onRecord(frame)
                                recordsReceived++
                                if (bytes.size >= 11) {
                                    lastSeenTimestamp = Instant.ofEpochSecond(readU32(bytes, 7))
                                }
                                emit(OffloadProgress(recordsReceived, cursorsAcknowledged, lastSeenTimestamp, false, false))
                                if (endTimestamp != null && lastSeenTimestamp != null && lastSeenTimestamp >= endTimestamp) {
                                    completed = true
                                    break
                                }
                            }
                            0x31 -> if (characteristic == PuffinCharacteristic.DATA_FROM_STRAP && bytes.size >= 21) {
                                val cursor = bytes.copyOfRange(13, 21)
                                if (lastCursor == null || !cursor.contentEquals(lastCursor)) {
                                    withTimeout(800) {
                                        sendCommand(0x17, byteArrayOf(0x01) + cursor)
                                    }
                                    lastCursor = cursor
                                    cursorsAcknowledged++
                                    emit(OffloadProgress(recordsReceived, cursorsAcknowledged, lastSeenTimestamp, false, false))
                                }
                            }
                            0x24 -> if (characteristic == PuffinCharacteristic.CMD_FROM_STRAP) {
                                delegate?.didReceiveRawFrame(this@PuffinHandshake, frame)
                            }
                        }
                    }
                    false
                }
                if (endedByTimeout == null) timedOut = true
            } finally {
                offloadStop = null
                collector.cancel()
                inbox.close()
                stop.close()
            }
            transition(HandshakeState.Ready)
            emit(OffloadProgress(recordsReceived, cursorsAcknowledged, lastSeenTimestamp, completed, timedOut))
        }
    }

    private suspend fun sendCommand(opcode: Int, suffix: ByteArray) {
        val payload = byteArrayOf(0x23, nextSequence().toByte(), opcode.toByte()) + suffix
        transport.write(encode(payload), PuffinCharacteristic.CMD_TO_STRAP)
    }

    private fun readU32(bytes: ByteArray, offset: Int): Long =
        (bytes[offset].toLong() and 0xFF) or
            ((bytes[offset + 1].toLong() and 0xFF) shl 8) or
            ((bytes[offset + 2].toLong() and 0xFF) shl 16) or
            ((bytes[offset + 3].toLong() and 0xFF) shl 24)

    private suspend fun readClock(inbox: Channel<Pair<PuffinFrame, PuffinCharacteristic>>): UInt {
        val seq = nextSequence()
        val response = sendAndAcknowledge(
            byteArrayOf(0x23, seq.toByte(), 0x0B, 0x00), 0x0B, seq, inbox, returnFrame = true,
            allowedStatuses = setOf(0x00, 0x01, 0x02),
        ) ?: throw PuffinHandshakeError.UnexpectedResponse(0x0B)
        val bytes = response.rawPayload
        val offset = when {
            bytes.size >= 9 -> 5
            bytes.size >= 8 -> 4
            else -> throw PuffinHandshakeError.UnexpectedResponse(0x0B)
        }
        val timestamp = readU32(bytes, offset)
        android.util.Log.i("BeveltryBLE", "GET_CLOCK raw=${bytes.joinToString("") { "%02x".format(it) }} timestamp=$timestamp")
        return timestamp.toUInt()
    }

    private suspend fun sendAndAcknowledge(
        payload: ByteArray,
        opcode: Int,
        seq: Int,
        inbox: Channel<Pair<PuffinFrame, PuffinCharacteristic>>,
        field: Int = 1,
        retryOnce: Boolean = false,
        returnFrame: Boolean = false,
        allowedStatuses: Set<Int> = setOf(0x00, 0x01),
    ): PuffinFrame? {
        val frame = PuffinFrameCodec.encode(field, payload)
        var lastError: PuffinHandshakeError = PuffinHandshakeError.AckTimeout(opcode)
        repeat(if (retryOnce) 2 else 1) { attempt ->
            if (attempt > 0) kotlinx.coroutines.currentCoroutineContext().ensureActive()
            transport.write(frame, PuffinCharacteristic.CMD_TO_STRAP)
            try {
                val response = waitForResponse(opcode, seq, inbox, allowedStatuses)
                return if (returnFrame) response else null
            } catch (error: PuffinHandshakeError) {
                lastError = error
                if (!retryOnce || attempt > 0) throw error
            }
        }
        throw lastError
    }

    private suspend fun waitForResponse(
        opcode: Int,
        seq: Int,
        inbox: Channel<Pair<PuffinFrame, PuffinCharacteristic>>,
        allowedStatuses: Set<Int> = setOf(0x00, 0x01),
    ): PuffinFrame {
        while (true) {
            val (frame, characteristic) = nextIncoming(opcode, inbox)
            delegate?.didReceiveRawFrame(this, frame)
            val bytes = frame.rawPayload
            if (characteristic != PuffinCharacteristic.CMD_FROM_STRAP || bytes.size < 4 ||
                (bytes[0].toInt() and 0xFF) != 0x24
            ) continue
            val echoSeq = bytes[1].toInt() and 0xFF
            val responseOpcode = bytes[2].toInt() and 0xFF
            if (responseOpcode != opcode || echoSeq != seq) continue
            val statusIndex = if (bytes.size >= 5) 4 else 3
            val status = bytes[statusIndex].toInt() and 0xFF
            if (status !in allowedStatuses) throw PuffinHandshakeError.AckStatusFailure(opcode, status)
            return frame
        }
    }

    private suspend fun nextIncoming(
        opcode: Int,
        inbox: Channel<Pair<PuffinFrame, PuffinCharacteristic>>,
    ): Pair<PuffinFrame, PuffinCharacteristic> = try {
        withTimeout(timeoutMillis.coerceAtLeast(1)) { inbox.receive() }
    } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
        throw PuffinHandshakeError.AckTimeout(opcode)
    }

    private fun encode(payload: ByteArray): ByteArray = PuffinFrameCodec.encode(1, payload)

    private fun nextSequence(): Int {
        val current = sequence
        sequence = if (sequence == 0xFF) 1 else sequence + 1
        return current
    }

    private fun transition(newState: HandshakeState) {
        state = newState
        delegate?.didChangeState(this, newState)
    }

    private fun fail(error: PuffinHandshakeError) {
        if (didReportFailure) return
        didReportFailure = true
        transition(HandshakeState.Failed(error))
        delegate?.didFail(this, error)
    }

    private fun UInt.toLittleEndian(): ByteArray = byteArrayOf(
        (this and 0xFFu).toByte(), (this shr 8 and 0xFFu).toByte(),
        (this shr 16 and 0xFFu).toByte(), (this shr 24 and 0xFFu).toByte(),
    )
}
