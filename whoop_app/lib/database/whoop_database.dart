import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../protocol/puffin_decoder.dart';

class WhoopDatabase {
  static WhoopDatabase? _instance;
  Database? _db;
  int? _lastValidRrMs;

  WhoopDatabase._();

  static WhoopDatabase get instance {
    _instance ??= WhoopDatabase._();
    return _instance!;
  }

  Database get database {
    if (_db == null) {
      throw StateError('Database not initialized. Call init() first.');
    }
    return _db!;
  }

  Future<void> init({String? customPath}) async {
    if (_db != null) return;

    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    String dbPath;
    if (customPath != null) {
      dbPath = customPath;
    } else if (Platform.isWindows) {
      // Prioritize the canonical workspace data path, then relative, then app documents
      List<String> candidatePaths = [
        r'C:\Users\costa\Downloads\Bevel\data\whoop_local.db',
        p.join(Directory.current.path, 'data', 'whoop_local.db'),
        p.join(Directory.current.path, '..', 'data', 'whoop_local.db'),
      ];
      String? foundPath;
      for (var path in candidatePaths) {
        if (File(path).existsSync()) {
          foundPath = path;
          break;
        }
      }
      if (foundPath != null) {
        dbPath = foundPath;
      } else {
        Directory appDoc = await getApplicationDocumentsDirectory();
        dbPath = p.join(appDoc.path, 'whoop_local.db');
      }
    } else {
      String databasesPath = await getDatabasesPath();
      dbPath = p.join(databasesPath, 'whoop_local.db');
    }

    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await _createTables(db);
      },
    );

    // Enable WAL mode
    await _db!.execute('PRAGMA journal_mode = WAL;');
    await _db!.execute('PRAGMA synchronous = NORMAL;');
  }

  Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS devices (
        serial_number TEXT PRIMARY KEY,
        mac_address TEXT,
        model TEXT,
        hw_revision TEXT,
        fw_revision TEXT,
        last_sync_timestamp_unix INTEGER,
        last_cursor_hex TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS records_1hz (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        serial_number TEXT NOT NULL,
        timestamp_unix INTEGER NOT NULL,
        sequence INTEGER,
        primary_hr INTEGER,
        secondary_hr INTEGER,
        rr_count INTEGER,
        rr_ms_json TEXT,
        accel_x REAL,
        accel_y REAL,
        accel_z REAL,
        accel_mag_g REAL,
        movement_delta_g REAL,
        steps INTEGER,
        skin_temp_c REAL,
        sleep_state INTEGER,
        optical_baseline INTEGER,
        is_on_wrist INTEGER,
        raw_hex TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(serial_number, timestamp_unix)
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS rr_intervals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        serial_number TEXT NOT NULL,
        timestamp_unix INTEGER NOT NULL,
        beat_ordinal INTEGER NOT NULL,
        rr_ms INTEGER NOT NULL,
        is_physiologically_valid INTEGER NOT NULL,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(serial_number, timestamp_unix, beat_ordinal)
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS daily_cycles (
        date TEXT PRIMARY KEY,
        recovery_score INTEGER,
        day_strain REAL,
        sleep_performance REAL,
        hrv_rmssd REAL,
        rhr_bpm REAL,
        skin_temp_delta REAL,
        stress_avg REAL,
        respiratory_rate REAL,
        calculated_at TEXT DEFAULT CURRENT_TIMESTAMP
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS workouts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        start_time_unix INTEGER,
        end_time_unix INTEGER,
        duration_seconds INTEGER,
        avg_hr INTEGER,
        max_hr INTEGER,
        strain REAL,
        sport_name TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS calibrations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp_unix INTEGER NOT NULL,
        date TEXT NOT NULL,
        whoop_a_hrv REAL,
        whoop_b_hrv REAL,
        delta_hrv_pct REAL,
        whoop_a_rhr REAL,
        whoop_b_rhr REAL,
        delta_rhr_pct REAL,
        whoop_a_strain REAL,
        whoop_b_strain REAL,
        delta_strain_pct REAL,
        whoop_a_recovery INTEGER,
        whoop_b_recovery INTEGER,
        delta_recovery_pct REAL,
        notes TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      );
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_records_ts ON records_1hz (serial_number, timestamp_unix);',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rr_ts ON rr_intervals (serial_number, timestamp_unix);',
    );
  }

  /// Upserts device metadata.
  Future<void> registerDevice({
    required String serialNumber,
    required String macAddress,
    String model = 'WHOOP 5WP',
    String? hwRevision,
    String? fwRevision,
  }) async {
    await database.rawInsert('''
      INSERT INTO devices (serial_number, mac_address, model, hw_revision, fw_revision, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, datetime('now'), datetime('now'))
      ON CONFLICT(serial_number) DO UPDATE SET
        mac_address = excluded.mac_address,
        model = excluded.model,
        hw_revision = coalesce(excluded.hw_revision, devices.hw_revision),
        fw_revision = coalesce(excluded.fw_revision, devices.fw_revision),
        updated_at = datetime('now');
    ''', [serialNumber, macAddress, model, hwRevision, fwRevision]);
  }

  /// Updates checkpoint cursor and last sync timestamp.
  Future<void> updateSyncCheckpoint({
    required String serialNumber,
    required int syncTimestampUnix,
    required String cursorHex,
  }) async {
    await database.rawUpdate('''
      UPDATE devices
      SET last_sync_timestamp_unix = ?,
          last_cursor_hex = ?,
          updated_at = datetime('now')
      WHERE serial_number = ?;
    ''', [syncTimestampUnix, cursorHex, serialNumber]);
  }

  /// Ingests a batch of HistoricalRecordV18 with strict hardware deduplication and Physiological Gate.
  Future<Map<String, int>> ingestRecordsBatch(
    String serialNumber,
    List<HistoricalRecordV18> records,
  ) async {
    if (records.isEmpty) return {'records_inserted': 0, 'rr_inserted': 0};

    int recordsInserted = 0;
    int rrInserted = 0;

    await database.transaction((txn) async {
      Batch batch = txn.batch();

      for (var r in records) {
        batch.rawInsert('''
          INSERT INTO records_1hz (
            serial_number, timestamp_unix, sequence, primary_hr, secondary_hr,
            rr_count, rr_ms_json, accel_x, accel_y, accel_z, accel_mag_g,
            movement_delta_g, steps, skin_temp_c, sleep_state, optical_baseline,
            is_on_wrist, raw_hex
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(serial_number, timestamp_unix) DO UPDATE SET
            primary_hr = excluded.primary_hr,
            rr_count = max(records_1hz.rr_count, excluded.rr_count),
            rr_ms_json = CASE WHEN excluded.rr_count > records_1hz.rr_count THEN excluded.rr_ms_json ELSE records_1hz.rr_ms_json END,
            skin_temp_c = excluded.skin_temp_c,
            optical_baseline = excluded.optical_baseline,
            is_on_wrist = excluded.is_on_wrist
          WHERE excluded.rr_count > records_1hz.rr_count;
        ''', [
          serialNumber,
          r.timestampUnix,
          r.sequence,
          r.primaryHr,
          r.secondaryHr,
          r.rrCount,
          jsonEncode(r.rrIntervalsMs),
          r.accelX,
          r.accelY,
          r.accelZ,
          r.accelMagG,
          r.movementDeltaG,
          r.steps,
          r.skinTempC,
          r.sleepState,
          r.opticalBaseline,
          r.isOnWrist ? 1 : 0,
          r.rawHex,
        ]);

        // Physiological Gate for RR intervals
        for (int i = 0; i < r.rrIntervalsMs.length; i++) {
          int rr = r.rrIntervalsMs[i];
          bool isValid = (rr >= 250 && rr <= 2000);
          if (isValid && _lastValidRrMs != null) {
            double delta = (rr - _lastValidRrMs!).abs() / _lastValidRrMs!;
            if (delta >= 0.25) {
              isValid = false; // Ectopic or artifact
            }
          }
          if (isValid) {
            _lastValidRrMs = rr;
          }

          batch.rawInsert('''
            INSERT OR IGNORE INTO rr_intervals (
              serial_number, timestamp_unix, beat_ordinal, rr_ms, is_physiologically_valid
            ) VALUES (?, ?, ?, ?, ?);
          ''', [
            serialNumber,
            r.timestampUnix,
            i,
            rr,
            isValid ? 1 : 0,
          ]);
        }
      }

      var results = await batch.commit(noResult: false);
      recordsInserted = results.where((r) => r is int && r > 0).length;
      rrInserted = records.fold(0, (sum, r) => sum + r.rrIntervalsMs.length);
    });

    return {
      'records_inserted': recordsInserted,
      'rr_inserted': rrInserted,
    };
  }

  /// Fetches the latest records for biometric analysis.
  Future<List<Map<String, dynamic>>> getRecords({
    int limit = 3600,
    int? sinceTimestamp,
  }) async {
    if (sinceTimestamp != null) {
      return await database.query(
        'records_1hz',
        where: 'timestamp_unix >= ?',
        whereArgs: [sinceTimestamp],
        orderBy: 'timestamp_unix ASC',
        limit: limit,
      );
    }
    return await database.query(
      'records_1hz',
      orderBy: 'timestamp_unix DESC',
      limit: limit,
    );
  }

  /// Fetches physiologically valid RR intervals.
  Future<List<int>> getValidRrIntervals({int limit = 2000}) async {
    var rows = await database.query(
      'rr_intervals',
      columns: ['rr_ms'],
      where: 'is_physiologically_valid = 1',
      orderBy: 'timestamp_unix ASC, beat_ordinal ASC',
      limit: limit,
    );
    return rows.map((r) => r['rr_ms'] as int).toList();
  }

  /// Total count of 1Hz records stored.
  Future<int> getRecordCount() async {
    var res = await database.rawQuery('SELECT COUNT(*) as count FROM records_1hz');
    return Sqflite.firstIntValue(res) ?? 0;
  }

  /// Saves a ground truth calibration comparison between WHOOP A and WHOOP B.
  Future<int> saveCalibration({
    required double whoopAHrv,
    required double whoopBHrv,
    required double whoopARhr,
    required double whoopBRhr,
    required double whoopAStrain,
    required double whoopBStrain,
    required int whoopARecovery,
    required int whoopBRecovery,
    String? notes,
  }) async {
    int nowTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    String todayDate = DateTime.now().toIso8601String().substring(0, 10);

    double deltaHrvPct = whoopAHrv > 0 ? ((whoopBHrv - whoopAHrv) / whoopAHrv * 100.0) : 0.0;
    double deltaRhrPct = whoopARhr > 0 ? ((whoopBRhr - whoopARhr) / whoopARhr * 100.0) : 0.0;
    double deltaStrainPct = whoopAStrain > 0 ? ((whoopBStrain - whoopAStrain) / whoopAStrain * 100.0) : 0.0;
    double deltaRecovPct = whoopARecovery > 0 ? ((whoopBRecovery - whoopARecovery) / whoopARecovery * 100.0) : 0.0;

    return await database.insert('calibrations', {
      'timestamp_unix': nowTs,
      'date': todayDate,
      'whoop_a_hrv': whoopAHrv,
      'whoop_b_hrv': whoopBHrv,
      'delta_hrv_pct': (deltaHrvPct * 10).round() / 10.0,
      'whoop_a_rhr': whoopARhr,
      'whoop_b_rhr': whoopBRhr,
      'delta_rhr_pct': (deltaRhrPct * 10).round() / 10.0,
      'whoop_a_strain': whoopAStrain,
      'whoop_b_strain': whoopBStrain,
      'delta_strain_pct': (deltaStrainPct * 10).round() / 10.0,
      'whoop_a_recovery': whoopARecovery,
      'whoop_b_recovery': whoopBRecovery,
      'delta_recovery_pct': (deltaRecovPct * 10).round() / 10.0,
      'notes': notes,
    });
  }

  /// Retrieves the latest calibration entry.
  Future<Map<String, dynamic>?> getLatestCalibration() async {
    var rows = await database.query(
      'calibrations',
      orderBy: 'timestamp_unix DESC',
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.first;
    return null;
  }

  /// Retrieves all recorded calibrations.
  Future<List<Map<String, dynamic>>> getCalibrations({int limit = 50}) async {
    return await database.query(
      'calibrations',
      orderBy: 'timestamp_unix DESC',
      limit: limit,
    );
  }

  /// Saves a recorded workout session.
  Future<int> saveWorkoutSession({
    required int startTimeUnix,
    required int endTimeUnix,
    required int durationSeconds,
    required int avgHr,
    required int maxHr,
    required double strain,
    required String sportName,
  }) async {
    return await database.insert('workouts', {
      'start_time_unix': startTimeUnix,
      'end_time_unix': endTimeUnix,
      'duration_seconds': durationSeconds,
      'avg_hr': avgHr,
      'max_hr': maxHr,
      'strain': strain,
      'sport_name': sportName,
    });
  }

  /// Retrieves recorded workouts.
  Future<List<Map<String, dynamic>>> getWorkoutSessions({int limit = 30}) async {
    return await database.query(
      'workouts',
      orderBy: 'start_time_unix DESC',
      limit: limit,
    );
  }

  /// Retrieves device metadata.
  Future<Map<String, dynamic>?> getDeviceMetadata(String serialNumber) async {
    var rows = await database.query(
      'devices',
      where: 'serial_number = ?',
      whereArgs: [serialNumber],
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.first;
    return null;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
