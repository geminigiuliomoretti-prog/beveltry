package com.beveltry.ble

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicInteger

data class SyncProgressUpdate(
    val recordsSaved: Int,
    val lastTimestampSeconds: Long?,
    val isCompleted: Boolean,
    val isAborted: Boolean,
    val error: String? = null,
)

/**
 * Coordinatore della sincronizzazione storica WHOOP 5.0.
 * Gestisce l'avvio (0x16), la ricezione dei pacchetti 0x2F (v18/v26), la transazionalità SQLite
 * e la conferma tramite ACK (0x17) solo dopo avvenuto commit su disco.
 */
class HistoricalSyncCoordinator(
    private val strapSerial: String,
    private val gattQueue: SerializedGattQueue,
    private val storageEngine: WhoopStorageEngine,
    private val writeCharacteristicProvider: () -> android.bluetooth.BluetoothGattCharacteristic?,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    private val seqCounter = AtomicInteger(1)
    private val progressFlow = MutableSharedFlow<SyncProgressUpdate>(extraBufferCapacity = 64)

    @Volatile
    private var isSyncActive = false

    @Volatile
    private var lastAckedCursor: ByteArray? = null

    private var syncJob: Job? = null
    private val incomingPacketChannel = Channel<ByteArray>(Channel.UNLIMITED)

    private val currentRawBlock = mutableListOf<ByteArray>()
    private val currentV18Block = mutableListOf<HistoricalV18Measurement>()
    private var totalRecordsSaved = 0

    fun progress(): Flow<SyncProgressUpdate> = progressFlow.asSharedFlow()

    private fun nextSeq(): Int {
        val s = seqCounter.getAndIncrement()
        if (seqCounter.get() > 255) seqCounter.set(1)
        return s and 0xFF
    }

    /**
     * Inoltra un payload inner ricevuto da DATA_FROM_STRAP al coordinatore.
     */
    fun onDataReceived(innerPayload: ByteArray) {
        if (!isSyncActive) return
        incomingPacketChannel.trySend(innerPayload)
    }

    /**
     * Avvia una sessione di offload storico continuo.
     */
    fun startSync(timeoutMs: Long = 60_000L): Boolean {
        if (isSyncActive) {
            Log.w(TAG, "Sincronizzazione già attiva")
            return false
        }

        isSyncActive = true
        currentRawBlock.clear()
        currentV18Block.clear()
        totalRecordsSaved = 0
        lastAckedCursor = null

        syncJob = scope.launch {
            try {
                // 1. Invia il comando 0x16 (SEND_HISTORICAL_DATA)
                val seq = nextSeq()
                val cmdPayload = byteArrayOf(0x23, seq.toByte(), 0x16, 0x00)
                val frame = PuffinFrameCodec.encode(field = 0x0000, cmdPayload)

                val targetChar = writeCharacteristicProvider()
                if (targetChar == null) {
                    emitError("Caratteristica CMD_TO_STRAP non trovata")
                    return@launch
                }

                val result = gattQueue.writeCharacteristic(targetChar, frame)
                if (result !is GattOpResult.Success) {
                    emitError("Invio comando 0x16 fallito: $result")
                    return@launch
                }

                Log.i(TAG, "Comando 0x16 inviato con successo, in ascolto burst dati...")

                var idleCounter = 0
                while (isSyncActive) {
                    val inner = withTimeoutOrNull(2000L) {
                        incomingPacketChannel.receive()
                    }

                    if (inner == null) {
                        idleCounter++
                        if (idleCounter >= 10) { // 20 secondi di inattività
                            Log.i(TAG, "Nessun pacchetto dati per 20s, completamento naturale offload")
                            finishSync(isCompleted = true)
                            break
                        }
                        continue
                    }
                    idleCounter = 0

                    processInnerPacket(inner)
                }
            } catch (e: CancellationException) {
                Log.i(TAG, "Sincronizzazione annullata")
                finishSync(isCompleted = false, isAborted = true)
            } catch (e: Exception) {
                Log.e(TAG, "Errore durante sincronizzazione", e)
                emitError(e.message ?: "Errore sconosciuto durante il sync")
            } finally {
                isSyncActive = false
            }
        }

        return true
    }

    private suspend fun processInnerPacket(inner: ByteArray) {
        if (inner.isEmpty()) return
        val opcode = inner[0].toInt() and 0xFF

        when (opcode) {
            0x2F -> {
                currentRawBlock.add(inner.copyOf())
                if (inner.size >= 2 && (inner[1].toInt() and 0xFF) == 0x12) {
                    try {
                        val record = PuffinProtocolDecoder.decodeV18(inner)
                        currentV18Block.add(record)
                    } catch (e: Exception) {
                        Log.w(TAG, "Scartato record v18 malformato: ${e.message}")
                    }
                }
            }

            0x31 -> {
                val cursorResult = PuffinProtocolDecoder.decodeCursor0x31(inner)
                Log.d(TAG, "Ricevuto metadata 0x31: variant=${cursorResult.layoutVariant}, reqAck=${cursorResult.requiresAck}, dumpComplete=${cursorResult.isDumpComplete}")

                if (cursorResult.isDumpComplete) {
                    // Commit finale dei dati rimanenti
                    commitCurrentBlock(cursorToken = null, timestampSeconds = cursorResult.timestampSeconds)
                    finishSync(isCompleted = true)
                    return
                }

                if (cursorResult.isBlocked) {
                    Log.w(TAG, "Layout 0x31 non riconosciuto o non sicuro: ACK bloccato per salvaguardia memoria flash!")
                    // Preserva comunque i record decodificati su SQLite
                    commitCurrentBlock(cursorToken = null, timestampSeconds = cursorResult.timestampSeconds)
                    return
                }

                if (cursorResult.requiresAck && cursorResult.cursorToken != null) {
                    val token = cursorResult.cursorToken
                    // PIPELINE OBBLIGATORIA:
                    // Commit transazione SQLite PRIMA di inviare l'ACK 0x17!
                    val committed = commitCurrentBlock(cursorToken = token, timestampSeconds = cursorResult.timestampSeconds)

                    if (committed) {
                        // Verifica deduplicazione ACK
                        val isDuplicateCursor = lastAckedCursor != null && lastAckedCursor.contentEquals(token)
                        if (!isDuplicateCursor) {
                            sendAck17(token)
                            lastAckedCursor = token
                        } else {
                            Log.d(TAG, "ACK 0x17 duplicato saltato per token identico consecutivo")
                        }
                    } else {
                        Log.e(TAG, "Salvataggio SQLite fallito: ACK 0x17 NON inviato per evitare perdita dati!")
                    }
                }
            }
        }
    }

    private fun commitCurrentBlock(cursorToken: ByteArray?, timestampSeconds: Long?): Boolean {
        if (currentRawBlock.isEmpty() && currentV18Block.isEmpty() && cursorToken == null) {
            return true
        }

        val success = storageEngine.saveHistoricalBlockTransactional(
            strapSerial = strapSerial,
            rawPackets = currentRawBlock,
            decodedV18 = currentV18Block,
            cursorToken = cursorToken,
            timestampSeconds = timestampSeconds,
        )

        if (success) {
            totalRecordsSaved += currentV18Block.size
            val lastTs = currentV18Block.lastOrNull()?.timestampSeconds ?: timestampSeconds
            progressFlow.tryEmit(
                SyncProgressUpdate(
                    recordsSaved = totalRecordsSaved,
                    lastTimestampSeconds = lastTs,
                    isCompleted = false,
                    isAborted = false,
                ),
            )
            currentRawBlock.clear()
            currentV18Block.clear()
        }

        return success
    }

    private suspend fun sendAck17(cursorToken: ByteArray) {
        val ackSeq = nextSeq()
        val ackPayload = byteArrayOf(0x23, ackSeq.toByte(), 0x17, 0x01) + cursorToken
        val frame = PuffinFrameCodec.encode(field = 0x0000, ackPayload)

        val targetChar = writeCharacteristicProvider() ?: return
        val result = gattQueue.writeCharacteristic(targetChar, frame, timeoutMs = 2000L)
        if (result is GattOpResult.Success) {
            Log.d(TAG, "ACK 0x17 inviato con successo per cursor: ${cursorToken.joinToString("") { "%02X".format(it) }}")
        } else {
            Log.w(TAG, "Invio ACK 0x17 fallito: $result")
        }
    }

    /**
     * Interrompe la sincronizzazione attiva inviando l'opcode di abort 0x14.
     */
    fun stopSync() {
        if (!isSyncActive) return
        isSyncActive = false
        syncJob?.cancel()

        scope.launch {
            try {
                val seq = nextSeq()
                val abortPayload = byteArrayOf(0x23, seq.toByte(), 0x14, 0x00)
                val frame = PuffinFrameCodec.encode(field = 0x0000, abortPayload)
                val targetChar = writeCharacteristicProvider()
                if (targetChar != null) {
                    gattQueue.writeCharacteristic(targetChar, frame, timeoutMs = 1500L)
                    Log.i(TAG, "Comando ABORT 0x14 inviato al WHOOP")
                }
            } catch (e: Exception) {
                Log.w(TAG, "Errore durante invio abort 0x14: ${e.message}")
            } finally {
                finishSync(isCompleted = false, isAborted = true)
            }
        }
    }

    private fun finishSync(isCompleted: Boolean, isAborted: Boolean = false) {
        isSyncActive = false
        progressFlow.tryEmit(
            SyncProgressUpdate(
                recordsSaved = totalRecordsSaved,
                lastTimestampSeconds = null,
                isCompleted = isCompleted,
                isAborted = isAborted,
            ),
        )
    }

    private fun emitError(message: String) {
        isSyncActive = false
        progressFlow.tryEmit(
            SyncProgressUpdate(
                recordsSaved = totalRecordsSaved,
                lastTimestampSeconds = null,
                isCompleted = false,
                isAborted = false,
                error = message,
            ),
        )
    }

    companion object {
        private const val TAG = "HistoricalSyncCoord"
    }
}
