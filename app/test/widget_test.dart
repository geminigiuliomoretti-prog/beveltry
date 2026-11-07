import 'package:beveltry/screens/dashboard_screen.dart';
import 'package:beveltry/src/ble/ble.dart';
import 'package:beveltry/src/repository/whoop_repository.dart';
import 'package:beveltry/src/services/metrics_service.dart';
import 'package:beveltry/src/services/sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Widget createTestWidget({
    required WhoopRepository repository,
    SyncService? syncService,
  }) {
    final service = syncService ??
        SyncService(
          repository: repository,
          simulateIfNoHardware: true,
        );
    final metricsService = MetricsService(repository: repository);

    return MaterialApp(
      home: DashboardScreen(
        repository: repository,
        syncService: service,
        metricsService: metricsService,
      ),
    );
  }

  testWidgets('Dashboard UI: mostra titolo, 1. Cerca WHOOP e pulsanti azione disabilitati all\'avvio', (tester) async {
    final repository = WhoopRepository.inMemory();

    await tester.pumpWidget(createTestWidget(repository: repository));
    await tester.pumpAndSettle();

    // 1. Titolo AppBar
    expect(find.text('Beveltry'), findsOneWidget);

    // 2. Card RHR e HRV
    expect(find.text('RHR'), findsOneWidget);
    expect(find.text('HRV (RMSSD)'), findsOneWidget);
    expect(find.text('Dati insufficienti'), findsNWidgets(2));

    // 3. Pulsante di scansione presente
    expect(find.text('1. Cerca WHOOP'), findsOneWidget);

    // 4. Pulsanti di azione presenti ma disabilitati se non connesso
    final syncFinder = find.byKey(const Key('sync_button'));
    final vibFinder = find.byKey(const Key('vibration_button'));
    final discFinder = find.byKey(const Key('disconnect_button'));

    expect(syncFinder, findsOneWidget);
    expect(vibFinder, findsOneWidget);
    expect(discFinder, findsOneWidget);

    final syncBtn = tester.widget<ElevatedButton>(syncFinder);
    final vibBtn = tester.widget<ElevatedButton>(vibFinder);
    final discBtn = tester.widget<OutlinedButton>(discFinder);

    expect(syncBtn.onPressed, isNull);
    expect(vibBtn.onPressed, isNull);
    expect(discBtn.onPressed, isNull);

    // 5. Sezione log
    expect(find.text('Log Operazioni'), findsOneWidget);
    expect(
      find.textContaining('Sistema inizializzato'),
      findsOneWidget,
    );

    await repository.close();
  });

  testWidgets('Dashboard UI: flusso completo Scan -> Select -> Connect/Bond -> Sync -> Calcola Metriche', (tester) async {
    final repository = WhoopRepository.inMemory();
    final transport = SimulatedPuffinTransport(
      isConnected: false,
      simulatedDevices: [
        const WhoopDiscoveredDevice(
          name: 'WBB5AP-5AG0558675',
          macAddress: 'FD:49:44:66:1D:92',
          rssi: -65,
        ),
      ],
    );
    final syncService = SyncService(
      repository: repository,
      transport: transport,
      simulateIfNoHardware: true,
    );

    await tester.pumpWidget(createTestWidget(
      repository: repository,
      syncService: syncService,
    ));
    await tester.pumpAndSettle();

    // 1. Click su "1. Cerca WHOOP"
    final scanButton = find.text('1. Cerca WHOOP');
    expect(scanButton, findsOneWidget);

    await tester.tap(scanButton);
    await tester.pumpAndSettle();

    // 2. Verifica comparsa ListView dei dispositivi trovati
    expect(find.text('WBB5AP-5AG0558675'), findsOneWidget);
    expect(find.textContaining('FD:49:44:66:1D:92'), findsOneWidget);

    // 3. Click sul dispositivo per avviare Connessione e Bonding
    final deviceTile = find.text('WBB5AP-5AG0558675');
    await tester.tap(deviceTile);
    await tester.pumpAndSettle();

    // 4. Verifica banner "Connesso a WBB5AP-5AG0558675"
    expect(find.text('Connesso a WBB5AP-5AG0558675'), findsOneWidget);

    // 5. Verifica che "2. Sincronizza" sia ora abilitato ed eseguibile
    final syncButton = find.byKey(const Key('sync_button'));
    expect(tester.widget<ElevatedButton>(syncButton).onPressed, isNotNull);

    await tester.tap(syncButton);
    await tester.pumpAndSettle();

    expect(find.textContaining('Sincronizzazione completata'), findsOneWidget);

    // 6. Click su "Calcola Metriche"
    final calcButton = find.text('Calcola Metriche');
    final state = tester.state<DashboardScreenState>(find.byType(DashboardScreen));
    await tester.tap(calcButton);
    await tester.pumpAndSettle();

    expect(find.textContaining('bpm'), findsAtLeastNWidgets(1));
    expect(state.latestMetrics, isNotNull);
    expect(find.textContaining('Calcolo completato'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await repository.close();
  });

  testWidgets('Dashboard UI: click su Test Vibrazione invia il comando 0x42 solo se connesso', (tester) async {
    final repository = WhoopRepository.inMemory();
    final transport = SimulatedPuffinTransport(
      isConnected: false,
      simulatedDevices: [
        const WhoopDiscoveredDevice(
          name: 'WBB5AP-5AG0558675',
          macAddress: 'FD:49:44:66:1D:92',
        ),
      ],
    );
    final syncService = SyncService(
      repository: repository,
      transport: transport,
      simulateIfNoHardware: true,
    );

    await tester.pumpWidget(createTestWidget(
      repository: repository,
      syncService: syncService,
    ));
    await tester.pumpAndSettle();

    // Connessione preliminare
    await tester.tap(find.text('1. Cerca WHOOP'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('WBB5AP-5AG0558675'));
    await tester.pumpAndSettle();

    // Ora il pulsante vibrazione è abilitato
    final vibButton = find.byKey(const Key('vibration_button'));
    expect(tester.widget<ElevatedButton>(vibButton).onPressed, isNotNull);

    await tester.tap(vibButton);
    await tester.pumpAndSettle();

    expect(find.textContaining('Vibrazione attivata con successo'), findsOneWidget);

    // Disconnetti e verifica che il pulsante torni disabilitato
    final discButton = find.byKey(const Key('disconnect_button'));
    await tester.tap(discButton);
    await tester.pumpAndSettle();

    expect(tester.widget<ElevatedButton>(find.byKey(const Key('vibration_button'))).onPressed, isNull);

    await tester.pumpWidget(const SizedBox());
    await repository.close();
  });

  testWidgets('Dashboard UI: bonding fallito o annullato mostra errore chiaro', (tester) async {
    final repository = WhoopRepository.inMemory();
    final transport = SimulatedPuffinTransport(
      isConnected: false,
      simulateBondFailure: true,
      simulatedDevices: [
        const WhoopDiscoveredDevice(
          name: 'WBB5AP-5AG0558675',
          macAddress: 'FD:49:44:66:1D:92',
        ),
      ],
    );
    final syncService = SyncService(
      repository: repository,
      transport: transport,
      simulateIfNoHardware: true,
    );

    await tester.pumpWidget(createTestWidget(
      repository: repository,
      syncService: syncService,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('1. Cerca WHOOP'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('WBB5AP-5AG0558675'));
    await tester.pumpAndSettle();

    // Verifica messaggio di errore esplicito
    expect(find.textContaining('Bonding fallito o annullato'), findsAtLeastNWidgets(1));
    expect(syncService.connectionState, isA<BleStatusError>());

    await tester.pumpWidget(const SizedBox());
    await repository.close();
  });
}
