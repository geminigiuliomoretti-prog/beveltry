import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:whoop_app/ui/theme.dart';
import 'package:whoop_app/biometrics/dsp_engine.dart';
import 'package:whoop_app/ui/home_tab.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whoop_app/transport/ble_manager.dart';

class FakeUniversalBlePlatform extends UniversalBlePlatform {
  bool _isScanning = false;

  @override
  Future<void> startScan({ScanFilter? scanFilter, PlatformConfig? platformConfig}) async {
    _isScanning = true;
  }

  @override
  Future<void> stopScan() async {
    _isScanning = false;
  }

  @override
  Future<bool> isScanning() async => _isScanning;

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    updateConnection(deviceId, false);
  }

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors, {
    DiscoverServicesPlatformConfig? platformConfig,
  }) async =>
      [];

  @override
  Future<bool> enableBluetooth() async => true;

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async => AvailabilityState.poweredOn;

  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async => [];

  @override
  Future<Uint8List> readValue(
    String deviceId,
    String service,
    String characteristic, {
    Duration? timeout,
  }) async =>
      Uint8List(0);

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {}

  @override
  Future<Uint8List> readDescriptorValue(
    String deviceId,
    String service,
    String characteristic,
    String descriptor, {
    Duration? timeout,
  }) async =>
      Uint8List(0);

  @override
  Future<void> writeDescriptorValue(
    String deviceId,
    String service,
    String characteristic,
    String descriptor,
    Uint8List value,
  ) async {}

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async => 512;

  @override
  Future<void> requestConnectionPriority(String deviceId, BleConnectionPriority priority) async {}

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {}

  @override
  Future<bool> isPaired(String deviceId) async => true;

  @override
  Future<bool> pair(String deviceId) async => true;

  @override
  Future<void> unpair(String deviceId) async {}

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async =>
      BleConnectionState.disconnected;

  @override
  Future<bool> disableBluetooth() async => true;

  @override
  Future<void> requestPermissions({bool withAndroidFineLocation = false}) async {}

  @override
  Future<int> readRssi(String deviceId) async => -60;
}

void main() {
  setUpAll(() {
    UniversalBle.setInstance(FakeUniversalBlePlatform());
  });

  test('WhoopBleManager zero mock values and manual scan/disconnect verification', () async {
    final ble = WhoopBleManager.instance;

    expect(ble.batteryLevel, equals(0));
    expect(ble.opticalBaseline, equals(0));
    expect(ble.skinTempC, equals(0.0));
    expect(ble.liveRrMs, isEmpty);
    expect(ble.liveHr, equals(0));
    expect(ble.isOnWrist, isFalse);
    expect(ble.connectionState, equals(StrapConnectionState.disconnected));
    expect(ble.discoveredDevices, isEmpty);

    await ble.disconnect();
    expect(ble.connectionState, equals(StrapConnectionState.disconnected));
  });

  testWidgets('HomeTab UI components smoke test and connect button', (WidgetTester tester) async {
    final recovery = BiometricsDspEngine.computeRecovery(
      rmssd: 78.4,
      rhr: 50.6,
      sleepEfficiency: 0.85,
    );
    final strain = BiometricsDspEngine.computeStrain([50, 55, 60]);
    final sleep = BiometricsDspEngine.computeSleep([], [800, 820]);
    final stress = BiometricsDspEngine.computeRealTimeStress(
      currentHr: 54,
      currentRmssd: 78.4,
      motionDeltaG: 0.02,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWhoopTheme(),
        home: Scaffold(
          body: ChangeNotifierProvider.value(
            value: WhoopBleManager.instance,
            child: HomeTab(
              recovery: recovery,
              strain: strain,
              sleep: sleep,
              stress: stress,
              onSyncPressed: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('RECOVERY'), findsOneWidget);
    expect(find.text('DAY STRAIN'), findsOneWidget);
    expect(find.text('LIVE HEART RATE'), findsOneWidget);
    expect(find.text('SYNC FLASH DATA'), findsOneWidget);
    expect(find.text('VIBRATE'), findsOneWidget);
    expect(find.text('CONNECT STRAP'), findsOneWidget);
    expect(find.text('DISCONNECTED'), findsOneWidget);
    expect(find.text('OFFLINE'), findsOneWidget);

    WhoopBleManager.instance.cancelTimers();
  });

  testWidgets('HomeTab displays multiple discovered straps and lets user choose', (WidgetTester tester) async {
    final ble = WhoopBleManager.instance;
    await ble.startScan();

    // Simulate discovering 2 different WHOOP straps
    final devA = BleDevice(deviceId: 'FD:49:44:66:1D:92', name: 'WHOOP 5.0 (Strap A)', rssi: -60);
    final devB = BleDevice(deviceId: 'AA:BB:CC:DD:EE:FF', name: 'WHOOP 4.0 (Strap B)', rssi: -75);
    ble.handleDiscoveredDevice(devA);
    ble.handleDiscoveredDevice(devB);

    final recovery = RecoveryResult(
      score: 0,
      category: RecoveryCategory.yellow,
      rmssd: 0,
      rhr: 0,
      sleepEfficiency: 0,
      skinTempDelta: 0,
    );
    final strain = StrainResult(
      score: 0.0,
      maxHr: 0,
      avgHr: 0.0,
      zoneSeconds: {'zone1': 0, 'zone2': 0, 'zone3': 0, 'zone4': 0, 'zone5': 0},
    );
    final sleep = SleepResult(
      totalSleepHours: 0,
      sleepPerformance: 0,
      sleepEfficiency: 0,
      deepPercent: 0,
      remPercent: 0,
      lightPercent: 0,
      awakePercent: 0,
      respiratoryRate: 0,
    );
    final stress = StressResult(stressScore: 0, label: 'NO DATA', motionDecoupled: false);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWhoopTheme(),
        home: Scaffold(
          body: ChangeNotifierProvider.value(
            value: ble,
            child: HomeTab(
              recovery: recovery,
              strain: strain,
              sleep: sleep,
              stress: stress,
              onSyncPressed: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('AVAILABLE WHOOP STRAPS'), findsOneWidget);
    expect(find.text('WHOOP 5.0 (Strap A)'), findsOneWidget);
    expect(find.text('WHOOP 4.0 (Strap B)'), findsOneWidget);
    expect(find.text('CONNECT'), findsNWidgets(2));

    await ble.disconnect();
    ble.cancelTimers();
  });
}
