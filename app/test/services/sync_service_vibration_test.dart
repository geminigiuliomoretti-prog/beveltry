import 'package:beveltry/src/ble/ble.dart';
import 'package:beveltry/src/repository/whoop_repository.dart';
import 'package:beveltry/src/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SyncService BLE Lifecycle & Vibration Tests', () {
    late WhoopRepository repository;
    late SimulatedPuffinTransport transport;
    late SyncService syncService;

    setUp(() {
      repository = WhoopRepository.inMemory();
      transport = SimulatedPuffinTransport(
        isConnected: false,
        simulatedDevices: [
          const WhoopDiscoveredDevice(
            name: 'WBB5AP-5AG0558675',
            macAddress: 'FD:49:44:66:1D:92',
            rssi: -60,
          ),
        ],
      );
      syncService = SyncService(
        repository: repository,
        transport: transport,
      );
    });

    tearDown(() async {
      await repository.close();
    });

    test('Stato iniziale è Idle e pulsanti/comandi richiedono connessione', () {
      expect(syncService.connectionState, isA<BleStatusIdle>());
      expect(syncService.isConnected, isFalse);
    });

    test('Flusso completo: scan -> discovered -> connectAndBond -> connected -> vibration -> disconnect', () async {
      // 1. Scan
      final scanFuture = syncService.scanForDevices();
      expect(syncService.connectionState, isA<BleStatusScanning>());
      await scanFuture;

      expect(syncService.connectionState, isA<BleStatusDiscovered>());
      final discoveredState = syncService.connectionState as BleStatusDiscovered;
      expect(discoveredState.devices.length, equals(1));
      expect(discoveredState.devices.first.name, equals('WBB5AP-5AG0558675'));

      // 2. Connect & Bond
      final connectSuccess = await syncService.connectAndBond(discoveredState.devices.first);
      expect(connectSuccess, isTrue);
      expect(syncService.connectionState, isA<BleStatusConnected>());
      expect(syncService.isConnected, isTrue);

      // 3. Test Vibrazione (0x42)
      final vibSuccess = await syncService.sendVibration(slot: 1, pattern: 1, durationMs: 1000);
      expect(vibSuccess, isTrue);
      expect(transport.sentFrames.length, equals(1));

      final frame = transport.sentFrames.first;
      expect(frame[0], equals(0xAA));
      expect(frame[1], equals(0x01));

      final innerPayload = PuffinFrameCodec.decode(frame);
      expect(innerPayload[0], equals(0x23)); // Command prefix
      expect(innerPayload[1], equals(1));    // Sequence 1
      expect(innerPayload[2], equals(0x42)); // Opcode SET_ALARM_TIME / ALARM_CONTROL
      expect(innerPayload[3], equals(0x01)); // Slot 1
      expect(innerPayload[4], equals(0x01)); // Pattern 1
      expect(innerPayload[5], equals(0xE8)); // 1000 ms lower byte
      expect(innerPayload[6], equals(0x03)); // 1000 ms upper byte

      // 4. Disconnect
      await syncService.disconnect();
      expect(syncService.connectionState, isA<BleStatusIdle>());
      expect(syncService.isConnected, isFalse);
      expect(transport.isConnected, isFalse);
    });

    test('sendVibration fallisce se il trasporto non è connesso', () async {
      final success = await syncService.sendVibration(slot: 1);
      expect(success, isFalse);
      expect(transport.sentFrames, isEmpty);
      expect(
        syncService.statusMessageNotifier.value,
        contains('cinturino non connesso'),
      );
    });

    test('connectAndBond gestisce rifiuto di bonding impostando BleStatusError', () async {
      transport.simulateBondFailure = true;
      final device = const WhoopDiscoveredDevice(
        name: 'WBB5AP-5AG0558675',
        macAddress: 'FD:49:44:66:1D:92',
      );

      final success = await syncService.connectAndBond(device);
      expect(success, isFalse);
      expect(syncService.connectionState, isA<BleStatusError>());
      final errorState = syncService.connectionState as BleStatusError;
      expect(errorState.message, contains('Bonding fallito o annullato'));
    });
  });
}
