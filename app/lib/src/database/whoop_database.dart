import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Gestore del database SQLite locale per i dati WHOOP 5.0.
///
/// Crea e mantiene le tabelle per:
/// - `v18_records`: record storici 1Hz (con vincolo UNIQUE su strap_serial, seq)
/// - `rr_intervals`: intervalli R-R beat-to-beat in millisecondi per analisi HRV
/// - `v26_records`: forme d'onda PPG a 24Hz
/// - `sync_state`: cursori e stato di avanzamento per offload continuativo
class WhoopDatabase {
  WhoopDatabase({this.customPath, Database? database}) : _db = database;

  /// Costruttore per database in memoria (utile per test unitari veloci).
  factory WhoopDatabase.inMemory() =>
      WhoopDatabase(customPath: inMemoryDatabasePath);

  static const String databaseName = 'whoop_local.db';
  static const int databaseVersion = 1;

  final String? customPath;
  Database? _db;

  /// Restituisce l'istanza attiva del database SQLite, aprendola se necessario.
  Future<Database> get database async {
    if (_db != null && _db!.isOpen) return _db!;
    _db = await open();
    return _db!;
  }

  /// Apre la connessione al database eseguendo la configurazione PRAGMA e la creazione schema.
  Future<Database> open() async {
    final path = customPath ?? p.join(await getDatabasesPath(), databaseName);
    return openDatabase(
      path,
      version: databaseVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onOpen: _onOpen,
    );
  }

  static Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON;');
    final path = db.path;
    if (path != inMemoryDatabasePath && path != ':memory:') {
      await db.execute('PRAGMA journal_mode = WAL;');
      await db.execute('PRAGMA synchronous = NORMAL;');
      await db.execute('PRAGMA busy_timeout = 5000;');
    }
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
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
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_v18_serial_seq 
      ON v18_records(strap_serial, seq);
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_v18_timestamp 
      ON v18_records(timestamp);
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_v18_serial_ts 
      ON v18_records(strap_serial, timestamp);
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS rr_intervals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        v18_record_id INTEGER NOT NULL REFERENCES v18_records(id) ON DELETE CASCADE,
        timestamp INTEGER NOT NULL,
        rr_ms INTEGER NOT NULL,
        beat_ordinal INTEGER NOT NULL DEFAULT 0,
        UNIQUE(v18_record_id, beat_ordinal)
      );
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_rr_record_id 
      ON rr_intervals(v18_record_id);
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_rr_timestamp 
      ON rr_intervals(timestamp);
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS v26_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        strap_serial TEXT NOT NULL,
        seq INTEGER NOT NULL,
        timestamp INTEGER NOT NULL,
        ppg_samples BLOB NOT NULL
      );
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_v26_serial_seq 
      ON v26_records(strap_serial, seq);
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_v26_timestamp 
      ON v26_records(timestamp);
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        strap_serial TEXT NOT NULL UNIQUE,
        last_cursor BLOB NOT NULL,
        last_sync_time INTEGER NOT NULL
      );
    ''');

    // Tabelle dedicate alla modalità NIGHT RECORDER (Task 07)
    await db.execute('''
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
    ''');

    await db.execute('''
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
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_night_samples_sess 
      ON night_samples(session_id, timestamp_utc);
    ''');

    await db.execute('''
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
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_night_rr_sample 
      ON night_rr_intervals(sample_id);
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS night_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        timestamp_utc INTEGER NOT NULL,
        monotonic_millis INTEGER NOT NULL,
        event_type TEXT NOT NULL,
        details TEXT
      );
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_night_events_sess 
      ON night_events(session_id, timestamp_utc);
    ''');

    await _createSleepLabTables(db);
    await _createAlwaysOnTables(db);
  }

  static Future<void> _onOpen(Database db) async {
    await _createSleepLabTables(db);
    await _createAlwaysOnTables(db);
  }

  static Future<void> _createAlwaysOnTables(Database db) async {
    // Tabelle dedicate ad Always-On e diagnostica di connessione (Task 08C)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS automatic_recording_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at_utc INTEGER NOT NULL
      );
    ''');

    await db.execute('''
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
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_conn_events_ts 
      ON connection_events(timestamp_utc);
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_conn_events_sess 
      ON connection_events(session_id);
    ''');

    await db.execute('''
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
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_rec_segments_sess 
      ON recording_segments(session_id);
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_rec_segments_start 
      ON recording_segments(started_at_utc);
    ''');
  }

  static Future<void> _createSleepLabTables(Database db) async {
    // Tabelle dedicate a Beveltry Sleep Lab e Confronto WHOOP A (Task 08A)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS whoop_a_comparisons (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        created_at_utc INTEGER NOT NULL,
        algorithm_version TEXT NOT NULL,
        sleep_onset_utc INTEGER,
        sleep_end_utc INTEGER,
        sleep_duration_seconds INTEGER,
        awake_duration_seconds INTEGER,
        light_duration_seconds INTEGER,
        deep_duration_seconds INTEGER,
        rem_duration_seconds INTEGER,
        hrv_rmssd REAL,
        rhr_bpm INTEGER,
        respiratory_rate REAL,
        recovery_score INTEGER,
        sleep_performance_score INTEGER,
        notes TEXT,
        UNIQUE(session_id) ON CONFLICT REPLACE
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS sleep_lab_manual_boundaries (
        session_id TEXT PRIMARY KEY,
        manual_onset_utc INTEGER,
        manual_end_utc INTEGER,
        updated_at_utc INTEGER NOT NULL
      );
    ''');

    // Tabelle dedicate ad Automatic Sleep Detection e Morning Report (Task 08D)
    await db.execute('''
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
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_night_proc_sess 
      ON night_processing(session_id);
    ''');

    await db.execute('''
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
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sleep_analyses_key 
      ON sleep_lab_analyses(night_key);
    ''');
  }

  /// Chiude la connessione al database se aperta.
  Future<void> close() async {
    if (_db != null && _db!.isOpen) {
      await _db!.close();
      _db = null;
    }
  }
}
