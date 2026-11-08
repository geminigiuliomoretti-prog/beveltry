import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'ble_connection_state.dart';
import 'puffin_frame_codec.dart';
import 'puffin_transport.dart';

/// UUID canonici del protocollo BLE WHOOP 5.0 (Puffin Gen 5).
abstract class WhoopBleUuids {
  static const String puffinService = 'fd4b0001-cce1-4033-93ce-002d5875f58a';
  static const String cmdToStrap = 'fd4b0002-cce1-4033-93ce-002d5875f58a';
  static const String cmdFromStrap = 'fd4b0003-cce1-4033-93ce-002d5875f58a';
  static const String eventsFromStrap = 'fd4b0004-cce1-4033-93ce-002d5875f58a';
  static const String dataFromStrap = 'fd4b0005-cce1-4033-93ce-002d5875f58a';
  static const String memfault = 'fd4b0006-cce1-4033-93ce-002d5875f58a';
  static const String heartRateService = '0000180d-0000-1000-8000-00805f9b34fb';
  static const String heartRateMeasurement = '00002a37-0000-1000-8000-00805f9b34fb';
}

/// Implementazione concreta multipiattaforma (Windows, Android, iOS, macOS, Linux)
/// di [PuffinTransport] basata su [UniversalBle].
///
/// Si occupa di:
/// - Scansione dispositivi WHOOP 5.0 (filtraggio UUID 0xFD4B / prefissi WBB5AP e MAC target)
/// - Connessione GATT reale e pairing/bonding
/// - Sottoscrizione alle caratteristiche notify di Puffin Gen 5
/// - Riassemblaggio continuo degli stream di frame Puffin con [PuffinFrameReassembler]
/// - Scrittura con conferma (withResponse = true) sul characteristic CMD_TO_STRAP
class BlePuffinTransport implements PuffinTransport {
  BlePuffinTransport() {
    UniversalBle.timeout = const Duration(seconds: 30);
    _setupUniversalBleCallbacks();
  }

  bool _isConnected = false;
  WhoopDiscoveredDevice? _connectedDevice;

  final Map<String, PuffinFrameReassembler> _reassemblers = {
    WhoopBleUuids.cmdFromStrap: PuffinFrameReassembler(),
    WhoopBleUuids.eventsFromStrap: PuffinFrameReassembler(),
    WhoopBleUuids.dataFromStrap: PuffinFrameReassembler(),
    WhoopBleUuids.memfault: PuffinFrameReassembler(),
  };

  final StreamController<PuffinIncomingFrame> _incomingFramesController =
      StreamController<PuffinIncomingFrame>.broadcast();

  @override
  Stream<PuffinIncomingFrame> get incomingFrames =>
      _incomingFramesController.stream;

  @override
  bool get isConnected => _isConnected;

  WhoopDiscoveredDevice? get connectedDevice => _connectedDevice;

  void _setupUniversalBleCallbacks() {
    UniversalBle.onValueChange = (BleCharacteristicValue event) {
      final current = _connectedDevice;
      if (current == null) return;
      if (event.deviceId.toLowerCase() != current.macAddress.toLowerCase()) return;

      final normChar = event.characteristicId.toLowerCase();
      final charType = _mapUuidToCharacteristic(normChar);
      if (charType == null) return;

      final reassembler = _reassemblers[normChar];
      if (reassembler != null) {
        final frames = reassembler.feed(event.value);
        for (final frame in frames) {
          _incomingFramesController.add(
            PuffinIncomingFrame(frame: frame, characteristic: charType),
          );
        }
      }
    };

    UniversalBle.onConnectionChange = (BleConnectionChange change) {
      final current = _connectedDevice;
      if (current != null &&
          change.deviceId.toLowerCase() == current.macAddress.toLowerCase()) {
        _isConnected = change.isConnected;
        if (!change.isConnected) {
          _connectedDevice = null;
          _resetReassemblers();
        }
      }
    };
  }

  void _resetReassemblers() {
    for (final r in _reassemblers.values) {
      r.reset();
    }
  }

  static PuffinCharacteristic? _mapUuidToCharacteristic(String charUuid) {
    if (charUuid.contains('fd4b0003')) return PuffinCharacteristic.cmdFromStrap;
    if (charUuid.contains('fd4b0004')) return PuffinCharacteristic.eventsFromStrap;
    if (charUuid.contains('fd4b0005')) return PuffinCharacteristic.dataFromStrap;
    if (charUuid.contains('fd4b0006')) return PuffinCharacteristic.memfault;
    return null;
  }

  static String _mapCharacteristicToUuid(PuffinCharacteristic characteristic) {
    return switch (characteristic) {
      PuffinCharacteristic.cmdToStrap => WhoopBleUuids.cmdToStrap,
      PuffinCharacteristic.cmdFromStrap => WhoopBleUuids.cmdFromStrap,
      PuffinCharacteristic.eventsFromStrap => WhoopBleUuids.eventsFromStrap,
      PuffinCharacteristic.dataFromStrap => WhoopBleUuids.dataFromStrap,
      PuffinCharacteristic.memfault => WhoopBleUuids.memfault,
    };
  }

  @override
  Stream<List<WhoopDiscoveredDevice>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) async* {
    final discoveredMap = <String, WhoopDiscoveredDevice>{};
    final controller = StreamController<List<WhoopDiscoveredDevice>>.broadcast();

    StreamSubscription<BleDevice>? scanSubscription;
    Timer? timeoutTimer;

    try {
      final hasPerms = await UniversalBle.hasPermissions();
      if (!hasPerms) {
        await UniversalBle.requestPermissions();
      }

      scanSubscription = UniversalBle.scanStream.listen((device) {
        final id = device.deviceId;
        final name = device.name ?? '';
        final upperName = name.toUpperCase();
        final upperId = id.toUpperCase();
        final services = device.services.map((s) => s.toLowerCase()).toList();

        final matchesService = services.any((s) => s.contains('fd4b'));
        final matchesName = upperName.startsWith('WBB5AP') ||
            upperName.startsWith('5AG') ||
            upperName.contains('WHOOP');
        final matchesKnownMac =
            upperId == 'FD:49:44:66:1D:92' || upperId.contains('FD:49:44');

        if (matchesService || matchesName || matchesKnownMac) {
          final displayName = name.isNotEmpty
              ? name
              : (matchesKnownMac ? 'WHOOP 5.0 (FD:49:44:66:1D:92)' : 'WHOOP ($id)');

          discoveredMap[id] = WhoopDiscoveredDevice(
            name: displayName,
            macAddress: id,
            rssi: device.rssi ?? -70,
          );
          controller.add(discoveredMap.values.toList());
        }
      });

      await UniversalBle.startScan();

      timeoutTimer = Timer(timeout, () async {
        try {
          await UniversalBle.stopScan();
        } catch (_) {}
      });

      yield* controller.stream;
    } finally {
      timeoutTimer?.cancel();
      await scanSubscription?.cancel();
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
    }
  }

  @override
  Future<bool> connectAndBond(
    WhoopDiscoveredDevice device, {
    void Function()? onBondingStarted,
  }) async {
    try {
      await UniversalBle.stopScan();
    } catch (_) {}

    _resetReassemblers();
    final mac = device.macAddress;
    _connectedDevice = device;

    try {
      // 1. Connessione GATT
      await UniversalBle.connect(
        mac,
        timeout: const Duration(seconds: 30),
      );

      // 2. Richiesta MTU ottimale (512 byte)
      try {
        await UniversalBle.requestMtu(mac, 512);
      } catch (_) {
        // MTU non negoziabile su tutti i controller, prosegue
      }

      // 3. Procedura di Bonding / Pairing autenticato
      onBondingStarted?.call();
      try {
        final isPaired = await UniversalBle.isPaired(mac);
        if (isPaired != true) {
          await UniversalBle.pair(mac);
        }
      } catch (_) {
        // Ignora eccezioni non bloccanti (es. periferica già associata dall'OS)
      }

      // 4. Scoperta Servizi GATT
      await UniversalBle.discoverServices(mac);

      // 5. Sottoscrizione notifiche caratteristiche WHOOP 5.0
      await UniversalBle.subscribeNotifications(
        mac,
        WhoopBleUuids.puffinService,
        WhoopBleUuids.cmdFromStrap,
      );
      await UniversalBle.subscribeNotifications(
        mac,
        WhoopBleUuids.puffinService,
        WhoopBleUuids.eventsFromStrap,
      );
      await UniversalBle.subscribeNotifications(
        mac,
        WhoopBleUuids.puffinService,
        WhoopBleUuids.dataFromStrap,
      );

      try {
        await UniversalBle.subscribeNotifications(
          mac,
          WhoopBleUuids.heartRateService,
          WhoopBleUuids.heartRateMeasurement,
        );
      } catch (_) {
        // Servizio standard 0x180D opzionale rispetto al flusso proprietario
      }

      _isConnected = true;
      return true;
    } catch (e) {
      _isConnected = false;
      _connectedDevice = null;
      rethrow;
    }
  }

  @override
  Future<void> write(
    Uint8List frame, {
    PuffinCharacteristic characteristic = PuffinCharacteristic.cmdToStrap,
  }) async {
    final dev = _connectedDevice;
    if (dev == null || !_isConnected) {
      throw StateError('Dispositivo WHOOP non connesso');
    }

    final charUuid = _mapCharacteristicToUuid(characteristic);
    await UniversalBle.write(
      dev.macAddress,
      WhoopBleUuids.puffinService,
      charUuid,
      frame,
      withoutResponse: false, // withResponse = true obbligatorio
    );
  }

  @override
  Future<void> disconnect() async {
    final dev = _connectedDevice;
    try {
      if (dev != null) {
        await UniversalBle.disconnect(dev.macAddress);
      }
    } finally {
      _isConnected = false;
      _connectedDevice = null;
      _resetReassemblers();
    }
  }
}
