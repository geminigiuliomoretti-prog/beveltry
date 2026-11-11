import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:beveltry/screens/always_on_screen.dart';
import 'package:beveltry/src/repository/whoop_repository.dart';
import 'package:beveltry/src/services/sync_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('Always-On Repository & SQLite Integration Tests', () {
    late WhoopRepository repository;

    setUp(() {
      repository = WhoopRepository.inMemory();
    });

    tearDown(() async {
      await repository.close();
    });

    test('Always-On settings persist and retrieve correctly', () async {
      // Default deve essere false
      final initial = await repository.isAlwaysOnEnabled();
      expect(initial, isFalse);

      // Abilitazione Always-On
      await repository.setAlwaysOnEnabled(true);
      final enabled = await repository.isAlwaysOnEnabled();
      expect(enabled, isTrue);

      // Impostazioni custom
      await repository.setSetting('target_mac', 'FD:49:44:66:1D:92');
      final mac = await repository.getSetting('target_mac');
      expect(mac, equals('FD:49:44:66:1D:92'));

      // Disabilitazione
      await repository.setAlwaysOnEnabled(false);
      final disabled = await repository.isAlwaysOnEnabled();
      expect(disabled, isFalse);
    });

    test('connection_events logs events and retrieves recent history', () async {
      final now = DateTime.utc(2026, 11, 11, 2, 0, 0);

      final id1 = await repository.logConnectionEvent(
        eventType: 'CONNECTING',
        details: 'Attempting GATT connect',
        timestamp: now,
      );
      expect(id1, greaterThan(0));

      final id2 = await repository.logConnectionEvent(
        eventType: 'GATT_DISCONNECTED',
        reasonCode: 19,
        details: 'Link loss status 19',
        timestamp: now.add(const Duration(minutes: 5)),
      );
      expect(id2, greaterThan(id1));

      final events = await repository.getRecentConnectionEvents(limit: 10);
      expect(events.length, equals(2));
      expect(events.first['event_type'], equals('GATT_DISCONNECTED'));
      expect(events.first['reason_code'], equals(19));

      final lastDisc = await repository.getLastDisconnectEvent();
      expect(lastDisc, isNotNull);
      expect(lastDisc!['reason_code'], equals(19));
      expect(lastDisc['details'], contains('Link loss'));
    });

    test('recording_segments tracks session segments, gaps and metrics', () async {
      const sessId = 'night_auto_20261111';
      const segId = 'seg_auto_001';
      final start = DateTime.utc(2026, 11, 11, 23, 0, 0);

      await repository.startRecordingSegment(
        segmentId: segId,
        sessionId: sessId,
        startedAt: start,
        startReason: 'ALWAYS_ON_INIT',
      );

      // Aggiornamento progressivo durante streaming
      await repository.updateRecordingSegmentMetrics(
        segmentId: segId,
        hrCount: 120,
        rrCount: 115,
        maxGapMs: 1500,
      );

      // Chiusura segmento
      final end = start.add(const Duration(minutes: 30));
      await repository.endRecordingSegment(
        segmentId: segId,
        endedAt: end,
        endReason: 'DISCONNECTED',
        hrCount: 1800,
        rrCount: 1750,
        maxGapMs: 2500,
      );

      final segments = await repository.getRecordingSegments(sessId);
      expect(segments.length, equals(1));
      final s = segments.first;
      expect(s['id'], equals(segId));
      expect(s['start_reason'], equals('ALWAYS_ON_INIT'));
      expect(s['end_reason'], equals('DISCONNECTED'));
      expect(s['hr_count'], equals(1800));
      expect(s['rr_count'], equals(1750));
      expect(s['max_gap_ms'], equals(2500));
    });
  });

  group('AlwaysOnScreen Widget Tests', () {
    late WhoopRepository repository;
    late SyncService syncService;

    setUp(() {
      repository = WhoopRepository.inMemory();
      syncService = SyncService(repository: repository);
    });

    tearDown(() async {
      await repository.close();
    });

    testWidgets('AlwaysOnScreen renders settings and diagnostics tabs', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: AlwaysOnScreen(
            repository: repository,
            syncService: syncService,
            enablePeriodicRefresh: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verifica titoli e controlli principali
      expect(find.text('Registrazione automatica'), findsOneWidget);
      expect(find.text('Registrazione automatica WHOOP'), findsOneWidget);
      expect(find.byKey(const Key('always_on_switch')), findsOneWidget);
      expect(find.textContaining('WHOOP B'), findsOneWidget);
      expect(find.text('Stato Sistema (Osservabilità Reale)'), findsOneWidget);
      expect(find.text('Servizio Background (FGS):'), findsOneWidget);
      expect(find.text('Connessione GATT BLE:'), findsOneWidget);

      // Toggle switch Always-On
      await tester.tap(find.byKey(const Key('always_on_switch')));
      await tester.pumpAndSettle();

      final isEnabled = await repository.isAlwaysOnEnabled();
      expect(isEnabled, isTrue);

      // Passaggio alla scheda Diagnostica
      await tester.tap(find.text('Diagnostica'));
      await tester.pumpAndSettle();

      expect(find.text('Parametri Diagnostici Task 08C'), findsOneWidget);
      expect(find.text('Istruzioni per Smartphone Samsung Galaxy'), findsOneWidget);
      expect(find.textContaining('Applicazioni mai in sospensione'), findsOneWidget);
      expect(find.text('Eventi di Connessione Recenti (SQLite)'), findsOneWidget);
    });

    testWidgets('AlwaysOnScreen renders 6-layer status and handles reconnect diagnostics (Task 08C.2)', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // Inserisce eventi di test per Bluetooth OFF/ON e Stale
      await repository.logConnectionEvent(
        eventType: 'BLUETOOTH_OFF',
        details: 'Adattatore Bluetooth disattivato',
      );
      await repository.logConnectionEvent(
        eventType: 'STREAM_STALE',
        reasonCode: 7000,
        details: 'Flusso interrotto: nessun battito da 7000ms',
      );
      await repository.logConnectionEvent(
        eventType: 'BLUETOOTH_ON',
        details: 'Adattatore Bluetooth riattivato',
      );
      await repository.logConnectionEvent(
        eventType: 'RECONNECT_SCHEDULED',
        reasonCode: 1,
        details: 'Riconnessione programmata',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AlwaysOnScreen(
            repository: repository,
            syncService: syncService,
            enablePeriodicRefresh: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verifica presenza dei 6 livelli di osservabilità reale
      expect(find.text('Servizio Background (FGS):'), findsOneWidget);
      expect(find.text('Adattatore Bluetooth:'), findsOneWidget);
      expect(find.text('Connessione GATT BLE:'), findsOneWidget);
      expect(find.text('2. Sottoscrizione 0x2A37 (SUBSCRIBED):'), findsOneWidget);
      expect(find.text('3. Flusso Notifiche (STREAMING):'), findsOneWidget);
      expect(find.text('4. Persistenza SQLite (PERSISTING):'), findsOneWidget);

      // Passa a Diagnostica e verifica gli eventi del ciclo di vita
      await tester.tap(find.text('Diagnostica'));
      await tester.pumpAndSettle();

      expect(find.text('Sequenza Eventi Tecnici BLE (Lifecycle)'), findsOneWidget);
      expect(find.text('BLUETOOTH_OFF'), findsWidgets);
      expect(find.text('STREAM_STALE'), findsWidgets);
      expect(find.text('BLUETOOTH_ON'), findsWidgets);
      expect(find.text('RECONNECT_SCHEDULED'), findsWidgets);
    });
  });
}
