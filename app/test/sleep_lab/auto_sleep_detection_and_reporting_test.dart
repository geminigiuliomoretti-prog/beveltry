import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:beveltry/screens/dashboard_screen.dart';
import 'package:beveltry/screens/sleep_lab_screen.dart';
import 'package:beveltry/src/database/whoop_database.dart';
import 'package:beveltry/src/repository/whoop_repository.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('Task 08D - Auto Sleep Detection & Morning Report Persistence Tests', () {
    late WhoopDatabase whoopDb;
    late WhoopRepository repository;

    setUp(() async {
      whoopDb = WhoopDatabase.inMemory();
      await whoopDb.database;
      repository = WhoopRepository(database: whoopDb);
    });

    tearDown(() async {
      await repository.close();
    });

    test('night_processing and sleep_lab_analyses tables can be written and read atomically', () async {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      const nightKey = 'night_20261111';
      const sessionId = 'night_20261111';

      // 1. Salva stato processing
      await repository.saveNightProcessingState(
        nightKey: nightKey,
        sessionId: sessionId,
        state: 'REPORT_READY',
        candidateOnset: now - 28800000,
        candidateOffset: now,
        lastProcessedAt: now,
        decisionReason: 'Risveglio finale confermato e worker completato',
      );

      final proc = await repository.getLatestNightProcessing();
      expect(proc, isNotNull);
      expect(proc!['night_key'], equals(nightKey));
      expect(proc['state'], equals('REPORT_READY'));
      expect(proc['decision_reason'], contains('Risveglio finale confermato'));

      // 2. Salva analisi atomica revisione 1
      await repository.saveSleepLabAnalysisRecord(
        nightKey: nightKey,
        sessionId: sessionId,
        revision: 1,
        state: 'REPORT_READY',
        sleepOnsetUtc: now - 28000000,
        sleepEndUtc: now - 600000,
        tstSeconds: 24300, // 6h 45m
        wasoSeconds: 2100, // 35m
        sleepEfficiency: 92.0,
        hrvRmssdMs: 64.2,
        hrvRollingMedianMs: 63.8,
        rhrBpm: 48,
        respirationRate: 14.2,
        respirationSnr: 2.5,
        usableEpochsCount: 900,
        totalEpochsCount: 920,
        coveragePercent: 99.8,
        gapsCount: 0,
        maxGapSeconds: 0.0,
        classificationLabel: 'EXPERIMENTAL_CARDIAC_ONLY',
      );

      final analysis = await repository.getLatestSleepLabAnalysis();
      expect(analysis, isNotNull);
      expect(analysis!['night_key'], equals(nightKey));
      expect(analysis['revision'], equals(1));
      expect(analysis['tst_seconds'], equals(24300));
      expect(analysis['waso_seconds'], equals(2100));
      expect(analysis['hrv_rmssd_ms'], equals(64.2));
      expect(analysis['rhr_bpm'], equals(48));
      expect(analysis['respiration_rate'], equals(14.2));
      expect(analysis['classification_label'], equals('EXPERIMENTAL_CARDIAC_ONLY'));
    });

    test('insufficient data marks state PROCESS_FAILED with INSUFFICIENT_DATA', () async {
      const nightKey = 'night_failed_test';
      const sessionId = 'night_failed_test';

      await repository.saveNightProcessingState(
        nightKey: nightKey,
        sessionId: sessionId,
        state: 'PROCESS_FAILED',
        errorCode: 'INSUFFICIENT_DATA',
        decisionReason: 'Dati insufficienti (< 30 min registrati)',
      );

      final proc = await repository.getLatestNightProcessing();
      expect(proc, isNotNull);
      expect(proc!['state'], equals('PROCESS_FAILED'));
      expect(proc['error_code'], equals('INSUFFICIENT_DATA'));
    });
  });

  group('Task 08D - Dashboard and Sleep Lab UI Widget Tests', () {
    late WhoopDatabase whoopDb;
    late WhoopRepository repository;

    setUp(() async {
      whoopDb = WhoopDatabase.inMemory();
      await whoopDb.database;
      repository = WhoopRepository(database: whoopDb);
    });

    tearDown(() async {
      await repository.close();
    });

    testWidgets('Dashboard renders Auto Night card with REPORT_READY and opens Sleep Lab', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      const nightKey = 'night_20261111';
      const sessionId = 'night_20261111';

      await repository.saveNightProcessingState(
        nightKey: nightKey,
        sessionId: sessionId,
        state: 'REPORT_READY',
      );

      await repository.saveSleepLabAnalysisRecord(
        nightKey: nightKey,
        sessionId: sessionId,
        revision: 1,
        state: 'REPORT_READY',
        sleepOnsetUtc: now - 28000000,
        sleepEndUtc: now - 600000,
        tstSeconds: 24300, // 6h 45m
        wasoSeconds: 2100, // 35m
        sleepEfficiency: 92.0,
        hrvRmssdMs: 64.2,
        rhrBpm: 48,
        respirationRate: 14.2,
        usableEpochsCount: 900,
        totalEpochsCount: 920,
        coveragePercent: 99.8,
        gapsCount: 0,
        maxGapSeconds: 0.0,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DashboardScreen(repository: repository),
        ),
      );
      await tester.pumpAndSettle();

      // Verifica card notte
      expect(find.text('ULTIMA NOTTE RILEVATA (Auto Sleep TASK 08D)'), findsOneWidget);
      expect(find.text('REPORT PRONTO'), findsOneWidget);
      expect(find.text('Sperimentale (Cardiac-only)'), findsOneWidget);
      expect(find.text('6h 45m'), findsOneWidget); // TST
      expect(find.text('35m'), findsOneWidget); // WASO
      expect(find.text('64.2 ms'), findsOneWidget); // HRV
      expect(find.text('48 bpm'), findsOneWidget); // RHR
      expect(find.text('14.2 RPM'), findsOneWidget); // RSA Respiration
      expect(find.text('99.8%'), findsOneWidget); // Coverage
      expect(find.text('0 gap'), findsOneWidget); // Gaps

      // Clic su apri Sleep Lab
      await tester.tap(find.byKey(const Key('sleep_lab_entry_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(SleepLabScreen), findsOneWidget);
      expect(find.text('Beveltry Sleep Lab'), findsOneWidget);
    });

    testWidgets('Dashboard renders Dati insufficienti when state is PROCESS_FAILED', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const nightKey = 'night_failed_short';

      await repository.saveNightProcessingState(
        nightKey: nightKey,
        sessionId: nightKey,
        state: 'PROCESS_FAILED',
        errorCode: 'INSUFFICIENT_DATA',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DashboardScreen(repository: repository),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('ULTIMA NOTTE RILEVATA (Auto Sleep TASK 08D)'), findsOneWidget);
      expect(find.text('DATI INSUFFICIENTI'), findsOneWidget);
      expect(find.text('Dati insufficienti (< 30 min registrati)'), findsOneWidget);
    });
  });
}
