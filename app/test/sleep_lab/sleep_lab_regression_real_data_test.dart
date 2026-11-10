import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:beveltry/src/database/whoop_database.dart';
import 'package:beveltry/src/repository/whoop_repository.dart';
import 'package:beveltry/src/sleep_lab/cardiac_sleep_wake_estimator.dart';
import 'package:beveltry/src/sleep_lab/sleep_lab_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('SleepLab Real Dataset Regression Tests (night_1794264340726)', () {
    test('Esegue regressione deterministica sul database reale della notte 9-10 Nov 2026', () async {
      final realDbFile = File('../exports/whoop_local.db');
      final altDbFile = File('exports/whoop_local.db');

      final dbPath = realDbFile.existsSync()
          ? realDbFile.absolute.path
          : (altDbFile.existsSync() ? altDbFile.absolute.path : null);

      if (dbPath == null) {
        // Se il database reale non è presente nell'ambiente di test, salta con successo
        return;
      }

      final database = WhoopDatabase(customPath: dbPath);
      final repository = WhoopRepository(database: database);
      final service = SleepLabService(repository: repository);

      try {
        const sessionId = 'night_1794264340726';
        final analysis = await service.analyzeSession(sessionId);

        // 1. Sessione e conteggi
        expect(analysis.sessionSummary.sessionId, equals(sessionId));
        expect(analysis.sessionSummary.totalSamples, equals(32701));
        expect(analysis.sessionSummary.totalRr, equals(27424));

        // 2. Epoche da 30s
        expect(analysis.epochs.length, equals(1091));
        expect(analysis.quality.usableEpochsCount, equals(1090));
        expect(analysis.quality.epochUsabilityPercent, greaterThan(99.8));
        expect(analysis.quality.maxGapSeconds, lessThan(3.0));

        // 3. Stima Sleep/Wake cardiac-only
        expect(analysis.sleepWake.provenance, equals(MetricProvenanceStatus.experimentalCardiacOnly));
        expect(analysis.sleepWake.baselineHrBpm, closeTo(52.6, 1.0));
        expect(analysis.sleepWake.effectiveOnsetUtc, isNotNull);
        expect(analysis.sleepWake.effectiveEndUtc, isNotNull);

        // L'inizio del sonno NON è l'inizio della registrazione (22:45 UTC), ma dopo le 00:30 UTC
        final onsetHour = analysis.sleepWake.effectiveOnsetUtc!.hour;
        expect(onsetHour >= 0 && onsetHour <= 2, isTrue);

        // 4. HRV Window Lab
        expect(analysis.hrvLab.wholeSleepRmssd.isAvailable, isTrue);
        expect(analysis.hrvLab.wholeSleepRmssd.valueDirectMs, isNotNull);
        expect(analysis.hrvLab.wholeSleepRmssd.valueDirectMs!, inInclusiveRange(70.0, 110.0));

        // Candidati Deep SWS sono UNAVAILABLE
        expect(analysis.hrvLab.rmssdLast5MinDeep.status, equals(MetricProvenanceStatus.unavailable));
        expect(analysis.hrvLab.rmssdAllDeep.status, equals(MetricProvenanceStatus.unavailable));

        // 5. RHR
        expect(analysis.rhr.min5MinStatus, equals(MetricProvenanceStatus.measured));
        expect(analysis.rhr.min5MinBpm, isNotNull);
        expect(analysis.rhr.min5MinBpm!, greaterThanOrEqualTo(40));
        expect(analysis.rhr.min5MinBpm!, lessThanOrEqualTo(55));

        // 6. Frequenza Respiratoria RSA
        expect(analysis.respiration.status, equals(MetricProvenanceStatus.experimental));
        expect(analysis.respiration.medianBreathsPerMinute, isNotNull);
        // Fisiologico umano a riposo: 12-16 RPM
        expect(analysis.respiration.medianBreathsPerMinute!, greaterThanOrEqualTo(12.0));
        expect(analysis.respiration.medianBreathsPerMinute!, lessThanOrEqualTo(16.0));
        expect(analysis.respiration.validWindowsCount, greaterThan(100));
      } finally {
        await database.close();
      }
    });
  });
}
