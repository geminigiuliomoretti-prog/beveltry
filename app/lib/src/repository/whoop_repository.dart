import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../database/whoop_database.dart';
import '../dsp/hrv_rmssd.dart';
import '../dsp/rhr_calculator.dart';
import '../records/night_session_summary.dart';
import '../records/v18_record.dart';
import '../records/v26_record.dart';
import '../sleep_lab/whoop_a_comparison.dart';

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

  // =========================================================================
  // METODI NIGHT RECORDER (Task 07)
  // =========================================================================

  /// Avvia una nuova sessione di registrazione notturna.
  Future<void> startNightSession({
    required String sessionId,
    required String deviceAddress,
    String? deviceName,
    DateTime? startTime,
  }) async {
    final db = await _db;
    final nowMs = (startTime ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    await db.insert(
      'night_sessions',
      {
        'session_id': sessionId,
        'start_time_utc': nowMs,
        'device_address': deviceAddress,
        'device_name': deviceName ?? 'WHOOP 5.0',
        'status': 'RECORDING',
        'total_samples': 0,
        'total_rr': 0,
        'disconnections_count': 0,
        'last_sample_time_utc': nowMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Salva un singolo campione HR notturno in una transazione isolata.
  Future<void> saveNightSample({
    required String sessionId,
    required DateTime timestamp,
    required int monotonicMillis,
    required int hrBpm,
    required int flags,
    required int sensorContact,
    required String rrStatus,
    String origin = 'GATT_0x2A37',
    String connState = 'CONNECTED',
    List<int> rawRrIntervals = const [],
  }) async {
    final db = await _db;
    final tsMs = timestamp.toUtc().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      final sampleId = await txn.insert(
        'night_samples',
        {
          'session_id': sessionId,
          'timestamp_utc': tsMs,
          'monotonic_millis': monotonicMillis,
          'hr_bpm': hrBpm,
          'flags': flags,
          'sensor_contact': sensorContact,
          'rr_status': rrStatus,
          'origin': origin,
          'conn_state': connState,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      if (sampleId <= 0) return;

      for (var i = 0; i < rawRrIntervals.length; i++) {
        final rawRr = rawRrIntervals[i];
        final rrMsDirect = rawRr;
        final rrMs1024 = rawRr * 1000.0 / 1024.0;

        await txn.insert(
          'night_rr_intervals',
          {
            'sample_id': sampleId,
            'session_id': sessionId,
            'timestamp_utc': tsMs,
            'beat_ordinal': i,
            'rr_raw': rawRr,
            'rr_ms_direct': rrMsDirect,
            'rr_ms_1024': rrMs1024,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }

      await txn.rawUpdate('''
        UPDATE night_sessions 
        SET total_samples = total_samples + 1,
            total_rr = total_rr + ?,
            last_sample_time_utc = ?
        WHERE session_id = ?
      ''', [rawRrIntervals.length, tsMs, sessionId]);
    });
  }

  /// Registra un evento di connessione o disconnessione durante la notte.
  Future<void> logNightEvent({
    required String sessionId,
    required DateTime timestamp,
    required int monotonicMillis,
    required String eventType,
    String? details,
  }) async {
    final db = await _db;
    final tsMs = timestamp.toUtc().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      await txn.insert('night_events', {
        'session_id': sessionId,
        'timestamp_utc': tsMs,
        'monotonic_millis': monotonicMillis,
        'event_type': eventType,
        'details': details,
      });

      if (eventType == 'DISCONNECTED') {
        await txn.rawUpdate('''
          UPDATE night_sessions 
          SET disconnections_count = disconnections_count + 1 
          WHERE session_id = ?
        ''', [sessionId]);
      }
    });
  }

  /// Conclude la sessione di registrazione notturna.
  Future<void> endNightSession({
    required String sessionId,
    String status = 'COMPLETED',
    DateTime? endTime,
  }) async {
    final db = await _db;
    final nowMs = (endTime ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    await db.update(
      'night_sessions',
      {
        'end_time_utc': nowMs,
        'status': status,
      },
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Calcola ed esporta il rapporto del mattino completo per una sessione notturna.
  Future<NightSessionSummary> getNightSessionSummary(String sessionId) async {
    final db = await _db;

    // 1. Dati della sessione
    final sessionRows = await db.query(
      'night_sessions',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );

    if (sessionRows.isEmpty) {
      throw ArgumentError('Sessione $sessionId non trovata nel database.');
    }

    final sRow = sessionRows.first;
    final startMs = sRow['start_time_utc'] as int;
    final endMs = sRow['end_time_utc'] as int? ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    final startTimeUtc = DateTime.fromMillisecondsSinceEpoch(startMs, isUtc: true);
    final endTimeUtc = sRow['end_time_utc'] != null
        ? DateTime.fromMillisecondsSinceEpoch(endMs, isUtc: true)
        : null;
    final deviceAddress = sRow['device_address'] as String? ?? 'UNKNOWN';
    final deviceName = sRow['device_name'] as String? ?? 'WHOOP 5.0';
    final status = sRow['status'] as String? ?? 'RECORDING';
    final totalSamples = sRow['total_samples'] as int? ?? 0;
    final totalRr = sRow['total_rr'] as int? ?? 0;
    final disconnectionsCount = sRow['disconnections_count'] as int? ?? 0;

    final durationSeconds = ((endMs - startMs) / 1000).round().clamp(0, double.infinity).toInt();

    // 2. Campioni HR per calcolo medie e RHR
    final sampleRows = await db.query(
      'night_samples',
      columns: ['timestamp_utc', 'hr_bpm'],
      where: 'session_id = ? AND hr_bpm > 0 AND hr_bpm <= 240',
      whereArgs: [sessionId],
      orderBy: 'timestamp_utc ASC',
    );

    final hrValues = <int>[];
    final hrPoints = <HrSamplePoint>[];
    for (final row in sampleRows) {
      final bpm = row['hr_bpm'] as int;
      final ts = DateTime.fromMillisecondsSinceEpoch(row['timestamp_utc'] as int, isUtc: true);
      hrValues.add(bpm);
      hrPoints.add(HrSamplePoint(timestampUtc: ts, hrBpm: bpm));
    }

    double? meanHr;
    double? medianHr;
    int? minHr;
    int? maxHr;
    int? estimatedRhr;

    if (hrValues.isNotEmpty) {
      final sum = hrValues.fold<int>(0, (a, b) => a + b);
      meanHr = sum / hrValues.length;

      final sorted = List<int>.from(hrValues)..sort();
      final mid = sorted.length ~/ 2;
      medianHr = sorted.length.isOdd
          ? sorted[mid].toDouble()
          : (sorted[mid - 1] + sorted[mid]) / 2.0;

      minHr = sorted.first;
      maxHr = sorted.last;

      // RHR con finestra mobile a 5 minuti (300 campioni validi)
      estimatedRhr = calculateRhrFromHrValues(hrValues, windowSize: 300);
    }

    // 3. Intervalli R-R e calcolo HRV RMSSD (v1 legacy + v2 segmentato gap-aware)
    final rrRows = await db.query(
      'night_rr_intervals',
      columns: ['timestamp_utc', 'beat_ordinal', 'rr_ms_direct'],
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp_utc ASC, beat_ordinal ASC',
    );

    final beatIntervals = rrRows.map((r) {
      final ts = DateTime.fromMillisecondsSinceEpoch(r['timestamp_utc'] as int, isUtc: true);
      final rr = r['rr_ms_direct'] as int;
      final ord = r['beat_ordinal'] as int? ?? 0;
      return BeatInterval(timestampUtc: ts, rrMs: rr, beatOrdinal: ord);
    }).toList();

    final hrvResult = calculateSegmentedHrv(
      beats: beatIntervals,
      gapThresholdSeconds: 2.0,
      minPhysiologicalMs: 300,
      maxPhysiologicalMs: 2000,
    );

    // 4. Disconnessioni e durata offline
    final eventRows = await db.query(
      'night_events',
      columns: ['timestamp_utc', 'event_type'],
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp_utc ASC',
    );

    var disconnectionDurationSeconds = 0;
    int? disconnectStartMs;
    for (final ev in eventRows) {
      final type = ev['event_type'] as String;
      final ts = ev['timestamp_utc'] as int;
      if (type == 'DISCONNECTED') {
        disconnectStartMs = ts;
      } else if (type == 'CONNECTED' && disconnectStartMs != null) {
        disconnectionDurationSeconds += ((ts - disconnectStartMs) / 1000).round();
        disconnectStartMs = null;
      }
    }
    if (disconnectStartMs != null && endTimeUtc != null) {
      disconnectionDurationSeconds += ((endMs - disconnectStartMs) / 1000).round();
    }

    // 5. Percentuale di copertura (stimata assumendo 1 notifica al secondo)
    final expectedSamples = durationSeconds > 0 ? durationSeconds : 1;
    final coveragePercent = (totalSamples / expectedSamples * 100.0).clamp(0.0, 100.0);

    // 6. Mappa metriche non disponibili con motivazione esplicita
    final missingMetrics = <String, String>{
      'Deep Sleep HRV': 'Il calcolo dell\'HRV specifico per il sonno profondo richiede la stadiazione proprietaria delle fasi del sonno.',
      'WHOOP Recovery Score': 'Algoritmo proprietario WHOOP non simulato; calcolo disabilitato per preservare l\'integrità scientifica dei dati.',
      'Fasi del Sonno (REM / Profondo / Leggero)': 'Richiede algoritmi proprietari combinati di accelerometria multiasse e fotopletismografia ottica.',
      'SpO2 (Saturazione Ossigeno)': 'Bloccata a livello hardware dall\'Entitlement Gate del firmware WHOOP (byte @82 = 0x00 senza abbonamento attivo).',
      'Frequenza Respiratoria': 'Richiede modello DSP proprietario sulle fluttuazioni respiratorie dell\'intervallo R-R.',
      'Temperatura Cutanea': 'Disponibile esclusivamente nei record storici Puffin 0x2F v18 autenticati.',
    };

    return NightSessionSummary(
      sessionId: sessionId,
      startTimeUtc: startTimeUtc,
      endTimeUtc: endTimeUtc,
      deviceAddress: deviceAddress,
      deviceName: deviceName,
      status: status,
      totalSamples: totalSamples,
      totalRr: totalRr,
      disconnectionsCount: disconnectionsCount,
      meanHr: meanHr,
      medianHr: medianHr,
      minHr: minHr,
      maxHr: maxHr,
      rmssdMs: hrvResult.legacyRmssdMs,
      segmentedRmssdMs: hrvResult.segmentedRmssdMs,
      segmentedRmssd1024Ms: hrvResult.segmentedRmssd1024Ms,
      legacyRmssd1024Ms: hrvResult.legacyRmssd1024Ms,
      excludedPhysiologicalBeats: hrvResult.excludedPhysiologicalBeats,
      excludedGapsCount: hrvResult.excludedGapsCount,
      segmentsCount: hrvResult.segmentsCount,
      validSuccessiveDiffsCount: hrvResult.validSuccessiveDiffsCount,
      estimatedRhr: estimatedRhr,
      coveragePercent: coveragePercent,
      totalDurationSeconds: durationSeconds,
      disconnectionDurationSeconds: disconnectionDurationSeconds,
      hrTimeSeries: hrPoints,
      missingMetrics: missingMetrics,
    );
  }

  /// Recupera tutte le sessioni notturne registrate nel database.
  Future<List<Map<String, dynamic>>> getAllNightSessions() async {
    final db = await _db;
    return db.query('night_sessions', orderBy: 'start_time_utc DESC');
  }

  /// Esporta i dati notturni in un file CSV contenente [timestamp], [hr] e [rr_raw] grezzi.
  ///
  /// Conforme ai requisiti di integrità:
  /// - NON modifica in alcun modo i dati originali nel database (sola lettura SELECT).
  /// - NON include alcun identificativo Bluetooth (né MAC address, né device name, né UUID).
  /// - Non altera gli intervalli R-R grezzi (Regola Inviolabile 2: ms diretti).
  Future<File> exportNightDataToCsv({
    String? sessionId,
    String? targetFilePath,
  }) async {
    final db = await _db;

    String? targetSessionId = sessionId;
    if (targetSessionId == null) {
      final latestSession = await db.query(
        'night_sessions',
        columns: ['session_id'],
        orderBy: 'start_time_utc DESC',
        limit: 1,
      );
      if (latestSession.isNotEmpty) {
        targetSessionId = latestSession.first['session_id'] as String?;
      }
    }

    final List<Map<String, Object?>> sampleRows;
    if (targetSessionId != null) {
      sampleRows = await db.rawQuery('''
        SELECT 
          s.id AS sample_id,
          s.timestamp_utc,
          s.hr_bpm,
          r.rr_raw
        FROM night_samples s
        LEFT JOIN night_rr_intervals r ON s.id = r.sample_id
        WHERE s.session_id = ?
        ORDER BY s.timestamp_utc ASC, r.beat_ordinal ASC
      ''', [targetSessionId]);
    } else {
      sampleRows = await db.rawQuery('''
        SELECT 
          s.id AS sample_id,
          s.timestamp_utc,
          s.hr_bpm,
          r.rr_raw
        FROM night_samples s
        LEFT JOIN night_rr_intervals r ON s.id = r.sample_id
        ORDER BY s.timestamp_utc ASC, r.beat_ordinal ASC
      ''');
    }

    final buffer = StringBuffer();
    buffer.writeln('timestamp,hr,rr_raw');

    for (final row in sampleRows) {
      final tsUtc = row['timestamp_utc'] as int;
      final hr = row['hr_bpm'] as int;
      final rrRaw = row['rr_raw'] as int?;
      final isoTs = DateTime.fromMillisecondsSinceEpoch(tsUtc, isUtc: true).toIso8601String();
      final rrStr = rrRaw != null ? '$rrRaw' : '';
      buffer.writeln('$isoTs,$hr,$rrStr');
    }

    final File outputFile;
    if (targetFilePath != null) {
      outputFile = File(targetFilePath);
    } else {
      String? dirPath;
      try {
        final extDir = await getExternalStorageDirectory();
        dirPath = extDir?.path;
      } catch (_) {}
      if (dirPath == null) {
        try {
          final docDir = await getApplicationDocumentsDirectory();
          dirPath = docDir.path;
        } catch (_) {
          dirPath = Directory.systemTemp.path;
        }
      }
      final sessSuffix = targetSessionId ?? 'all_${DateTime.now().toUtc().millisecondsSinceEpoch}';
      final fileName = 'whoop_night_data_$sessSuffix.csv';
      outputFile = File(p.join(dirPath, fileName));
    }

    await outputFile.parent.create(recursive: true);
    await outputFile.writeAsString(buffer.toString(), flush: true);
    return outputFile;
  }

  // =========================================================================
  // METODI SLEEP LAB & CONFRONTO WHOOP A (Task 08A)
  // =========================================================================

  /// Recupera tutti i campioni HR grezzi per una specifica sessione notturna.
  Future<List<HrSamplePoint>> getRawNightSamples(String sessionId) async {
    final db = await _db;
    final rows = await db.query(
      'night_samples',
      columns: ['timestamp_utc', 'hr_bpm'],
      where: 'session_id = ? AND hr_bpm > 0 AND hr_bpm <= 240',
      whereArgs: [sessionId],
      orderBy: 'timestamp_utc ASC',
    );

    return rows.map((r) {
      return HrSamplePoint(
        timestampUtc: DateTime.fromMillisecondsSinceEpoch(r['timestamp_utc'] as int, isUtc: true),
        hrBpm: r['hr_bpm'] as int,
      );
    }).toList();
  }

  /// Recupera tutti gli intervalli R-R grezzi per una specifica sessione notturna.
  Future<List<BeatInterval>> getRawNightRrIntervals(String sessionId) async {
    final db = await _db;
    final rows = await db.query(
      'night_rr_intervals',
      columns: ['timestamp_utc', 'beat_ordinal', 'rr_raw', 'rr_ms_direct'],
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp_utc ASC, beat_ordinal ASC',
    );

    return rows.map((r) {
      final ts = DateTime.fromMillisecondsSinceEpoch(r['timestamp_utc'] as int, isUtc: true);
      final rr = (r['rr_ms_direct'] ?? r['rr_raw']) as int;
      final ord = r['beat_ordinal'] as int? ?? 0;
      return BeatInterval(timestampUtc: ts, rrMs: rr, beatOrdinal: ord);
    }).toList();
  }

  /// Salva o aggiorna i dati ufficiali WHOOP A per una notte.
  Future<void> saveWhoopAComparison(WhoopAComparisonRecord record) async {
    final db = await _db;
    await db.insert(
      'whoop_a_comparisons',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Recupera il confronto WHOOP A associato alla sessione, se presente.
  Future<WhoopAComparisonRecord?> getWhoopAComparisonForSession(String sessionId) async {
    final db = await _db;
    final rows = await db.query(
      'whoop_a_comparisons',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return WhoopAComparisonRecord.fromMap(rows.first);
  }

  /// Salva i confini di sonno corretti manualmente dall'utente.
  Future<void> saveManualSleepBoundaries({
    required String sessionId,
    DateTime? manualOnset,
    DateTime? manualEnd,
  }) async {
    final db = await _db;
    await db.insert(
      'sleep_lab_manual_boundaries',
      {
        'session_id': sessionId,
        'manual_onset_utc': manualOnset?.toUtc().millisecondsSinceEpoch,
        'manual_end_utc': manualEnd?.toUtc().millisecondsSinceEpoch,
        'updated_at_utc': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Recupera i confini manuali impostati per una sessione.
  Future<Map<String, DateTime?>> getManualSleepBoundaries(String sessionId) async {
    final db = await _db;
    final rows = await db.query(
      'sleep_lab_manual_boundaries',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return {'manualOnset': null, 'manualEnd': null};
    }
    final row = rows.first;
    final onsetMs = row['manual_onset_utc'] as int?;
    final endMs = row['manual_end_utc'] as int?;
    return {
      'manualOnset': onsetMs != null ? DateTime.fromMillisecondsSinceEpoch(onsetMs, isUtc: true) : null,
      'manualEnd': endMs != null ? DateTime.fromMillisecondsSinceEpoch(endMs, isUtc: true) : null,
    };
  }

  /// Chiude la connessione al database sottostante.

  // ==========================================
  // METODI ALWAYS-ON & DIAGNOSTICA (Task 08C)
  // ==========================================

  /// Salva una preferenza Always-On in automatic_recording_settings.
  Future<void> setSetting(String key, String value) async {
    final db = await _database.database;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await db.insert(
      'automatic_recording_settings',
      {'key': key, 'value': value, 'updated_at_utc': nowMs},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Recupera una preferenza Always-On.
  Future<String?> getSetting(String key, {String? defaultValue}) async {
    final db = await _database.database;
    final rows = await db.query(
      'automatic_recording_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      return rows.first['value'] as String?;
    }
    return defaultValue;
  }

  /// Verifica se la registrazione automatica Always-On è attiva.
  Future<bool> isAlwaysOnEnabled() async {
    final val = await getSetting('always_on_enabled', defaultValue: 'false');
    return val == 'true';
  }

  /// Imposta lo stato di Always-On in SQLite.
  Future<void> setAlwaysOnEnabled(bool enabled) async {
    await setSetting('always_on_enabled', enabled ? 'true' : 'false');
  }

  /// Registra un evento di connessione o gap nella tabella connection_events.
  Future<int> logConnectionEvent({
    required String eventType,
    int? reasonCode,
    String? details,
    String? sessionId,
    DateTime? timestamp,
    int? monotonicMillis,
  }) async {
    final db = await _database.database;
    final now = timestamp ?? DateTime.now().toUtc();
    final mono = monotonicMillis ?? now.millisecondsSinceEpoch;
    return db.insert(
      'connection_events',
      {
        'timestamp_utc': now.millisecondsSinceEpoch,
        'monotonic_millis': mono,
        'session_id': sessionId,
        'event_type': eventType,
        'reason_code': reasonCode,
        'details': details,
        'created_at_utc': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
    );
  }

  /// Restituisce gli eventi di connessione recenti per diagnostica.
  Future<List<Map<String, dynamic>>> getRecentConnectionEvents({int limit = 50}) async {
    final db = await _database.database;
    return db.query(
      'connection_events',
      orderBy: 'id DESC',
      limit: limit,
    );
  }

  /// Avvia un segmento di registrazione (apertura/riconnessione).
  Future<void> startRecordingSegment({
    required String segmentId,
    required String sessionId,
    required DateTime startedAt,
    required String startReason,
  }) async {
    final db = await _database.database;
    await db.insert(
      'recording_segments',
      {
        'id': segmentId,
        'session_id': sessionId,
        'started_at_utc': startedAt.toUtc().millisecondsSinceEpoch,
        'start_reason': startReason,
        'hr_count': 0,
        'rr_count': 0,
        'max_gap_ms': 0,
        'created_at_utc': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Aggiorna le metriche del segmento corrente (durante lo streaming).
  Future<void> updateRecordingSegmentMetrics({
    required String segmentId,
    required int hrCount,
    required int rrCount,
    required int maxGapMs,
  }) async {
    final db = await _database.database;
    await db.update(
      'recording_segments',
      {
        'hr_count': hrCount,
        'rr_count': rrCount,
        'max_gap_ms': maxGapMs,
      },
      where: 'id = ?',
      whereArgs: [segmentId],
    );
  }

  /// Chiude un segmento di registrazione (disconnessione o termine).
  Future<void> endRecordingSegment({
    required String segmentId,
    required DateTime endedAt,
    required String endReason,
    required int hrCount,
    required int rrCount,
    required int maxGapMs,
  }) async {
    final db = await _database.database;
    await db.update(
      'recording_segments',
      {
        'ended_at_utc': endedAt.toUtc().millisecondsSinceEpoch,
        'end_reason': endReason,
        'hr_count': hrCount,
        'rr_count': rrCount,
        'max_gap_ms': maxGapMs,
      },
      where: 'id = ?',
      whereArgs: [segmentId],
    );
  }

  /// Restituisce tutti i segmenti registrati per una data sessione.
  Future<List<Map<String, dynamic>>> getRecordingSegments(String sessionId) async {
    final db = await _database.database;
    return db.query(
      'recording_segments',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'started_at_utc ASC',
    );
  }

  /// Restituisce l'ultimo evento di disconnessione registrato.
  Future<Map<String, dynamic>?> getLastDisconnectEvent() async {
    final db = await _database.database;
    final rows = await db.query(
      'connection_events',
      where: 'event_type LIKE ?',
      whereArgs: ['%DISCONNECT%'],
      orderBy: 'id DESC',
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first : null;
  }

  // ==========================================
  // TASK 08D: METODI PER AUTO SLEEP & REPORT
  // ==========================================

  /// Recupera lo stato di elaborazione dell'ultima notte rilevata.
  Future<Map<String, dynamic>?> getLatestNightProcessing() async {
    final db = await _database.database;
    final rows = await db.query(
      'night_processing',
      orderBy: 'updated_at_utc DESC',
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first : null;
  }

  /// Recupera l'ultima analisi del sonno memorizzata (Sleep Lab Analysis atomica).
  Future<Map<String, dynamic>?> getLatestSleepLabAnalysis() async {
    final db = await _database.database;
    final rows = await db.query(
      'sleep_lab_analyses',
      orderBy: 'created_at_utc DESC, revision DESC',
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first : null;
  }

  /// Salva lo stato di elaborazione notturna.
  Future<void> saveNightProcessingState({
    required String nightKey,
    required String sessionId,
    required String state,
    int? candidateOnset,
    int? candidateOffset,
    int? lastProcessedAt,
    String algorithmVersion = '1.0.0-cardiac-only',
    String? errorCode,
    double? confidence,
    String? decisionReason,
  }) async {
    final db = await _database.database;
    await db.insert(
      'night_processing',
      {
        'night_key': nightKey,
        'session_id': sessionId,
        'state': state,
        'candidate_onset': candidateOnset,
        'candidate_offset': candidateOffset,
        'last_processed_at': lastProcessedAt,
        'algorithm_version': algorithmVersion,
        'error_code': errorCode,
        'confidence': confidence,
        'decision_reason': decisionReason,
        'updated_at_utc': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Salva il record atomico dell'analisi Sleep Lab.
  Future<void> saveSleepLabAnalysisRecord({
    required String nightKey,
    required String sessionId,
    int revision = 1,
    required String state,
    String algorithmVersion = '1.0.0-cardiac-only',
    int? sleepOnsetUtc,
    int? sleepEndUtc,
    required int tstSeconds,
    required int wasoSeconds,
    required double sleepEfficiency,
    double? hrvRmssdMs,
    double? hrvRollingMedianMs,
    int? rhrBpm,
    double? respirationRate,
    double? respirationSnr,
    required int usableEpochsCount,
    required int totalEpochsCount,
    required double coveragePercent,
    required int gapsCount,
    required double maxGapSeconds,
    String? qualityFlags,
    String classificationLabel = 'EXPERIMENTAL_CARDIAC_ONLY',
    String? analysisJson,
    String? errorMessage,
  }) async {
    final db = await _database.database;
    await db.insert(
      'sleep_lab_analyses',
      {
        'night_key': nightKey,
        'session_id': sessionId,
        'revision': revision,
        'state': state,
        'algorithm_version': algorithmVersion,
        'sleep_onset_utc': sleepOnsetUtc,
        'sleep_end_utc': sleepEndUtc,
        'tst_seconds': tstSeconds,
        'waso_seconds': wasoSeconds,
        'sleep_efficiency': sleepEfficiency,
        'hrv_rmssd_ms': hrvRmssdMs,
        'hrv_rolling_median_ms': hrvRollingMedianMs,
        'rhr_bpm': rhrBpm,
        'respiration_rate': respirationRate,
        'respiration_snr': respirationSnr,
        'usable_epochs_count': usableEpochsCount,
        'total_epochs_count': totalEpochsCount,
        'coverage_percent': coveragePercent,
        'gaps_count': gapsCount,
        'max_gap_seconds': maxGapSeconds,
        'quality_flags': qualityFlags,
        'classification_label': classificationLabel,
        'analysis_json': analysisJson,
        'error_message': errorMessage,
        'created_at_utc': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

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
