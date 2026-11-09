import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../database/whoop_database.dart';
import '../records/v18_record.dart';
import '../records/v26_record.dart';

/// Repository per la gestione persistente e deduplicata dei dati WHOOP 5.0.
///
/// Implementa il pattern Repository sul database SQLite locale, gestendo
/// transazioni per consistenza e deduplicazione automatica tramite vincoli UNIQUE.
class WhoopRepository {
  WhoopRepository({WhoopDatabase? database})
      : _database = database ?? WhoopDatabase();

  /// Crea un'istanza del repository configurata per database in-memory.
  factory WhoopRepository.inMemory() =>
      WhoopRepository(database: WhoopDatabase.inMemory());

  final WhoopDatabase _database;

  /// Restituisce l'istanza attiva del database.
  Future<Database> get _db => _database.database;

  /// Salva un record [V18Record] e i suoi intervalli R-R associati in una singola transazione.
  ///
  /// Se un record per lo stesso [strapSerial] e [V18Record.seq] esiste già nel database,
  /// l'inserimento viene ignorato (deduplicazione hardware delle re-deliveries).
  Future<void> saveV18Record(V18Record record, String strapSerial) async {
    final db = await _db;
    await db.transaction((txn) async {
      // Verifica se il record è già presente per deduplicazione
      final existing = await txn.query(
        'v18_records',
        columns: ['id'],
        where: 'strap_serial = ? AND seq = ?',
        whereArgs: [strapSerial, record.seq],
        limit: 1,
      );

      if (existing.isNotEmpty) {
        // Record già presente: scarta duplicato re-delivered
        return;
      }

      final recordId = await txn.insert(
        'v18_records',
        {
          'strap_serial': strapSerial,
          'seq': record.seq,
          'timestamp': record.timestamp.toUtc().millisecondsSinceEpoch,
          'hr_primary': record.hrPrimary,
          'hr_secondary': record.hrSecondary,
          'rr_count': record.rrCount,
          'gravity_x': record.gravityX,
          'gravity_y': record.gravityY,
          'gravity_z': record.gravityZ,
          'accel_mag': record.accelMagG,
          'step_counter': record.stepCounter,
          'skin_temp_raw': record.skinTempRaw,
          'skin_temp_celsius': record.skinTempCelsius,
          'activity_flag': record.activityFlag,
          'spo2_candidate': record.spo2Candidate,
          'sleep_state': record.sleepState,
          'optical_baseline': record.opticalBaseline,
          'optical_baseline_ch1': record.opticalBaselineCh1,
          'optical_baseline_ch2': record.opticalBaselineCh2,
          'is_on_wrist': record.isOnWrist ? 1 : 0,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      if (recordId <= 0) return;

      for (var i = 0; i < record.rrIntervalsMs.length; i++) {
        await txn.insert(
          'rr_intervals',
          {
            'v18_record_id': recordId,
            'timestamp': record.timestamp.toUtc().millisecondsSinceEpoch,
            'rr_ms': record.rrIntervalsMs[i],
            'beat_ordinal': i,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  /// Salva un batch di record [V18Record] in un'unica transazione.
  Future<void> saveV18RecordsBatch(
    List<V18Record> records,
    String strapSerial,
  ) async {
    if (records.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      for (final record in records) {
        final existing = await txn.query(
          'v18_records',
          columns: ['id'],
          where: 'strap_serial = ? AND seq = ?',
          whereArgs: [strapSerial, record.seq],
          limit: 1,
        );

        if (existing.isNotEmpty) continue;

        final recordId = await txn.insert(
          'v18_records',
          {
            'strap_serial': strapSerial,
            'seq': record.seq,
            'timestamp': record.timestamp.toUtc().millisecondsSinceEpoch,
            'hr_primary': record.hrPrimary,
            'hr_secondary': record.hrSecondary,
            'rr_count': record.rrCount,
            'gravity_x': record.gravityX,
            'gravity_y': record.gravityY,
            'gravity_z': record.gravityZ,
            'accel_mag': record.accelMagG,
            'step_counter': record.stepCounter,
            'skin_temp_raw': record.skinTempRaw,
            'skin_temp_celsius': record.skinTempCelsius,
            'activity_flag': record.activityFlag,
            'spo2_candidate': record.spo2Candidate,
            'sleep_state': record.sleepState,
            'optical_baseline': record.opticalBaseline,
            'optical_baseline_ch1': record.opticalBaselineCh1,
            'optical_baseline_ch2': record.opticalBaselineCh2,
            'is_on_wrist': record.isOnWrist ? 1 : 0,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );

        if (recordId <= 0) continue;

        for (var i = 0; i < record.rrIntervalsMs.length; i++) {
          await txn.insert(
            'rr_intervals',
            {
              'v18_record_id': recordId,
              'timestamp': record.timestamp.toUtc().millisecondsSinceEpoch,
              'rr_ms': record.rrIntervalsMs[i],
              'beat_ordinal': i,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }
    });
  }

  /// Recupera tutti i [V18Record] registrati tra [start] ed [end] inclusi,
  /// ordinati cronologicamente in modo crescente.
  Future<List<V18Record>> getRecordsInRange(
    DateTime start,
    DateTime end, {
    String? strapSerial,
  }) async {
    final db = await _db;
    final startMs = start.toUtc().millisecondsSinceEpoch;
    final endMs = end.toUtc().millisecondsSinceEpoch;

    final String whereClause;
    final List<Object?> whereArgs;

    if (strapSerial != null) {
      whereClause = 'timestamp >= ? AND timestamp <= ? AND strap_serial = ?';
      whereArgs = [startMs, endMs, strapSerial];
    } else {
      whereClause = 'timestamp >= ? AND timestamp <= ?';
      whereArgs = [startMs, endMs];
    }

    final rows = await db.query(
      'v18_records',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'timestamp ASC, seq ASC',
    );

    if (rows.isEmpty) return <V18Record>[];

    final recordIds = rows.map((r) => r['id'] as int).toList();
    final placeholders = List.filled(recordIds.length, '?').join(',');

    final rrRows = await db.query(
      'rr_intervals',
      where: 'v18_record_id IN ($placeholders)',
      whereArgs: recordIds,
      orderBy: 'v18_record_id ASC, beat_ordinal ASC',
    );

    final rrMap = <int, List<int>>{};
    for (final rr in rrRows) {
      final recId = rr['v18_record_id'] as int;
      final ms = rr['rr_ms'] as int;
      (rrMap[recId] ??= <int>[]).add(ms);
    }

    return rows.map((row) {
      final id = row['id'] as int;
      final rrs = rrMap[id] ?? const <int>[];
      return _mapRowToV18Record(row, rrs);
    }).toList();
  }

  /// Recupera gli ultimi [limit] record [V18Record] registrati nel database,
  /// ordinati cronologicamente in modo crescente per l'analisi DSP.
  ///
  /// Questo metodo risolve il problema del "database vuoto" dovuto a sfasamenti
  /// di orologio o mancato allineamento con DateTime.now().
  Future<List<V18Record>> getLatestRecords({
    int limit = 5000,
    String? strapSerial,
  }) async {
    final db = await _db;
    final String? whereClause;
    final List<Object?>? whereArgs;

    if (strapSerial != null) {
      whereClause = 'strap_serial = ?';
      whereArgs = [strapSerial];
    } else {
      whereClause = null;
      whereArgs = null;
    }

    final rows = await db.query(
      'v18_records',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'timestamp DESC, seq DESC',
      limit: limit,
    );

    if (rows.isEmpty) return <V18Record>[];

    final recordIds = rows.map((r) => r['id'] as int).toList();
    final placeholders = List.filled(recordIds.length, '?').join(',');

    final rrRows = await db.query(
      'rr_intervals',
      where: 'v18_record_id IN ($placeholders)',
      whereArgs: recordIds,
      orderBy: 'v18_record_id ASC, beat_ordinal ASC',
    );

    final rrMap = <int, List<int>>{};
    for (final rr in rrRows) {
      final recId = rr['v18_record_id'] as int;
      final ms = rr['rr_ms'] as int;
      (rrMap[recId] ??= <int>[]).add(ms);
    }

    final records = rows.map((row) {
      final id = row['id'] as int;
      final rrs = rrMap[id] ?? const <int>[];
      return _mapRowToV18Record(row, rrs);
    }).toList();

    return records.reversed.toList();
  }

  /// Salva l'ultimo cursore offload ricevuto per l'ACK su `fd4b0002`.
  Future<void> saveCursor(
    Uint8List cursor, {
    String strapSerial = 'default',
  }) async {
    final db = await _db;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await db.insert(
      'sync_state',
      {
        'strap_serial': strapSerial,
        'last_cursor': cursor,
        'last_sync_time': nowMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Recupera l'ultimo cursore memorizzato per riprendere l'offload.
  Future<Uint8List?> getLastCursor({
    String strapSerial = 'default',
  }) async {
    final db = await _db;
    final rows = await db.query(
      'sync_state',
      columns: ['last_cursor'],
      where: 'strap_serial = ?',
      whereArgs: [strapSerial],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    final blob = rows.first['last_cursor'];
    if (blob is Uint8List) return blob;
    if (blob is List<int>) return Uint8List.fromList(blob);
    return null;
  }

  /// Salva un record [V26Record] di campioni PPG a 24Hz.
  Future<void> saveV26Record(
    V26Record record,
    String strapSerial, {
    required int seq,
    DateTime? timestamp,
  }) async {
    final db = await _db;
    final ts = (timestamp ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    final bytes = Uint8List(record.ppgSamples.length * 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < record.ppgSamples.length; i++) {
      data.setInt16(i * 2, record.ppgSamples[i], Endian.little);
    }

    await db.insert(
      'v26_records',
      {
        'strap_serial': strapSerial,
        'seq': seq,
        'timestamp': ts,
        'ppg_samples': bytes,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Restituisce il conteggio totale dei record v26 memorizzati.
  Future<int> countV26Records({String? strapSerial}) async {
    final db = await _db;
    final String query = strapSerial != null
        ? 'SELECT COUNT(*) as count FROM v26_records WHERE strap_serial = ?'
        : 'SELECT COUNT(*) as count FROM v26_records';
    final List<Object?> args = strapSerial != null ? [strapSerial] : [];
    final res = await db.rawQuery(query, args);
    return Sqflite.firstIntValue(res) ?? 0;
  }

  /// Restituisce il conteggio totale dei record v18 memorizzati.
  Future<int> countV18Records({String? strapSerial}) async {
    final db = await _db;
    final String query = strapSerial != null
        ? 'SELECT COUNT(*) as count FROM v18_records WHERE strap_serial = ?'
        : 'SELECT COUNT(*) as count FROM v18_records';
    final List<Object?> args = strapSerial != null ? [strapSerial] : [];
    final res = await db.rawQuery(query, args);
    return Sqflite.firstIntValue(res) ?? 0;
  }

  /// Restituisce il conteggio totale degli intervalli R-R memorizzati.
  Future<int> countRrIntervals() async {
    final db = await _db;
    final res = await db.rawQuery('SELECT COUNT(*) as count FROM rr_intervals');
    return Sqflite.firstIntValue(res) ?? 0;
  }

  /// Restituisce la lista di intervalli R-R in millisecondi nell'intervallo temporale specificato.
  Future<List<int>> getRrIntervalsInRange(
    DateTime start,
    DateTime end,
  ) async {
    final db = await _db;
    final startMs = start.toUtc().millisecondsSinceEpoch;
    final endMs = end.toUtc().millisecondsSinceEpoch;

    final rows = await db.query(
      'rr_intervals',
      columns: ['rr_ms'],
      where: 'timestamp >= ? AND timestamp <= ?',
      whereArgs: [startMs, endMs],
      orderBy: 'timestamp ASC, beat_ordinal ASC',
    );

    return rows.map((r) => r['rr_ms'] as int).toList();
  }

  /// Chiude la connessione al database sottostante.
  Future<void> close() => _database.close();

  static V18Record _mapRowToV18Record(
    Map<String, Object?> row,
    List<int> rrIntervals,
  ) {
    final rawTemp = row['skin_temp_raw'] as int?;
    final celsiusTemp = row['skin_temp_celsius'] != null
        ? (row['skin_temp_celsius'] as num).toDouble()
        : (rawTemp != null ? rawTemp / 10.0 : null);
    final optBaseline = row['optical_baseline'] as int;
    final optCh1 = row['optical_baseline_ch1'] as int? ?? optBaseline;
    final optCh2 = row['optical_baseline_ch2'] as int?;
    final isOnWrist = (row['is_on_wrist'] as int? ?? 0) == 1;

    return V18Record(
      seq: row['seq'] as int,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        row['timestamp'] as int,
        isUtc: true,
      ),
      hrPrimary: row['hr_primary'] as int,
      hrSecondary: row['hr_secondary'] as int,
      rrCount: row['rr_count'] as int,
      rrIntervalsMs: List<int>.unmodifiable(rrIntervals),
      gravityX: (row['gravity_x'] as num).toDouble(),
      gravityY: (row['gravity_y'] as num).toDouble(),
      gravityZ: (row['gravity_z'] as num).toDouble(),
      accelMagG: (row['accel_mag'] as num).toDouble(),
      stepCounter: row['step_counter'] as int,
      skinTempRaw: rawTemp,
      skinTempCelsius: celsiusTemp,
      activityFlag: row['activity_flag'] as int,
      spo2Candidate: row['spo2_candidate'] as int,
      sleepState: row['sleep_state'] as int,
      opticalBaselineCh1: optCh1,
      opticalBaselineCh2: optCh2,
      opticalBaseline: optBaseline,
      isOnWrist: isOnWrist,
    );
  }
}
