package com.beveltry.ble

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Log

/**
 * Gestore SQLite nativo Android per la persistenza sicura, transazionale e deduplicata
 * dei record storici WHOOP 5.0 in modalità WAL.
 *
 * Rispetta rigorosamente la pipeline transazionale:
 * Salva raw frame -> Salva record decodificati -> Salva checkpoint/pending ACK -> Commit transazione.
 * Solo dopo il commit avvenuto con successo viene autorizzato l'invio dell'ACK 0x17.
 */
class WhoopStorageEngine(
    context: Context?,
    databaseName: String = "whoop_local.db",
    private val inMemoryDb: SQLiteDatabase? = null,
) : SQLiteOpenHelper(context, databaseName, null, DATABASE_VERSION) {

    init {
        // Se non in-memory, abilita WAL mode
        if (inMemoryDb == null && context != null) {
            try {
                setWriteAheadLoggingEnabled(true)
            } catch (e: Exception) {
                Log.w(TAG, "Impossibile abilitare WAL mode tramite helper: ${e.message}")
            }
        }
    }

    override fun onConfigure(db: SQLiteDatabase) {
        super.onConfigure(db)
        db.setForeignKeyConstraintsEnabled(true)
        db.enableWriteAheadLogging()
    }

    override fun onCreate(db: SQLiteDatabase) {
        createTables(db)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // Schema incrementale
        createTables(db)
    }

    private fun createTables(db: SQLiteDatabase) {
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS v18_records (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                strap_serial TEXT NOT NULL,
                seq INTEGER NOT NULL,
                timestamp INTEGER NOT NULL,
                hr_primary INTEGER NOT NULL,
                hr_secondary INTEGER NOT NULL,
                rr_count INTEGER NOT NULL,
                gravity_x REAL NOT NULL,
                gravity_y REAL NOT NULL,
                gravity_z REAL NOT NULL,
                accel_mag REAL NOT NULL,
                step_counter INTEGER NOT NULL,
                skin_temp_raw INTEGER,
                skin_temp_celsius REAL,
                activity_flag INTEGER NOT NULL,
                spo2_candidate INTEGER NOT NULL,
                sleep_state INTEGER NOT NULL,
                optical_baseline INTEGER NOT NULL,
                optical_baseline_ch1 INTEGER,
                optical_baseline_ch2 INTEGER,
                is_on_wrist INTEGER NOT NULL DEFAULT 0
            );
        """.trimIndent())

        db.execSQL("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_v18_serial_seq 
            ON v18_records(strap_serial, seq);
        """.trimIndent())

        db.execSQL("""
            CREATE INDEX IF NOT EXISTS idx_v18_timestamp 
            ON v18_records(timestamp);
        """.trimIndent())

        db.execSQL("""
            CREATE TABLE IF NOT EXISTS rr_intervals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                v18_record_id INTEGER NOT NULL REFERENCES v18_records(id) ON DELETE CASCADE,
                timestamp INTEGER NOT NULL,
                rr_ms INTEGER NOT NULL,
                beat_ordinal INTEGER NOT NULL DEFAULT 0,
                UNIQUE(v18_record_id, beat_ordinal)
            );
        """.trimIndent())

        db.execSQL("""
            CREATE INDEX IF NOT EXISTS idx_rr_record_id 
            ON rr_intervals(v18_record_id);
        """.trimIndent())

        db.execSQL("""
            CREATE TABLE IF NOT EXISTS v26_records (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                strap_serial TEXT NOT NULL,
                seq INTEGER NOT NULL,
                timestamp INTEGER NOT NULL,
                ppg_samples BLOB NOT NULL
            );
        """.trimIndent())

        db.execSQL("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_v26_serial_seq 
            ON v26_records(strap_serial, seq);
        """.trimIndent())

        db.execSQL("""
            CREATE TABLE IF NOT EXISTS sync_state (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                strap_serial TEXT NOT NULL UNIQUE,
                last_cursor BLOB NOT NULL,
                last_sync_time INTEGER NOT NULL
            );
        """.trimIndent())

        db.execSQL("""
            CREATE TABLE IF NOT EXISTS raw_frames (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                strap_serial TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                opcode INTEGER NOT NULL,
                payload BLOB NOT NULL
            );
        """.trimIndent())

        // Tabelle dedicate per la modalità NIGHT RECORDER (Task 07)
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS night_sessions (
                session_id TEXT PRIMARY KEY,
                start_time_utc INTEGER NOT NULL,
                end_time_utc INTEGER,
                device_address TEXT NOT NULL,
                device_name TEXT,
                status TEXT NOT NULL,
                total_samples INTEGER NOT NULL DEFAULT 0,
                total_rr INTEGER NOT NULL DEFAULT 0,
                disconnections_count INTEGER NOT NULL DEFAULT 0,
                last_sample_time_utc INTEGER
            );
        """.trimIndent())

        db.execSQL("""
            CREATE TABLE IF NOT EXISTS night_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                timestamp_utc INTEGER NOT NULL,
                monotonic_millis INTEGER NOT NULL,
                hr_bpm INTEGER NOT NULL,
                flags INTEGER NOT NULL,
                sensor_contact INTEGER NOT NULL DEFAULT -1,
                rr_status TEXT NOT NULL,
                origin TEXT NOT NULL,
                conn_state TEXT NOT NULL,
                UNIQUE(session_id, timestamp_utc, hr_bpm, monotonic_millis)
            );
        """.trimIndent())

        db.execSQL("""
            CREATE INDEX IF NOT EXISTS idx_night_samples_sess 
            ON night_samples(session_id, timestamp_utc);
        """.trimIndent())

        db.execSQL("""
            CREATE TABLE IF NOT EXISTS night_rr_intervals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                sample_id INTEGER NOT NULL REFERENCES night_samples(id) ON DELETE CASCADE,
                session_id TEXT NOT NULL,
                timestamp_utc INTEGER NOT NULL,
                beat_ordinal INTEGER NOT NULL DEFAULT 0,
                rr_raw INTEGER NOT NULL,
                rr_ms_direct INTEGER NOT NULL,
                rr_ms_1024 REAL NOT NULL,
                UNIQUE(session_id, sample_id, beat_ordinal)
            );
        """.trimIndent())

        db.execSQL("""
            CREATE INDEX IF NOT EXISTS idx_night_rr_sample 
            ON night_rr_intervals(sample_id);
        """.trimIndent())

        db.execSQL("""
            CREATE TABLE IF NOT EXISTS night_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                timestamp_utc INTEGER NOT NULL,
                monotonic_millis INTEGER NOT NULL,
                event_type TEXT NOT NULL,
                details TEXT
            );
        """.trimIndent())

        db.execSQL("""
            CREATE INDEX IF NOT EXISTS idx_night_events_sess 
            ON night_events(session_id, timestamp_utc);
        """.trimIndent())

        // Tabelle dedicate ad Always-On e diagnostica di connessione (Task 08C)
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS automatic_recording_settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at_utc INTEGER NOT NULL
            );
        """.trimIndent())

        db.execSQL("""
            CREATE TABLE IF NOT EXISTS connection_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp_utc INTEGER NOT NULL,
                monotonic_millis INTEGER NOT NULL,
                session_id TEXT,
                event_type TEXT NOT NULL,
                reason_code INTEGER,
                details TEXT,
                created_at_utc INTEGER NOT NULL
            );
        """.trimIndent())

        db.execSQL("""
            CREATE INDEX IF NOT EXISTS idx_conn_events_ts 
            ON connection_events(timestamp_utc);
        """.trimIndent())

        db.execSQL("""
            CREATE INDEX IF NOT EXISTS idx_conn_events_sess 
            ON connection_events(session_id);
        """.trimIndent())

        db.execSQL("""
            CREATE TABLE IF NOT EXISTS recording_segments (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                started_at_utc INTEGER NOT NULL,
                ended_at_utc INTEGER,
                start_reason TEXT NOT NULL,
                end_reason TEXT,
                hr_count INTEGER NOT NULL DEFAULT 0,
                rr_count INTEGER NOT NULL DEFAULT 0,
                max_gap_ms INTEGER NOT NULL DEFAULT 0,
                created_at_utc INTEGER NOT NULL
            );
        """.trimIndent())

        db.execSQL("""
            CREATE INDEX IF NOT EXISTS idx_rec_segments_sess 
            ON recording_segments(session_id);
        """.trimIndent())

        db.execSQL("""
            CREATE INDEX IF NOT EXISTS idx_rec_segments_start 
            ON recording_segments(started_at_utc);
        """.trimIndent())

        // Tabelle dedicate ad Automatic Sleep Detection e Morning Report (Task 08D)
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS night_processing (
                night_key TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                state TEXT NOT NULL,
                candidate_onset INTEGER,
                candidate_offset INTEGER,
                last_processed_at INTEGER,
                algorithm_version TEXT NOT NULL,
                error_code TEXT,
                confidence REAL,
                decision_reason TEXT,
                updated_at_utc INTEGER NOT NULL
            );
        """.trimIndent())

        db.execSQL("""
            CREATE INDEX IF NOT EXISTS idx_night_proc_sess 
            ON night_processing(session_id);
        """.trimIndent())

        db.execSQL("""
            CREATE TABLE IF NOT EXISTS sleep_lab_analyses (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                night_key TEXT NOT NULL,
                session_id TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 1,
                state TEXT NOT NULL,
                algorithm_version TEXT NOT NULL,
                sleep_onset_utc INTEGER,
                sleep_end_utc INTEGER,
                tst_seconds INTEGER NOT NULL,
                waso_seconds INTEGER NOT NULL,
                sleep_efficiency REAL NOT NULL,
                hrv_rmssd_ms REAL,
                hrv_rolling_median_ms REAL,
                rhr_bpm INTEGER,
                respiration_rate REAL,
                respiration_snr REAL,
                usable_epochs_count INTEGER NOT NULL,
                total_epochs_count INTEGER NOT NULL,
                coverage_percent REAL NOT NULL,
                gaps_count INTEGER NOT NULL,
                max_gap_seconds REAL NOT NULL,
                quality_flags TEXT,
                classification_label TEXT NOT NULL DEFAULT 'EXPERIMENTAL_CARDIAC_ONLY',
                analysis_json TEXT,
                error_message TEXT,
                created_at_utc INTEGER NOT NULL,
                UNIQUE(night_key, revision)
            );
        """.trimIndent())

        db.execSQL("""
            CREATE INDEX IF NOT EXISTS idx_sleep_analyses_key 
            ON sleep_lab_analyses(night_key);
        """.trimIndent())
    }

    private fun getDb(): SQLiteDatabase {
        val db = inMemoryDb ?: writableDatabase
        createTables(db)
        return db
    }

    /**
     * Esegue la pipeline di salvataggio transazionale per un blocco storico.
     * Salva raw frames, record decodificati e aggiorna il checkpoint.
     * Restituisce true SE E SOLO SE la transazione è stata committata con successo.
     */
    fun saveHistoricalBlockTransactional(
        strapSerial: String,
        rawPackets: List<ByteArray>,
        decodedV18: List<HistoricalV18Measurement>,
        cursorToken: ByteArray?,
        timestampSeconds: Long?,
    ): Boolean {
        val db = getDb()
        db.beginTransaction()
        try {
            val nowMs = System.currentTimeMillis()

            // 1. Salva raw frames per audit / diagnostica
            for (raw in rawPackets) {
                if (raw.isEmpty()) continue
                val opcode = raw[0].toInt() and 0xFF
                val cvRaw = ContentValues().apply {
                    put("strap_serial", strapSerial)
                    put("timestamp", nowMs)
                    put("opcode", opcode)
                    put("payload", raw)
                }
                db.insert("raw_frames", null, cvRaw)
            }

            // 2. Salva record v18 con deduplicazione hardware (strap_serial, seq)
            for (rec in decodedV18) {
                val cvV18 = ContentValues().apply {
                    put("strap_serial", strapSerial)
                    put("seq", rec.seq)
                    put("timestamp", rec.timestampSeconds * 1000)
                    put("hr_primary", rec.hrPrimary)
                    put("hr_secondary", rec.hrSecondary)
                    put("rr_count", rec.rrCount)
                    put("gravity_x", rec.gravityX)
                    put("gravity_y", rec.gravityY)
                    put("gravity_z", rec.gravityZ)
                    put("accel_mag", rec.accelMagG)
                    put("step_counter", rec.stepCounter)
                    put("skin_temp_raw", rec.skinTempRaw.toInt())
                    put("skin_temp_celsius", rec.skinTempCelsius)
                    put("activity_flag", rec.activityFlag)
                    put("spo2_candidate", rec.spo2CandidateRaw)
                    put("sleep_state", rec.sleepState)
                    put("optical_baseline", rec.opticalBaseline)
                    put("optical_baseline_ch1", rec.opticalBaselineCh1)
                    put("optical_baseline_ch2", rec.opticalBaselineCh2)
                    put("is_on_wrist", if (rec.isOnWrist) 1 else 0)
                }

                // Inserimento idempotente (CONFLICT_IGNORE)
                val rowId = db.insertWithOnConflict("v18_records", null, cvV18, SQLiteDatabase.CONFLICT_IGNORE)

                // Se il record è nuovo, inserisci i relativi intervalli RR
                if (rowId > 0) {
                    for (i in rec.rrIntervalsMs.indices) {
                        val cvRr = ContentValues().apply {
                            put("v18_record_id", rowId)
                            put("timestamp", rec.timestampSeconds * 1000)
                            put("rr_ms", rec.rrIntervalsMs[i])
                            put("beat_ordinal", i)
                        }
                        db.insertWithOnConflict("rr_intervals", null, cvRr, SQLiteDatabase.CONFLICT_IGNORE)
                    }
                }
            }

            // 3. Salva checkpoint cursore se presente
            if (cursorToken != null) {
                val cvSync = ContentValues().apply {
                    put("strap_serial", strapSerial)
                    put("last_cursor", cursorToken)
                    put("last_sync_time", timestampSeconds ?: (nowMs / 1000))
                }
                db.insertWithOnConflict("sync_state", null, cvSync, SQLiteDatabase.CONFLICT_REPLACE)
            }

            db.setTransactionSuccessful()
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Fallimento transazione SQLite durante salvataggio blocco", e)
            return false
        } finally {
            db.endTransaction()
        }
    }

    /**
     * Conta i record v18 presenti nel database.
     */
    fun countV18Records(strapSerial: String? = null): Int {
        val db = getDb()
        val query = if (strapSerial != null) {
            "SELECT COUNT(*) FROM v18_records WHERE strap_serial = ?"
        } else {
            "SELECT COUNT(*) FROM v18_records"
        }
        val args = if (strapSerial != null) arrayOf(strapSerial) else null
        db.rawQuery(query, args).use { cursor ->
            return if (cursor.moveToFirst()) cursor.getInt(0) else 0
        }
    }

    /**
     * Conta gli intervalli RR presenti nel database.
     */
    fun countRrIntervals(): Int {
        val db = getDb()
        db.rawQuery("SELECT COUNT(*) FROM rr_intervals", null).use { cursor ->
            return if (cursor.moveToFirst()) cursor.getInt(0) else 0
        }
    }

    /**
     * Recupera l'ultimo cursore memorizzato per il seriale dato.
     */
    fun getLastCursor(strapSerial: String): ByteArray? {
        val db = getDb()
        db.rawQuery("SELECT last_cursor FROM sync_state WHERE strap_serial = ?", arrayOf(strapSerial)).use { cursor ->
            return if (cursor.moveToFirst()) cursor.getBlob(0) else null
        }
    }

    /**
     * Inizializza una nuova sessione di registrazione notturna (Night Recorder).
     */
    fun startNightSession(
        sessionId: String,
        deviceAddress: String,
        deviceName: String?,
        startTimeUtc: Long = System.currentTimeMillis(),
    ): Boolean {
        val db = getDb()
        val values = ContentValues().apply {
            put("session_id", sessionId)
            put("start_time_utc", startTimeUtc)
            put("device_address", deviceAddress)
            put("device_name", deviceName ?: "WHOOP 5.0")
            put("status", "RECORDING")
            put("total_samples", 0)
            put("total_rr", 0)
            put("disconnections_count", 0)
            put("last_sample_time_utc", startTimeUtc)
        }
        val rowId = db.insertWithOnConflict("night_sessions", null, values, SQLiteDatabase.CONFLICT_REPLACE)
        return rowId != -1L
    }

    /**
     * Inserisce un campione HR acquisito durante la registrazione notturna.
     * Salva progressivamente in transazione con deduplicazione.
     */
    fun insertNightSample(
        sessionId: String,
        timestampUtc: Long,
        monotonicMillis: Long,
        hrBpm: Int,
        flags: Int,
        sensorContact: Int,
        rrStatus: String,
        origin: String = "GATT_0x2A37",
        connState: String = "CONNECTED",
    ): Long {
        val db = getDb()
        val values = ContentValues().apply {
            put("session_id", sessionId)
            put("timestamp_utc", timestampUtc)
            put("monotonic_millis", monotonicMillis)
            put("hr_bpm", hrBpm)
            put("flags", flags)
            put("sensor_contact", sensorContact)
            put("rr_status", rrStatus)
            put("origin", origin)
            put("conn_state", connState)
        }
        val sampleId = db.insertWithOnConflict("night_samples", null, values, SQLiteDatabase.CONFLICT_IGNORE)
        if (sampleId != -1L) {
            db.execSQL("""
                UPDATE night_sessions 
                SET total_samples = total_samples + 1, last_sample_time_utc = ? 
                WHERE session_id = ?
            """.trimIndent(), arrayOf<Any>(timestampUtc, sessionId))
        }
        return sampleId
    }

    /**
     * Inserisce un intervallo R-R associato a un campione notturno.
     */
    fun insertNightRr(
        sampleId: Long,
        sessionId: String,
        timestampUtc: Long,
        beatOrdinal: Int,
        rrRaw: Int,
        rrMsDirect: Int,
        rrMs1024: Double,
    ): Boolean {
        val db = getDb()
        val values = ContentValues().apply {
            put("sample_id", sampleId)
            put("session_id", sessionId)
            put("timestamp_utc", timestampUtc)
            put("beat_ordinal", beatOrdinal)
            put("rr_raw", rrRaw)
            put("rr_ms_direct", rrMsDirect)
            put("rr_ms_1024", rrMs1024)
        }
        val rowId = db.insertWithOnConflict("night_rr_intervals", null, values, SQLiteDatabase.CONFLICT_IGNORE)
        if (rowId != -1L) {
            db.execSQL("""
                UPDATE night_sessions 
                SET total_rr = total_rr + 1 
                WHERE session_id = ?
            """.trimIndent(), arrayOf<Any>(sessionId))
        }
        return rowId != -1L
    }

    /**
     * Inserisce un evento diagnostico o di disconnessione durante la notte.
     */
    fun insertNightEvent(
        sessionId: String,
        timestampUtc: Long,
        monotonicMillis: Long,
        eventType: String,
        details: String?,
    ): Boolean {
        val db = getDb()
        val values = ContentValues().apply {
            put("session_id", sessionId)
            put("timestamp_utc", timestampUtc)
            put("monotonic_millis", monotonicMillis)
            put("event_type", eventType)
            put("details", details)
        }
        if (eventType == "DISCONNECTED") {
            db.execSQL("""
                UPDATE night_sessions 
                SET disconnections_count = disconnections_count + 1 
                WHERE session_id = ?
            """.trimIndent(), arrayOf<Any>(sessionId))
        }
        val rowId = db.insert("night_events", null, values)
        return rowId != -1L
    }

    /**
     * Termina la sessione di registrazione notturna aggiornando timestamp finale e stato.
     */
    fun endNightSession(
        sessionId: String,
        status: String = "COMPLETED",
        endTimeUtc: Long = System.currentTimeMillis(),
    ): Boolean {
        val db = getDb()
        val values = ContentValues().apply {
            put("end_time_utc", endTimeUtc)
            put("status", status)
        }
        val updated = db.update("night_sessions", values, "session_id = ?", arrayOf(sessionId))
        return updated > 0
    }

    /**
     * Recupera un riepilogo statistico completo della sessione notturna per il report del mattino.
     */
    fun getNightSessionSummary(sessionId: String): Map<String, Any?> {
        val db = getDb()
        val result = mutableMapOf<String, Any?>()

        // 1. Session metadata
        db.rawQuery("""
            SELECT session_id, start_time_utc, end_time_utc, device_address, device_name,
                   status, total_samples, total_rr, disconnections_count, last_sample_time_utc
            FROM night_sessions WHERE session_id = ?
        """.trimIndent(), arrayOf(sessionId)).use { c ->
            if (c.moveToFirst()) {
                result["sessionId"] = c.getString(0)
                result["startTimeUtc"] = c.getLong(1)
                result["endTimeUtc"] = if (c.isNull(2)) null else c.getLong(2)
                result["deviceAddress"] = c.getString(3)
                result["deviceName"] = c.getString(4)
                result["status"] = c.getString(5)
                result["totalSamples"] = c.getInt(6)
                result["totalRr"] = c.getInt(7)
                result["disconnectionsCount"] = c.getInt(8)
                result["lastSampleTimeUtc"] = if (c.isNull(9)) null else c.getLong(9)
            }
        }

        // 2. HR statistics (min, max, avg, median)
        db.rawQuery("""
            SELECT MIN(hr_bpm), MAX(hr_bpm), AVG(hr_bpm), COUNT(hr_bpm)
            FROM night_samples 
            WHERE session_id = ? AND hr_bpm > 0 AND hr_bpm <= 240
        """.trimIndent(), arrayOf(sessionId)).use { c ->
            if (c.moveToFirst()) {
                result["minHr"] = if (c.isNull(0)) null else c.getInt(0)
                result["maxHr"] = if (c.isNull(1)) null else c.getInt(1)
                result["avgHr"] = if (c.isNull(2)) null else c.getDouble(2)
                result["validHrSamples"] = c.getInt(3)
            }
        }

        // Median HR
        val hrList = mutableListOf<Int>()
        db.rawQuery("""
            SELECT hr_bpm FROM night_samples 
            WHERE session_id = ? AND hr_bpm > 0 AND hr_bpm <= 240 
            ORDER BY hr_bpm ASC
        """.trimIndent(), arrayOf(sessionId)).use { c ->
            while (c.moveToNext()) {
                hrList.add(c.getInt(0))
            }
        }
        if (hrList.isNotEmpty()) {
            val mid = hrList.size / 2
            val median = if (hrList.size % 2 == 1) {
                hrList[mid].toDouble()
            } else {
                (hrList[mid - 1] + hrList[mid]) / 2.0
            }
            result["medianHr"] = median
        } else {
            result["medianHr"] = null
        }

        // 3. RR intervals & RMSSD
        val rrList = mutableListOf<Int>()
        db.rawQuery("""
            SELECT rr_ms_direct FROM night_rr_intervals 
            WHERE session_id = ? AND rr_ms_direct >= 300 AND rr_ms_direct <= 2000
            ORDER BY timestamp_utc ASC, beat_ordinal ASC
        """.trimIndent(), arrayOf(sessionId)).use { c ->
            while (c.moveToNext()) {
                rrList.add(c.getInt(0))
            }
        }
        result["validRrCount"] = rrList.size
        if (rrList.size >= 2) {
            var sumSq = 0.0
            for (i in 1 until rrList.size) {
                val diff = (rrList[i] - rrList[i - 1]).toDouble()
                sumSq += diff * diff
            }
            val rmssd = kotlin.math.sqrt(sumSq / (rrList.size - 1))
            result["rmssdMs"] = rmssd
        } else {
            result["rmssdMs"] = null
        }

        return result
    }


    // ==========================================
    // METODI ALWAYS-ON & DIAGNOSTICA (Task 08C)
    // ==========================================

    fun setSetting(key: String, value: String, updatedAtUtc: Long = System.currentTimeMillis()) {
        val db = getDb()
        val cv = ContentValues().apply {
            put("key", key)
            put("value", value)
            put("updated_at_utc", updatedAtUtc)
        }
        db.insertWithOnConflict("automatic_recording_settings", null, cv, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun getSetting(key: String, defaultValue: String? = null): String? {
        val db = getDb()
        db.rawQuery(
            "SELECT value FROM automatic_recording_settings WHERE key = ?",
            arrayOf(key)
        ).use { c ->
            if (c.moveToFirst()) {
                return c.getString(0)
            }
        }
        return defaultValue
    }

    fun isAlwaysOnEnabled(): Boolean {
        return getSetting("always_on_enabled", "false") == "true"
    }

    fun setAlwaysOnEnabled(enabled: Boolean) {
        setSetting("always_on_enabled", if (enabled) "true" else "false")
    }

    fun insertConnectionEvent(
        eventType: String,
        reasonCode: Int? = null,
        details: String? = null,
        sessionId: String? = null,
        timestampUtc: Long = System.currentTimeMillis(),
        monotonicMillis: Long = System.nanoTime() / 1_000_000L,
    ): Long {
        val db = getDb()
        val cv = ContentValues().apply {
            put("timestamp_utc", timestampUtc)
            put("monotonic_millis", monotonicMillis)
            put("session_id", sessionId)
            put("event_type", eventType)
            put("reason_code", reasonCode)
            put("details", details)
            put("created_at_utc", System.currentTimeMillis())
        }
        return db.insert("connection_events", null, cv)
    }

    fun startRecordingSegment(
        segmentId: String,
        sessionId: String,
        startedAtUtc: Long,
        startReason: String,
    ): Boolean {
        val db = getDb()
        val cv = ContentValues().apply {
            put("id", segmentId)
            put("session_id", sessionId)
            put("started_at_utc", startedAtUtc)
            put("start_reason", startReason)
            put("hr_count", 0)
            put("rr_count", 0)
            put("max_gap_ms", 0)
            put("created_at_utc", System.currentTimeMillis())
        }
        return db.insertWithOnConflict("recording_segments", null, cv, SQLiteDatabase.CONFLICT_REPLACE) != -1L
    }

    fun updateRecordingSegmentMetrics(
        segmentId: String,
        hrCount: Int,
        rrCount: Int,
        maxGapMs: Long,
    ): Boolean {
        val db = getDb()
        val cv = ContentValues().apply {
            put("hr_count", hrCount)
            put("rr_count", rrCount)
            put("max_gap_ms", maxGapMs)
        }
        return db.update("recording_segments", cv, "id = ?", arrayOf(segmentId)) > 0
    }

    fun endRecordingSegment(
        segmentId: String,
        endedAtUtc: Long,
        endReason: String,
        hrCount: Int,
        rrCount: Int,
        maxGapMs: Long,
    ): Boolean {
        val db = getDb()
        val cv = ContentValues().apply {
            put("ended_at_utc", endedAtUtc)
            put("end_reason", endReason)
            put("hr_count", hrCount)
            put("rr_count", rrCount)
            put("max_gap_ms", maxGapMs)
        }
        return db.update("recording_segments", cv, "id = ?", arrayOf(segmentId)) > 0
    }

    fun getRecentConnectionEvents(limit: Int = 50): List<Map<String, Any?>> {
        val db = getDb()
        val list = mutableListOf<Map<String, Any?>>()
        db.rawQuery(
            "SELECT id, timestamp_utc, monotonic_millis, session_id, event_type, reason_code, details FROM connection_events ORDER BY id DESC LIMIT ?",
            arrayOf(limit.toString())
        ).use { c ->
            while (c.moveToNext()) {
                list.add(mapOf(
                    "id" to c.getLong(0),
                    "timestampUtc" to c.getLong(1),
                    "monotonicMillis" to c.getLong(2),
                    "sessionId" to if (c.isNull(3)) null else c.getString(3),
                    "eventType" to c.getString(4),
                    "reasonCode" to if (c.isNull(5)) null else c.getInt(5),
                    "details" to if (c.isNull(6)) null else c.getString(6),
                ))
            }
        }
        return list
    }

    fun getRecordingSegments(sessionId: String): List<Map<String, Any?>> {
        val db = getDb()
        val list = mutableListOf<Map<String, Any?>>()
        db.rawQuery(
            "SELECT id, session_id, started_at_utc, ended_at_utc, start_reason, end_reason, hr_count, rr_count, max_gap_ms FROM recording_segments WHERE session_id = ? ORDER BY started_at_utc ASC",
            arrayOf(sessionId)
        ).use { c ->
            while (c.moveToNext()) {
                list.add(mapOf(
                    "id" to c.getString(0),
                    "sessionId" to c.getString(1),
                    "startedAtUtc" to c.getLong(2),
                    "endedAtUtc" to if (c.isNull(3)) null else c.getLong(3),
                    "startReason" to c.getString(4),
                    "endReason" to if (c.isNull(5)) null else c.getString(5),
                    "hrCount" to c.getInt(6),
                    "rrCount" to c.getInt(7),
                    "maxGapMs" to c.getLong(8),
                ))
            }
        }
        return list
    }

    fun getLastDisconnectEvent(): Map<String, Any?>? {
        val db = getDb()
        db.rawQuery(
            "SELECT timestamp_utc, reason_code, details FROM connection_events WHERE event_type LIKE '%DISCONNECT%' ORDER BY id DESC LIMIT 1",
            null
        ).use { c ->
            if (c.moveToFirst()) {
                return mapOf(
                    "timestampUtc" to c.getLong(0),
                    "reasonCode" to if (c.isNull(1)) null else c.getInt(1),
                    "details" to if (c.isNull(2)) null else c.getString(2),
                )
            }
        }
        return null
    }

    // TASK 08D: Metodi per la Night State Machine e Sleep Lab Analysis

    fun saveNightProcessingState(
        nightKey: String,
        sessionId: String,
        state: String,
        candidateOnset: Long? = null,
        candidateOffset: Long? = null,
        lastProcessedAt: Long? = null,
        algorithmVersion: String = "1.0.0-cardiac-only",
        errorCode: String? = null,
        confidence: Double? = null,
        decisionReason: String? = null,
    ) {
        val db = getDb()
        val now = System.currentTimeMillis()
        val cv = ContentValues().apply {
            put("night_key", nightKey)
            put("session_id", sessionId)
            put("state", state)
            put("candidate_onset", candidateOnset)
            put("candidate_offset", candidateOffset)
            put("last_processed_at", lastProcessedAt)
            put("algorithm_version", algorithmVersion)
            put("error_code", errorCode)
            put("confidence", confidence)
            put("decision_reason", decisionReason)
            put("updated_at_utc", now)
        }
        db.insertWithOnConflict("night_processing", null, cv, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun getNightProcessing(nightKey: String): Map<String, Any?>? {
        val db = getDb()
        db.rawQuery(
            "SELECT night_key, session_id, state, candidate_onset, candidate_offset, last_processed_at, algorithm_version, error_code, confidence, decision_reason, updated_at_utc FROM night_processing WHERE night_key = ?",
            arrayOf(nightKey)
        ).use { c ->
            if (c.moveToFirst()) {
                return mapOf(
                    "nightKey" to c.getString(0),
                    "sessionId" to c.getString(1),
                    "state" to c.getString(2),
                    "candidateOnset" to if (c.isNull(3)) null else c.getLong(3),
                    "candidateOffset" to if (c.isNull(4)) null else c.getLong(4),
                    "lastProcessedAt" to if (c.isNull(5)) null else c.getLong(5),
                    "algorithmVersion" to c.getString(6),
                    "errorCode" to if (c.isNull(7)) null else c.getString(7),
                    "confidence" to if (c.isNull(8)) null else c.getDouble(8),
                    "decisionReason" to if (c.isNull(9)) null else c.getString(9),
                    "updatedAtUtc" to c.getLong(10),
                )
            }
        }
        return null
    }

    fun getLatestNightProcessing(): Map<String, Any?>? {
        val db = getDb()
        db.rawQuery(
            "SELECT night_key, session_id, state, candidate_onset, candidate_offset, last_processed_at, algorithm_version, error_code, confidence, decision_reason, updated_at_utc FROM night_processing ORDER BY updated_at_utc DESC LIMIT 1",
            null
        ).use { c ->
            if (c.moveToFirst()) {
                return mapOf(
                    "nightKey" to c.getString(0),
                    "sessionId" to c.getString(1),
                    "state" to c.getString(2),
                    "candidateOnset" to if (c.isNull(3)) null else c.getLong(3),
                    "candidateOffset" to if (c.isNull(4)) null else c.getLong(4),
                    "lastProcessedAt" to if (c.isNull(5)) null else c.getLong(5),
                    "algorithmVersion" to c.getString(6),
                    "errorCode" to if (c.isNull(7)) null else c.getString(7),
                    "confidence" to if (c.isNull(8)) null else c.getDouble(8),
                    "decisionReason" to if (c.isNull(9)) null else c.getString(9),
                    "updatedAtUtc" to c.getLong(10),
                )
            }
        }
        return null
    }

    fun saveSleepLabAnalysis(
        nightKey: String,
        sessionId: String,
        revision: Int = 1,
        state: String,
        algorithmVersion: String = "1.0.0-cardiac-only",
        sleepOnsetUtc: Long?,
        sleepEndUtc: Long?,
        tstSeconds: Int,
        wasoSeconds: Int,
        sleepEfficiency: Double,
        hrvRmssdMs: Double?,
        hrvRollingMedianMs: Double?,
        rhrBpm: Int?,
        respirationRate: Double?,
        respirationSnr: Double?,
        usableEpochsCount: Int,
        totalEpochsCount: Int,
        coveragePercent: Double,
        gapsCount: Int,
        maxGapSeconds: Double,
        qualityFlags: String? = null,
        classificationLabel: String = "EXPERIMENTAL_CARDIAC_ONLY",
        analysisJson: String? = null,
        errorMessage: String? = null,
    ): Long {
        val db = getDb()
        val now = System.currentTimeMillis()
        val cv = ContentValues().apply {
            put("night_key", nightKey)
            put("session_id", sessionId)
            put("revision", revision)
            put("state", state)
            put("algorithm_version", algorithmVersion)
            put("sleep_onset_utc", sleepOnsetUtc)
            put("sleep_end_utc", sleepEndUtc)
            put("tst_seconds", tstSeconds)
            put("waso_seconds", wasoSeconds)
            put("sleep_efficiency", sleepEfficiency)
            put("hrv_rmssd_ms", hrvRmssdMs)
            put("hrv_rolling_median_ms", hrvRollingMedianMs)
            put("rhr_bpm", rhrBpm)
            put("respiration_rate", respirationRate)
            put("respiration_snr", respirationSnr)
            put("usable_epochs_count", usableEpochsCount)
            put("total_epochs_count", totalEpochsCount)
            put("coverage_percent", coveragePercent)
            put("gaps_count", gapsCount)
            put("max_gap_seconds", maxGapSeconds)
            put("quality_flags", qualityFlags)
            put("classification_label", classificationLabel)
            put("analysis_json", analysisJson)
            put("error_message", errorMessage)
            put("created_at_utc", now)
        }
        return db.insertWithOnConflict("sleep_lab_analyses", null, cv, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun getLatestSleepLabAnalysis(): Map<String, Any?>? {
        val db = getDb()
        db.rawQuery(
            """SELECT id, night_key, session_id, revision, state, algorithm_version, 
                      sleep_onset_utc, sleep_end_utc, tst_seconds, waso_seconds, 
                      sleep_efficiency, hrv_rmssd_ms, hrv_rolling_median_ms, rhr_bpm, 
                      respiration_rate, respiration_snr, usable_epochs_count, 
                      total_epochs_count, coverage_percent, gaps_count, max_gap_seconds, 
                      quality_flags, classification_label, analysis_json, error_message, 
                      created_at_utc 
               FROM sleep_lab_analyses ORDER BY created_at_utc DESC, revision DESC LIMIT 1""",
            null
        ).use { c ->
            if (c.moveToFirst()) {
                return mapOf(
                    "id" to c.getLong(0),
                    "nightKey" to c.getString(1),
                    "sessionId" to c.getString(2),
                    "revision" to c.getInt(3),
                    "state" to c.getString(4),
                    "algorithmVersion" to c.getString(5),
                    "sleepOnsetUtc" to if (c.isNull(6)) null else c.getLong(6),
                    "sleepEndUtc" to if (c.isNull(7)) null else c.getLong(7),
                    "tstSeconds" to c.getInt(8),
                    "wasoSeconds" to c.getInt(9),
                    "sleepEfficiency" to c.getDouble(10),
                    "hrvRmssdMs" to if (c.isNull(11)) null else c.getDouble(11),
                    "hrvRollingMedianMs" to if (c.isNull(12)) null else c.getDouble(12),
                    "rhrBpm" to if (c.isNull(13)) null else c.getInt(13),
                    "respirationRate" to if (c.isNull(14)) null else c.getDouble(14),
                    "respirationSnr" to if (c.isNull(15)) null else c.getDouble(15),
                    "usableEpochsCount" to c.getInt(16),
                    "totalEpochsCount" to c.getInt(17),
                    "coveragePercent" to c.getDouble(18),
                    "gapsCount" to c.getInt(19),
                    "maxGapSeconds" to c.getDouble(20),
                    "qualityFlags" to if (c.isNull(21)) null else c.getString(21),
                    "classificationLabel" to c.getString(22),
                    "analysisJson" to if (c.isNull(23)) null else c.getString(23),
                    "errorMessage" to if (c.isNull(24)) null else c.getString(24),
                    "createdAtUtc" to c.getLong(25),
                )
            }
        }
        return null
    }

    data class NightSampleRow(
        val id: Long,
        val timestampUtc: Long,
        val monotonicMillis: Long,
        val hrBpm: Int,
        val flags: Int
    )

    data class NightRrRow(
        val id: Long,
        val sampleId: Long,
        val timestampUtc: Long,
        val beatOrdinal: Int,
        val rrMsDirect: Int
    )

    fun getSamplesForSession(sessionId: String): List<NightSampleRow> {
        val db = getDb()
        val list = mutableListOf<NightSampleRow>()
        db.rawQuery(
            "SELECT id, timestamp_utc, monotonic_millis, hr_bpm, flags FROM night_samples WHERE session_id = ? ORDER BY timestamp_utc ASC",
            arrayOf(sessionId)
        ).use { c ->
            while (c.moveToNext()) {
                list.add(NightSampleRow(
                    id = c.getLong(0),
                    timestampUtc = c.getLong(1),
                    monotonicMillis = c.getLong(2),
                    hrBpm = c.getInt(3),
                    flags = c.getInt(4)
                ))
            }
        }
        return list
    }

    fun getRrIntervalsForSession(sessionId: String): List<NightRrRow> {
        val db = getDb()
        val list = mutableListOf<NightRrRow>()
        db.rawQuery(
            "SELECT id, sample_id, timestamp_utc, beat_ordinal, rr_ms_direct FROM night_rr_intervals WHERE session_id = ? ORDER BY timestamp_utc ASC, beat_ordinal ASC",
            arrayOf(sessionId)
        ).use { c ->
            while (c.moveToNext()) {
                list.add(NightRrRow(
                    id = c.getLong(0),
                    sampleId = c.getLong(1),
                    timestampUtc = c.getLong(2),
                    beatOrdinal = c.getInt(3),
                    rrMsDirect = c.getInt(4)
                ))
            }
        }
        return list
    }

    companion object {
        private const val TAG = "WhoopStorageEngine"
        const val DATABASE_VERSION = 1

        /** Factory per creare un engine in memoria per test unitari */
        fun inMemory(): WhoopStorageEngine {
            val db = SQLiteDatabase.create(null)
            return WhoopStorageEngine(context = null, inMemoryDb = db)
        }
    }
}
