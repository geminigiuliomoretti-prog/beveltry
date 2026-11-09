import 'package:beveltry/src/records/v18_record.dart';
import 'package:beveltry/src/repository/whoop_repository.dart';
import 'package:beveltry/src/services/metrics_service.dart';
import 'package:beveltry/src/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('MetricsService & Integration Tests', () {
    late WhoopRepository repository;
    late MetricsService metricsService;
    late SyncService syncService;

    setUp(() {
      repository = WhoopRepository.inMemory();
      metricsService = MetricsService(repository: repository);
      syncService = SyncService(repository: repository);
    });

    tearDown(() async {
      await repository.close();
    });

    test('MetricsService con database vuoto restituisce metriche nulle e recordCount 0', () async {
      final metrics = await metricsService.calculateMetricsForLastNight();
      expect(metrics.rhr, isNull);
      expect(metrics.hrvRmssd, isNull);
      expect(metrics.recordCount, equals(0));
      expect(metrics.hasValidMetrics, isFalse);
    });

    test('DailyMetrics valida isHrvValid solo con HRV > 0 e recordCount >= 10', () {
      final now = DateTime.utc(2026, 11, 7, 8, 0, 0);
      final zeroHrv = DailyMetrics(rhr: 68, hrvRmssd: 0.0, recordCount: 30, calculatedAt: now);
      expect(zeroHrv.isHrvValid, isFalse);

      final fewRecords = DailyMetrics(rhr: 68, hrvRmssd: 45.0, recordCount: 5, calculatedAt: now);
      expect(fewRecords.isHrvValid, isFalse);

      final nullHrv = DailyMetrics(rhr: 68, hrvRmssd: null, recordCount: 30, calculatedAt: now);
      expect(nullHrv.isHrvValid, isFalse);

      final validHrv = DailyMetrics(rhr: 68, hrvRmssd: 45.0, recordCount: 30, calculatedAt: now);
      expect(validHrv.isHrvValid, isTrue);
    });

    test('MetricsService calcola RHR ed HRV corretti per una notte di dati sintetici', () async {
      final now = DateTime.utc(2026, 11, 7, 8, 0, 0);
      final records = <V18Record>[];

      // 360 record a 1Hz (6 minuti totali)
      // I primi 300 secondi (5 minuti) hanno HR 50 bpm e alternanza RR [800, 900, 800, 900] (RMSSD = 100.0)
      for (var i = 0; i < 360; i++) {
        final isFiveMinWindow = i < 300;
        final hr = isFiveMinWindow ? 50 : 70;
        final rr = i % 2 == 0 ? 800 : 900;

        records.add(
          V18Record(
            seq: i + 1,
            timestamp: now.subtract(Duration(minutes: 6)).add(Duration(seconds: i)),
            hrPrimary: hr,
            hrSecondary: hr,
            rrCount: 1,
            rrIntervalsMs: [rr],
            gravityX: 0.0,
            gravityY: 0.0,
            gravityZ: 1.0,
            accelMagG: 1.0,
            stepCounter: 0,
            skinTempRaw: 320,
            skinTempCelsius: 32.0,
            activityFlag: 0,
            spo2Candidate: 0,
            sleepState: isFiveMinWindow ? 2 : 1, // 2 = deep sleep
            opticalBaselineCh1: 35000,
            opticalBaselineCh2: 35000,
            opticalBaseline: 35000,
            isOnWrist: true,
          ),
        );
      }

      await repository.saveV18RecordsBatch(records, '5AG0558675');

      final metrics = await metricsService.calculateMetricsForLastNight(
        referenceTime: now,
      );

      expect(metrics.recordCount, equals(360));
      expect(metrics.rhr, equals(50));
      expect(metrics.hrvRmssd, isNotNull);
      expect(metrics.hrvRmssd, closeTo(100.0, 0.1));
      expect(metrics.hasValidMetrics, isTrue);
    });

    test('MetricsService calcola metriche anche su record disallineati nel tempo (Fix database vuoto)', () async {
      // Record registrati 30 giorni fa (o con orologio del cinturino non sincronizzato con il telefono)
      final pastDate = DateTime.utc(2025, 5, 1, 0, 0, 0);
      final records = <V18Record>[];

      for (var i = 0; i < 350; i++) {
        records.add(
          V18Record(
            seq: 1000 + i,
            timestamp: pastDate.add(Duration(seconds: i)),
            hrPrimary: 55,
            hrSecondary: 55,
            rrCount: 1,
            rrIntervalsMs: [i % 2 == 0 ? 820 : 880],
            gravityX: 0.0,
            gravityY: 0.0,
            gravityZ: 1.0,
            accelMagG: 1.0,
            stepCounter: 0,
            skinTempRaw: 320,
            skinTempCelsius: 32.0,
            activityFlag: 0,
            spo2Candidate: 0,
            sleepState: 2,
            opticalBaselineCh1: 35000,
            opticalBaselineCh2: 35000,
            opticalBaseline: 35000,
            isOnWrist: true,
          ),
        );
      }

      await repository.saveV18RecordsBatch(records, '5AG0558675');

      // Calcola senza referenceTime (default usa DateTime.now()): NON deve restituire database vuoto!
      final metrics = await metricsService.calculateMetricsForLastNight();
      expect(metrics.recordCount, equals(350));
      expect(metrics.rhr, equals(55));
      expect(metrics.hrvRmssd, isNotNull);
      expect(metrics.hasValidMetrics, isTrue);
    });

    test('SyncService scarica e persiste i record notificando lo stato', () async {
      expect(syncService.statusNotifier.value, equals(SyncStatus.idle));

      final savedCount = await syncService.startSync(simulationRecordCount: 30);
      expect(savedCount, equals(30));
      expect(syncService.statusNotifier.value, equals(SyncStatus.completed));
      expect(syncService.recordsSavedNotifier.value, equals(30));

      final storedInDb = await repository.countV18Records(strapSerial: '5AG0558675');
      expect(storedInDb, equals(30));

      // Se lanciato di nuovo mentre è completato, deduplica ed evita errori
      final countAgain = await syncService.startSync(simulationRecordCount: 30);
      expect(countAgain, equals(30));
      // Nel DB rimangono 30 per via del vincolo UNIQUE (strap_serial, seq)!
      final storedAfterDuplicate = await repository.countV18Records(strapSerial: '5AG0558675');
      expect(storedAfterDuplicate, equals(30));
    });
  });
}
