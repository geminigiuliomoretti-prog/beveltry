import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'screens/dashboard_screen.dart';
import 'src/ble/ble.dart';
import 'src/repository/whoop_repository.dart';
import 'src/services/metrics_service.dart';
import 'src/services/sync_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final repository = WhoopRepository();
  final transport = defaultTargetPlatform == TargetPlatform.android
      ? MethodChannelPuffinTransport()
      : SimulatedPuffinTransport();
  final syncService = SyncService(
    repository: repository,
    transport: transport,
    simulateIfNoHardware: defaultTargetPlatform != TargetPlatform.android,
  );
  final metricsService = MetricsService(repository: repository);

  runApp(BeveltryApp(
    repository: repository,
    syncService: syncService,
    metricsService: metricsService,
  ));
}

class BeveltryApp extends StatelessWidget {
  const BeveltryApp({
    super.key,
    this.repository,
    this.syncService,
    this.metricsService,
  });

  final WhoopRepository? repository;
  final SyncService? syncService;
  final MetricsService? metricsService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Beveltry',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      ),
      home: DashboardScreen(
        repository: repository,
        syncService: syncService,
        metricsService: metricsService,
      ),
    );
  }
}
