import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:beveltry/screens/sleep_lab_screen.dart';
import 'package:beveltry/src/database/whoop_database.dart';
import 'package:beveltry/src/repository/whoop_repository.dart';
import 'package:beveltry/src/sleep_lab/sleep_lab_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late WhoopDatabase database;
  late WhoopRepository repository;

  setUp(() async {
    database = WhoopDatabase.inMemory();
    repository = WhoopRepository(database: database);
  });

  tearDown(() async {
    await database.close();
  });

  group('SleepLabScreen Widget Tests', () {
    testWidgets('Rendering stato vuoto quando non ci sono sessioni registrate', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SleepLabScreen(repository: repository),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Beveltry Sleep Lab'), findsOneWidget);
      expect(find.text('Nessuna sessione notturna registrata.'), findsOneWidget);
    });

    testWidgets('Rendering completo Sleep Lab con sessione notturna attiva', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const sessionId = 'night_widget_test';
      final start = DateTime.utc(2026, 11, 10, 0, 0, 0);
      final end = start.add(const Duration(minutes: 10));

      await repository.startNightSession(
        sessionId: sessionId,
        deviceAddress: 'FD:49:44:66:1D:92',
        deviceName: 'WHOOP 5WP',
        startTime: start,
      );

      for (var i = 0; i < 60; i++) {
        final t = start.add(Duration(seconds: i * 10));
        await repository.saveNightSample(
          sessionId: sessionId,
          timestamp: t,
          monotonicMillis: i * 10000,
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

      final analysis = await SleepLabService(repository: repository).analyzeSession(sessionId);

      await tester.pumpWidget(
        MaterialApp(
          home: SleepLabScreen(
            repository: repository,
            initialSessionId: sessionId,
            initialAnalysis: analysis,
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Beveltry Sleep Lab'), findsOneWidget);
      expect(find.text('Sonno & Confini'), findsOneWidget);
      expect(find.text('HRV Window Lab'), findsOneWidget);
      expect(find.text('RHR & Frequenza Respiratoria'), findsOneWidget);
      expect(find.text('Stadiazione Fasi del Sonno'), findsOneWidget);
      expect(find.text('Confronto WHOOP A'), findsOneWidget);

      // Verifica presenza badge espliciti
      expect(find.text('MEASURED'), findsWidgets);
      expect(find.text('UNAVAILABLE'), findsWidgets);
    });
  });
}
