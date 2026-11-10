import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:beveltry/src/database/whoop_database.dart';
import 'package:beveltry/src/repository/whoop_repository.dart';
import 'package:beveltry/src/sleep_lab/cardiac_sleep_wake_estimator.dart';
import 'package:beveltry/src/sleep_lab/sleep_lab_service.dart';
import 'package:beveltry/src/sleep_lab/whoop_a_comparison.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late WhoopDatabase database;
  late WhoopRepository repository;
  late SleepLabService sleepLabService;

  setUp(() async {
    database = WhoopDatabase.inMemory();
    repository = WhoopRepository(database: database);
    sleepLabService = SleepLabService(repository: repository);
  });

  tearDown(() async {
    await database.close();
  });

  group('SleepLabService & SQLite Persistence Tests', () {
    test('Salvataggio e recupero confini manuali sonno', () async {
      final onset = DateTime.utc(2026, 11, 10, 1, 15, 0);
      final offset = DateTime.utc(2026, 11, 10, 7, 30, 0);

      await sleepLabService.saveManualBoundaries(
        sessionId: 'sess_test_1',
        manualOnsetUtc: onset,
        manualEndUtc: offset,
      );

      final boundaries = await repository.getManualSleepBoundaries('sess_test_1');
      expect(boundaries['manualOnset'], equals(onset));
      expect(boundaries['manualEnd'], equals(offset));
    });

    test('Salvataggio e recupero confronto WHOOP A', () async {
      final record = WhoopAComparisonRecord(
        sessionId: 'sess_test_2',
        createdAtUtc: DateTime.utc(2026, 11, 10, 8, 0, 0),
        algorithmVersion: '1.0.0',
        hrvRmssd: 55.2,
        rhrBpm: 49,
        respiratoryRate: 13.9,
      );

      await sleepLabService.saveWhoopAComparison(record);

      final loaded = await repository.getWhoopAComparisonForSession('sess_test_2');
      expect(loaded, isNotNull);
      expect(loaded!.sessionId, equals('sess_test_2'));
      expect(loaded.hrvRmssd, equals(55.2));
      expect(loaded.rhrBpm, equals(49));
      expect(loaded.respiratoryRate, equals(13.9));
    });

    test('Pipeline completa SleepLabService.analyzeSession su dati sintetici persistiti', () async {
      const sessionId = 'night_pipeline_test';
      final start = DateTime.utc(2026, 11, 10, 0, 0, 0);
      final end = start.add(const Duration(minutes: 10)); // 10 minuti = 20 epoche da 30s

      await repository.startNightSession(
        sessionId: sessionId,
        deviceAddress: 'FD:49:44:66:1D:92',
        deviceName: 'WHOOP 5WP',
        startTime: start,
      );

      // Inserisce 600 campioni (1 campione ogni secondo = 30 campioni per epoca)
      for (var i = 0; i < 600; i++) {
        final t = start.add(Duration(seconds: i));
        await repository.saveNightSample(
          sessionId: sessionId,
          timestamp: t,
          monotonicMillis: i * 1000,
          hrBpm: 55,
          flags: 16,
          sensorContact: -1,
          rrStatus: 'AVAILABLE',
          rawRrIntervals: [1000],
        );
      }

      await repository.endNightSession(
        sessionId: sessionId,
        status: 'COMPLETED',
        endTime: end,
      );

      // Esegue analisi Sleep Lab
      final analysis = await sleepLabService.analyzeSession(sessionId);

      expect(analysis.sessionSummary.sessionId, equals(sessionId));
      expect(analysis.epochs.length, equals(20));
      expect(analysis.sleepWake.provenance, equals(MetricProvenanceStatus.experimentalCardiacOnly));
      expect(analysis.hrvLab.wholeSleepRmssd.isAvailable, isTrue);
      expect(analysis.rhr.min5MinStatus, equals(MetricProvenanceStatus.measured));
      expect(analysis.quality.usableEpochsCount, equals(20));

      // Ripete l'analisi per test di determinismo
      final analysis2 = await sleepLabService.analyzeSession(sessionId);
      expect(analysis.epochs.length, equals(analysis2.epochs.length));
      expect(analysis.sleepWake.sleepEfficiencyPercent, equals(analysis2.sleepWake.sleepEfficiencyPercent));
      expect(analysis.hrvLab.wholeSleepRmssd.valueDirectMs, equals(analysis2.hrvLab.wholeSleepRmssd.valueDirectMs));
    });
  });
}
