import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:beveltry/screens/night_recorder_screen.dart';
import 'package:beveltry/src/ble/ble.dart';
import 'package:beveltry/src/repository/whoop_repository.dart';
import 'package:beveltry/src/services/sync_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('Night Recorder Repository & Summary Tests', () {
    late WhoopRepository repository;

    setUp(() {
      repository = WhoopRepository.inMemory();
    });

    tearDown(() async {
      await repository.close();
    });

    test('startNightSession and saveNightSample persist progressively', () async {
      const sessId = 'night_test_20261109';
      final now = DateTime.utc(2026, 11, 9, 22, 30, 0);

      await repository.startNightSession(
        sessionId: sessId,
        deviceAddress: 'FD:49:44:66:1D:92',
        deviceName: 'WBB5AP-5AG0558675',
        startTime: now,
      );

      // Inserimento campioni con intervalli RR
      final hrSamples = [60, 62, 65, 58, 60, 64, 70];
      final rrSamples = [1000, 968, 923, 1034, 1000, 938, 857];

      for (var i = 0; i < hrSamples.length; i++) {
        await repository.saveNightSample(
          sessionId: sessId,
          timestamp: now.add(Duration(seconds: i)),
          monotonicMillis: 10000 + i * 1000,
          hrBpm: hrSamples[i],
          flags: 0x16,
          sensorContact: 1,
          rrStatus: 'AVAILABLE',
          rawRrIntervals: [rrSamples[i]],
        );
      }

      await repository.logNightEvent(
        sessionId: sessId,
        timestamp: now.add(const Duration(seconds: 10)),
        monotonicMillis: 20000,
        eventType: 'DISCONNECTED',
        details: 'Link loss',
      );

      await repository.logNightEvent(
        sessionId: sessId,
        timestamp: now.add(const Duration(seconds: 15)),
        monotonicMillis: 25000,
        eventType: 'CONNECTED',
        details: 'Reconnected',
      );

      await repository.endNightSession(
        sessionId: sessId,
        endTime: now.add(const Duration(seconds: 20)),
      );

      final summary = await repository.getNightSessionSummary(sessId);

      expect(summary.sessionId, equals(sessId));
      expect(summary.totalSamples, equals(7));
      expect(summary.totalRr, equals(7));
      expect(summary.disconnectionsCount, equals(1));
      expect(summary.disconnectionDurationSeconds, equals(5));
      expect(summary.minHr, equals(58));
      expect(summary.maxHr, equals(70));
      expect(summary.meanHr, closeTo(62.7, 0.2));
      expect(summary.rmssdMs, isNotNull);
      expect(summary.rmssdMs!, greaterThan(0));
      expect(summary.estimatedRhr, isNotNull);
      expect(summary.missingMetrics.containsKey('SpO2 (Saturazione Ossigeno)'), isTrue);
      expect(summary.missingMetrics.containsKey('WHOOP Recovery Score'), isTrue);

      final markdown = summary.toMarkdownReport();
      expect(markdown, contains('RAPPORTO SESSIONE NOTTURNA'));
      expect(markdown, contains('WBB5AP-5AG0558675'));
      expect(markdown, contains('70 BPM'));
      expect(markdown, contains('MISSING'));
    });

    test('deduplication ignores identical sample re-deliveries', () async {
      const sessId = 'night_dedup_test';
      final now = DateTime.utc(2026, 11, 9, 23, 0, 0);

      await repository.startNightSession(
        sessionId: sessId,
        deviceAddress: 'FD:49:44:66:1D:92',
      );

      // Inserisci lo stesso identico campione 3 volte
      for (var i = 0; i < 3; i++) {
        await repository.saveNightSample(
          sessionId: sessId,
          timestamp: now,
          monotonicMillis: 50000,
          hrBpm: 77,
          flags: 0x16,
          sensorContact: 1,
          rrStatus: 'AVAILABLE',
          rawRrIntervals: [779],
        );
      }

      final summary = await repository.getNightSessionSummary(sessId);
      // Il vincolo UNIQUE su (session_id, timestamp_utc, hr_bpm, monotonic_millis) impedisce duplicati
      expect(summary.totalSamples, equals(1));
    });

    test('exportNightDataToCsv produces valid CSV with timestamp, hr, rr_raw and no BT identifiers', () async {
      const sessId = 'night_export_test';
      final now = DateTime.utc(2026, 11, 9, 23, 0, 0);

      await repository.startNightSession(
        sessionId: sessId,
        deviceAddress: 'FD:49:44:66:1D:92',
        deviceName: 'WBB5AP-5AG0558675',
        startTime: now,
      );

      await repository.saveNightSample(
        sessionId: sessId,
        timestamp: now,
        monotonicMillis: 1000,
        hrBpm: 60,
        flags: 0x16,
        sensorContact: 1,
        rrStatus: 'AVAILABLE',
        rawRrIntervals: [950, 955],
      );

      await repository.saveNightSample(
        sessionId: sessId,
        timestamp: now.add(const Duration(seconds: 1)),
        monotonicMillis: 2000,
        hrBpm: 61,
        flags: 0x06,
        sensorContact: 1,
        rrStatus: 'RR_UNAVAILABLE',
        rawRrIntervals: [],
      );

      final file = await repository.exportNightDataToCsv(sessionId: sessId);
      expect(await file.exists(), isTrue);

      final content = await file.readAsString();
      final lines = content.trim().split('\n');

      expect(lines.first.trim(), equals('timestamp,hr,rr_raw'));
      expect(lines.length, equals(4)); // header + 2 RR rows for sample 1 + 1 row for sample 2
      expect(lines[1].trim(), equals('${now.toIso8601String()},60,950'));
      expect(lines[2].trim(), equals('${now.toIso8601String()},60,955'));
      expect(lines[3].trim(), equals('${now.add(const Duration(seconds: 1)).toIso8601String()},61,'));

      // Verifica assoluta: nessun identificativo Bluetooth presente nel file CSV
      expect(content.contains('FD:49:44:66:1D:92'), isFalse);
      expect(content.contains('WBB5AP'), isFalse);
      expect(content.contains('5AG0558675'), isFalse);

      // Verifica integrità: i dati originali non sono stati modificati o cancellati
      final summary = await repository.getNightSessionSummary(sessId);
      expect(summary.totalSamples, equals(2));
      expect(summary.totalRr, equals(2));

      await file.delete();
    });
  });

  group('NightRecorderScreen Widget Tests', () {
    late WhoopRepository repository;
    late SyncService syncService;

    setUp(() {
      repository = WhoopRepository.inMemory();
      syncService = SyncService(
        repository: repository,
        simulateIfNoHardware: false,
        initialConnectionState: const BleStatusStandardHrConnected(
          WhoopDiscoveredDevice(name: 'WBB5AP-5AG0558675', macAddress: 'FD:49:44:66:1D:92'),
        ),
      );
    });

    tearDown(() async {
      await repository.close();
    });

    testWidgets('NightRecorderScreen renders initial state and handles recording lifecycle', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      syncService.connectionStateNotifier.value = const BleStatusStandardHrConnected(
        WhoopDiscoveredDevice(name: 'WBB5AP-5AG0558675', macAddress: 'FD:49:44:66:1D:92'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: NightRecorderScreen(
            repository: repository,
            syncService: syncService,
          ),
        ),
      );

      expect(find.text('Night Recorder'), findsOneWidget);
      expect(find.text('AVVIA REGISTRAZIONE NOTTURNA'), findsOneWidget);
      expect(find.textContaining('Istruzioni per la Notte'), findsOneWidget);
      expect(find.text('Esporta dati notturni'), findsOneWidget);

      // Assicura lo stato connesso per abilitare il pulsante
      syncService.connectionStateNotifier.value = const BleStatusStandardHrConnected(
        WhoopDiscoveredDevice(name: 'WBB5AP-5AG0558675', macAddress: 'FD:49:44:66:1D:92'),
      );
      await tester.pump();

      // Avvia la registrazione
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(ElevatedButton, 'AVVIA REGISTRAZIONE NOTTURNA'));
        await Future.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();

      expect(find.text('STATO: RECORDING'), findsOneWidget);
      expect(find.text('TERMINA E ANALIZZA'), findsOneWidget);
      expect(find.textContaining('Dati salvati progressivamente su SQLite'), findsOneWidget);

      // Simula notifica battito 0x2A37
      syncService.liveHrNotifier.value = 77;
      await tester.pump();

      expect(find.text('77 BPM'), findsOneWidget);

      // Termina e analizza
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(ElevatedButton, 'TERMINA E ANALIZZA'));
        await Future.delayed(const Duration(milliseconds: 250));
      });
      await tester.pump();

      expect(find.text('Rapporto del Mattino'), findsOneWidget);
      expect(find.text('Copia Markdown'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Esporta dati notturni'), findsOneWidget);

      // Tocca Esporta dati notturni dal dialog del mattino
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(TextButton, 'Esporta dati notturni'));
        await Future.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(find.text('Dati notturni esportati'), findsOneWidget);
      expect(find.text('Copia CSV negli appunti'), findsOneWidget);
    });
  });
}
