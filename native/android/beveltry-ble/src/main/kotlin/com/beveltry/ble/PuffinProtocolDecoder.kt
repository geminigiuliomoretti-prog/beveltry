package com.beveltry.ble

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.sqrt

// 1. Decodifica Standard HR (0x2A37)
data class StandardHrMeasurement(
    val hr: Int,
    val rrIntervalsMs: List<Int>,
    val energyExpended: Int? = null,
    val sensorContactDetected: Boolean? = null,
    val flags: Int = 0,
    val rawRrIntervals: List<Int> = emptyList(),
)

// 2. Decodifica Live HR (0x28)
data class Live28Measurement(
    val timestampSeconds: Long,
    val hr: Int,
    val validity: Int,
    val rrIntervalMs: Int,
)

// 3. Decodifica Record Storico v18 (0x2F / 0x12)
data class HistoricalV18Measurement(
    val seq: Int,
    val timestampSeconds: Long,
    val hrPrimary: Int,
    val hrSecondary: Int,
    val rrCount: Int,
    val rrIntervalsMs: List<Int>,
    val gravityX: Float,
    val gravityY: Float,
    val gravityZ: Float,
    val accelMagG: Float,
    val stepCounter: Int,
    val skinTempRaw: Short,
    val skinTempCelsius: Float,
    val activityFlag: Int,
    val spo2CandidateRaw: Int, // Non decodificare mai come SpO2! (Regola 3)
    val sleepState: Int,
    val opticalBaselineCh1: Int,
    val opticalBaselineCh2: Int,
    val opticalBaseline: Int,
    val isOnWrist: Boolean,
)

// 4. Decodifica Record Storico v26 (0x2F / 0x1A)
data class HistoricalV26Measurement(
    val seq: Int,
    val timestampSeconds: Long,
    val ppgSamples: ShortArray,
)

// 5. Decodifica Cursore / Metadata (0x31)
enum class CursorLayoutVariant {
    HCI_LOG_20B,
    HCI_LOG_8B_DUMP_COMPLETE,
    TASK04_24B,
    RULE6_21B,
    UNKNOWN_BLOCKED,
}

data class Cursor0x31Decoded(
    val requiresAck: Boolean,
    val isDumpComplete: Boolean,
    val cursorToken: ByteArray?,
    val timestampSeconds: Long?,
    val layoutVariant: CursorLayoutVariant,
    val isBlocked: Boolean = false,
)

// 6. Decodifica Risposta Comandi (0x24)
data class CommandResponse0x24(
    val cmd: Int,
    val echoSeq: Int,
    val strapSeq: Int?,
    val status: Int,
    val isSuccess: Boolean,
    val remainingBytes: ByteArray,
)

object PuffinProtocolDecoder {

    /**
     * Decodifica la caratteristica GATT standard Heart Rate Measurement (0x2A37).
     * REGOLA INVIOLABILE 2: Il WHOOP 5.0 invia gli intervalli R-R direttamente in millisecondi (ms).
     * MAI moltiplicare per 1000/1024 o convertire con unità 1/1024s.
     */
    fun decodeStandardHr(bytes: ByteArray): StandardHrMeasurement {
        require(bytes.isNotEmpty()) { "Payload 0x2A37 vuoto" }
        val flags = bytes[0].toInt() and 0xFF
        val is16Bit = (flags and 0x01) != 0
        val sensorContactSupported = (flags and 0x04) != 0
        val sensorContactDetected = if (sensorContactSupported) (flags and 0x02) != 0 else null
        val energyExpendedPresent = (flags and 0x08) != 0
        val rrPresent = (flags and 0x10) != 0

        var offset = 1
        val hr = if (is16Bit) {
            require(bytes.size >= offset + 2) { "Campo HR 16-bit troncato" }
            val v = (bytes[offset].toInt() and 0xFF) or ((bytes[offset + 1].toInt() and 0xFF) shl 8)
            offset += 2
            v
        } else {
            require(bytes.size >= offset + 1) { "Campo HR 8-bit troncato" }
            val v = bytes[offset].toInt() and 0xFF
            offset += 1
            v
        }

        var energy: Int? = null
        if (energyExpendedPresent) {
            require(bytes.size >= offset + 2) { "Campo Energy Expended troncato" }
            energy = (bytes[offset].toInt() and 0xFF) or ((bytes[offset + 1].toInt() and 0xFF) shl 8)
            offset += 2
        }

        val rawRrList = mutableListOf<Int>()
        val rrList = mutableListOf<Int>()
        if (rrPresent) {
            while (offset + 1 < bytes.size) {
                // Intervallo R-R u16 little-endian: valore grezzo u16
                val rawRr = (bytes[offset].toInt() and 0xFF) or ((bytes[offset + 1].toInt() and 0xFF) shl 8)
                rawRrList.add(rawRr)
                // REGOLA INVIOLABILE 2: Il WHOOP 5.0 invia gli intervalli R-R direttamente in millisecondi (ms)
                rrList.add(rawRr)
                offset += 2
            }
        }

        return StandardHrMeasurement(
            hr = hr,
            rrIntervalsMs = rrList,
            energyExpended = energy,
            sensorContactDetected = sensorContactDetected,
            flags = flags,
            rawRrIntervals = rawRrList,
        )
    }

    /**
     * Decodifica il pacchetto Realtime HR 0x28 (stream Puffin live compact).
     */
    fun decodeLive28(inner: ByteArray): Live28Measurement {
        require(inner.size >= 12) { "Payload 0x28 inferiore a 12 byte" }
        require((inner[0].toInt() and 0xFF) == 0x28) { "Opcode 0x28 atteso ma ricevuto 0x${inner[0].toString(16)}" }

        val ts = readU32LE(inner, 2)
        val hr = inner[8].toInt() and 0xFF
        val validity = inner[9].toInt() and 0xFF
        val rrMs = readU16LE(inner, 10)

        return Live28Measurement(
            timestampSeconds = ts,
            hr = hr,
            validity = validity,
            rrIntervalMs = rrMs,
        )
    }

    /**
     * Decodifica un record storico v18 (Opcode 0x2F, Versione 0x12).
     * Lunghezza inner payload: tra 108 e 112 byte.
     * Tutti gli intervalli RR sono in millisecondi diretti (Regola 2).
     * SpO2 @82 NON viene decodificata (Regola 3).
     */
    fun decodeV18(inner: ByteArray): HistoricalV18Measurement {
        require(inner.size >= 108) { "Payload v18 inferiore a 108 byte (len=${inner.size})" }
        require((inner[0].toInt() and 0xFF) == 0x2F) { "Opcode 0x2F atteso" }
        require((inner[1].toInt() and 0xFF) == 0x12) { "Versione 0x12 attesa per record v18" }

        val seq = readU16LE(inner, 2)
        val ts = readU32LE(inner, 7)
        val hrPrimary = inner[14].toInt() and 0xFF
        val rrCount = (inner[15].toInt() and 0xFF).coerceIn(0, 4)

        val rrList = mutableListOf<Int>()
        for (i in 0 until rrCount) {
            val offset = 16 + (i * 2)
            if (offset + 1 < inner.size) {
                val rrMs = readU16LE(inner, offset)
                rrList.add(rrMs)
            }
        }

        val hrSecondary = inner[29].toInt() and 0xFF
        val gx = readFloat32LE(inner, 37)
        val gy = readFloat32LE(inner, 41)
        val gz = readFloat32LE(inner, 45)
        val accelMag = sqrt((gx * gx) + (gy * gy) + (gz * gz))

        val stepCounter = readU16LE(inner, 57)

        var skinTempRaw = readI16LE(inner, 61)
        if (skinTempRaw < 150 || skinTempRaw > 450) {
            val fallback = readI16LE(inner, 63)
            if (fallback in 150..450) skinTempRaw = fallback
        }
        val skinTempCelsius = skinTempRaw / 10.0f

        val activityFlag = inner[64].toInt() and 0xFF
        val spo2Candidate = inner[82].toInt() and 0xFF // Candidato grezzo preservato, NON decodificato come SpO2

        val sleepState = inner[96].toInt() and 0xFF
        val baselineCh1 = readU16LE(inner, 98)
        val baselineCh2 = if (inner.size >= 108) readU16LE(inner, 106) else 0
        val opticalBaseline = maxOf(baselineCh1, baselineCh2)
        val isOnWrist = hrPrimary > 0 || opticalBaseline > 30000

        return HistoricalV18Measurement(
            seq = seq,
            timestampSeconds = ts,
            hrPrimary = hrPrimary,
            hrSecondary = hrSecondary,
            rrCount = rrCount,
            rrIntervalsMs = rrList,
            gravityX = gx,
            gravityY = gy,
            gravityZ = gz,
            accelMagG = accelMag,
            stepCounter = stepCounter,
            skinTempRaw = skinTempRaw,
            skinTempCelsius = skinTempCelsius,
            activityFlag = activityFlag,
            spo2CandidateRaw = spo2Candidate,
            sleepState = sleepState,
            opticalBaselineCh1 = baselineCh1,
            opticalBaselineCh2 = baselineCh2,
            opticalBaseline = opticalBaseline,
            isOnWrist = isOnWrist,
        )
    }

    /**
     * Decodifica forma d'onda PPG ad alta risoluzione v26 (Opcode 0x2F, Versione 0x1A).
     */
    fun decodeV26(inner: ByteArray): HistoricalV26Measurement {
        require(inner.size >= 76) { "Payload v26 inferiore a 76 byte" }
        require((inner[0].toInt() and 0xFF) == 0x2F) { "Opcode 0x2F atteso" }
        require((inner[1].toInt() and 0xFF) == 0x1A) { "Versione 0x1A attesa per record v26" }

        val seq = readU16LE(inner, 2)
        val ts = readU32LE(inner, 7)

        val samples = ShortArray(24)
        var offset = 27
        for (i in 0 until 24) {
            if (offset + 1 < inner.size) {
                samples[i] = readI16LE(inner, offset)
                offset += 2
            }
        }

        return HistoricalV26Measurement(
            seq = seq,
            timestampSeconds = ts,
            ppgSamples = samples,
        )
    }

    /**
     * Risolve in modo consapevole e sicuro il layout/versione del frame metadata 0x31.
     * Confronta rigorosamente le varianti documentate:
     * - Variante HCI capture: 20 byte totali, cursore a 8 byte a inner[12..20] (offset 12..19).
     * - Variante HCI Dump Complete: 8 byte totali, subtype 0x02, nessun ACK.
     * - Variante Task 04: 24 byte totali, cursore a 8 byte a inner[5..13].
     * - Regola 6 fallback: 21+ byte, cursore a 8 byte a inner[13..21] (1-based / inner[12..20] 0-based).
     * Se la variante non è identificabile con certezza, disabilita l'ACK e segnala il blocco.
     */
    fun decodeCursor0x31(inner: ByteArray): Cursor0x31Decoded {
        if (inner.isEmpty() || (inner[0].toInt() and 0xFF) != 0x31) {
            return Cursor0x31Decoded(
                requiresAck = false,
                isDumpComplete = false,
                cursorToken = null,
                timestampSeconds = null,
                layoutVariant = CursorLayoutVariant.UNKNOWN_BLOCKED,
                isBlocked = true,
            )
        }

        val subtype = if (inner.size >= 3) inner[2].toInt() and 0xFF else 0
        val ts = if (inner.size >= 7) readU32LE(inner, 3) else null

        // 1. Variante Dump Complete (HCI capture)
        if (inner.size in 8..12 && subtype == 0x02) {
            return Cursor0x31Decoded(
                requiresAck = false,
                isDumpComplete = true,
                cursorToken = null,
                timestampSeconds = ts,
                layoutVariant = CursorLayoutVariant.HCI_LOG_8B_DUMP_COMPLETE,
                isBlocked = false,
            )
        }

        // 2. Variante HCI capture (20 byte esatti):
        // [31, seq, 01, ts(4B), 33, 33, 31, 00, 00, token(8B)]
        // Token a inner[12..20] (ultimi 8 byte)
        if (inner.size == 20 && subtype == 0x01) {
            val token = inner.copyOfRange(12, 20)
            return Cursor0x31Decoded(
                requiresAck = true,
                isDumpComplete = false,
                cursorToken = token,
                timestampSeconds = ts,
                layoutVariant = CursorLayoutVariant.HCI_LOG_20B,
                isBlocked = false,
            )
        }

        // 3. Variante Task 04 (24 byte):
        // [31, seq, 02, C5, C9, token(8B), 56 00 00 00, 14 00 00 00, 00 00 00 00]
        if (inner.size == 24 && subtype == 0x02) {
            val token = inner.copyOfRange(5, 13)
            return Cursor0x31Decoded(
                requiresAck = true,
                isDumpComplete = false,
                cursorToken = token,
                timestampSeconds = ts,
                layoutVariant = CursorLayoutVariant.TASK04_24B,
                isBlocked = false,
            )
        }

        // 4. Regola 6 (frame inner >= 21 byte con cursore a 8 byte tra index 12 e 20)
        if (inner.size >= 21) {
            val token = inner.copyOfRange(12, 20)
            // Se token non è tutti zeri
            val hasNonZero = token.any { it != 0.toByte() }
            if (hasNonZero) {
                return Cursor0x31Decoded(
                    requiresAck = true,
                    isDumpComplete = false,
                    cursorToken = token,
                    timestampSeconds = ts,
                    layoutVariant = CursorLayoutVariant.RULE6_21B,
                    isBlocked = false,
                )
            }
        }

        // 5. Layout sconosciuto o ambiguo: blocca l'ACK per sicurezza flash (NAND safety gate)
        return Cursor0x31Decoded(
            requiresAck = false,
            isDumpComplete = false,
            cursorToken = null,
            timestampSeconds = ts,
            layoutVariant = CursorLayoutVariant.UNKNOWN_BLOCKED,
            isBlocked = true,
        )
    }

    /**
     * Decodifica il frame di risposta comando 0x24.
     * Supporta layout standard: [0x24, strap_seq, cmd, echo_seq, status, ...]
     * e layout breve: [0x24, echo_seq, cmd, status].
     */
    fun decodeCommandResponse0x24(inner: ByteArray): CommandResponse0x24? {
        if (inner.isEmpty() || (inner[0].toInt() and 0xFF) != 0x24) return null
        return if (inner.size >= 5) {
            val strapSeq = inner[1].toInt() and 0xFF
            val cmd = inner[2].toInt() and 0xFF
            val echoSeq = inner[3].toInt() and 0xFF
            val status = inner[4].toInt() and 0xFF
            val isSuccess = status == 0x00 || status == 0x01 || status == 0x02
            val remaining = if (inner.size > 5) inner.copyOfRange(5, inner.size) else ByteArray(0)
            CommandResponse0x24(cmd, echoSeq, strapSeq, status, isSuccess, remaining)
        } else if (inner.size >= 4) {
            val echoSeq = inner[1].toInt() and 0xFF
            val cmd = inner[2].toInt() and 0xFF
            val status = inner[3].toInt() and 0xFF
            val isSuccess = status == 0x00 || status == 0x01 || status == 0x02
            val remaining = if (inner.size > 4) inner.copyOfRange(4, inner.size) else ByteArray(0)
            CommandResponse0x24(cmd, echoSeq, null, status, isSuccess, remaining)
        } else {
            null
        }
    }

    internal fun readU16LE(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xFF) or ((bytes[offset + 1].toInt() and 0xFF) shl 8)

    internal fun readI16LE(bytes: ByteArray, offset: Int): Short =
        (((bytes[offset].toInt() and 0xFF) or ((bytes[offset + 1].toInt() and 0xFF) shl 8))).toShort()

    internal fun readU32LE(bytes: ByteArray, offset: Int): Long =
        (bytes[offset].toLong() and 0xFF) or
            ((bytes[offset + 1].toLong() and 0xFF) shl 8) or
            ((bytes[offset + 2].toLong() and 0xFF) shl 16) or
            ((bytes[offset + 3].toLong() and 0xFF) shl 24)

    internal fun readFloat32LE(bytes: ByteArray, offset: Int): Float {
        val intBits = (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 3].toInt() and 0xFF) shl 24)
        return Float.fromBits(intBits)
    }
}
