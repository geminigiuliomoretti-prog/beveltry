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
  static const String memfault = 'fd4b0007-cce1-4033-93ce-002d5875f58a';
  static const String heartRateService = '0000180d-0000-1000-8000-00805f9b34fb';
  static const String heartRateMeasurement = '00002a37-0000-1000-8000-00805f9b34fb';
}

/// Eccezione sollevata quando la procedura di accoppiamento/bonding di sistema fallisce o viene rifiutata.
class BleBondException implements Exception {
  BleBondException(this.message);
  final String message;

  @override
  String toString() => message;
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
  final StreamController<Uint8List> _standardHrController =
      StreamController<Uint8List>.broadcast();
  final StreamController<bool> _connectionChangeController =
      StreamController<bool>.broadcast();

  Future<void> _writeQueue = Future.value();

  @override
  Stream<PuffinIncomingFrame> get incomingFrames =>
      _incomingFramesController.stream;

  @override
  Stream<Uint8List> get standardHrStream => _standardHrController.stream;

  @override
  Stream<bool> get onConnectionChanged => _connectionChangeController.stream;

  @override
  bool get isConnected => _isConnected;

  WhoopDiscoveredDevice? get connectedDevice => _connectedDevice;

  void _setupUniversalBleCallbacks() {
    UniversalBle.onValueChange = (BleCharacteristicValue event) {
      final current = _connectedDevice;
      if (current == null) return;
      if (event.deviceId.toLowerCase() != current.macAddress.toLowerCase()) return;

      final normChar = event.characteristicId.toLowerCase();

      // Instradamento canale standard Bluetooth SIG 0x2A37
      if (normChar.contains('2a37')) {
        _standardHrController.add(event.value);
        return;
      }

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
        _connectionChangeController.add(change.isConnected);
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
    if (charUuid.contains('fd4b0007')) return PuffinCharacteristic.memfault;
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

      // 1. Controllo Dispositivi di Sistema (Già Associati/Bonded) PRIMA dello Scan
      try {
        List<BleDevice> systemDevices = [];
        try {
          systemDevices = await UniversalBle.getSystemDevices(
            withServices: [WhoopBleUuids.puffinService],
          );
        } catch (_) {}
        if (systemDevices.isEmpty) {
          try {
            systemDevices = await UniversalBle.getSystemDevices();
          } catch (_) {}
        }

        for (final device in systemDevices) {
          final id = device.deviceId;
          final name = device.name ?? '';
          final upperName = name.toUpperCase();
          final upperId = id.toUpperCase();

          // Ignora esplicitamente il WHOOP A
          if (upperName.contains('5A00479315')) continue;

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
              rssi: device.rssi ?? -50,
            );
          }
        }

        if (discoveredMap.isNotEmpty) {
          controller.add(discoveredMap.values.toList());
        }
      } catch (_) {}

      // 2. Scan Reale con Popolamento Cache di universal_ble
      scanSubscription = UniversalBle.scanStream.listen((device) {
        final id = device.deviceId;
        final name = device.name ?? '';
        final upperName = name.toUpperCase();
        final upperId = id.toUpperCase();

        // Ignora esplicitamente il WHOOP A
        if (upperName.contains('5A00479315')) return;

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

  static bool _isGatt133Error(Object error) {
    final str = error.toString().toLowerCase();
    return str.contains('133');
  }

  @override
  Future<bool> connectAndBond(
    WhoopDiscoveredDevice device, {
    void Function()? onBondingStarted,
    void Function(String message)? onRetryProgress,
    int maxRetries = 3,
    Duration retryDelay = const Duration(seconds: 2),
  }) async {
    final mac = device.macAddress;

    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        // 1. Fermare la scansione prima di connettersi e attendere 300ms
        try {
          await UniversalBle.stopScan();
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // Popola la cache nativa di universal_ble se il dispositivo era bonded di sistema
        try {
          await UniversalBle.getSystemDevices();
        } catch (_) {}

        _resetReassemblers();
        _connectedDevice = device;

        // 2. Controllo se già associato (isPaired): se true, salta pair()
        bool isAlreadyBonded = false;
        try {
          isAlreadyBonded = (await UniversalBle.isPaired(mac)) == true;
        } catch (_) {}

        if (!isAlreadyBonded) {
          onBondingStarted?.call();
          try {
            await UniversalBle.pair(mac, timeout: const Duration(seconds: 35));
          } catch (pairErr) {
            // Non bloccare la connessione se pair() fallisce: registra e prosegui con connect e discoverServices
            onRetryProgress?.call('Avviso pairing: $pairErr. Proseguimento con connessione...');
          }
        }

        // 3. Connessione GATT con trasporto LE (30s)
        await UniversalBle.connect(
          mac,
          timeout: const Duration(seconds: 30),
        );

        // Richiesta MTU ottimale (512 byte)
        try {
          await UniversalBle.requestMtu(mac, 512);
        } catch (_) {
          // MTU non negoziabile su tutti i controller, prosegue
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
            WhoopBleUuids.puffinService,
            WhoopBleUuids.memfault,
          );
        } catch (_) {}

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

        // Chiudere esplicitamente il GATT in caso di errore
        try {
          await UniversalBle.disconnect(mac);
        } catch (_) {}

        // Se errore 133 e rimangono tentativi, chiude GATT, attende 2 secondi e riprova
        final is133 = _isGatt133Error(e);
        if (is133 && attempt < maxRetries) {
          onRetryProgress?.call(
            'Errore GATT 133 rilevato al tentativo $attempt/$maxRetries. '
            'GATT chiuso. Attesa di ${retryDelay.inSeconds} secondi prima del prossimo tentativo...',
          );
          await Future<void>.delayed(retryDelay);
          continue;
        }

        if (attempt == maxRetries) {
          rethrow;
        }
        await Future<void>.delayed(retryDelay);
      }
    }

    return false;
  }

  @override
  Future<void> write(
    Uint8List frame, {
    PuffinCharacteristic characteristic = PuffinCharacteristic.cmdToStrap,
  }) async {
    final completer = Completer<void>();
    _writeQueue = _writeQueue.then((_) async {
      try {
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
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
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
