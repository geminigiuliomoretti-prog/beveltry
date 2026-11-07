import 'dart:typed_data';

import 'ble_connection_state.dart';

/// Characteristic GATT utilizzate dal servizio Puffin Gen 5 (`fd4b`).
enum PuffinCharacteristic {
  cmdToStrap,
  cmdFromStrap,
  eventsFromStrap,
  dataFromStrap,
  memfault,
}

/// Contratto per il trasporto BLE di basso livello verso il WHOOP 5.0.
abstract class PuffinTransport {
  /// Invia un frame binario envelope al cinturino.
  Future<void> write(
    Uint8List frame, {
    PuffinCharacteristic characteristic = PuffinCharacteristic.cmdToStrap,
  });

  /// Indica se il trasporto è connesso e pronto all'invio.
  bool get isConnected;

  /// Scansiona i dispositivi Bluetooth nelle vicinanze.
  Stream<List<WhoopDiscoveredDevice>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) =>
      Stream.value(const []);

  /// Si connette al dispositivo specificato e avvia la procedura di pairing/bonding.
  Future<bool> connectAndBond(
    WhoopDiscoveredDevice device, {
    void Function()? onBondingStarted,
  }) async =>
      true;

  /// Chiude la connessione GATT e reimposta lo stato.
  Future<void> disconnect() async {}
}

/// Trasporto simulato per test e per esecuzione in ambienti senza hardware connesso.
class SimulatedPuffinTransport implements PuffinTransport {
  SimulatedPuffinTransport({
    this.isConnected = true,
    List<WhoopDiscoveredDevice>? simulatedDevices,
    this.simulateBondFailure = false,
  }) : simulatedDevices = simulatedDevices ??
            [
              const WhoopDiscoveredDevice(
                name: 'WBB5AP-5AG0558675',
                macAddress: 'FD:49:44:66:1D:92',
                rssi: -62,
              ),
            ];

  @override
  bool isConnected;

  /// Dispositivi da restituire durante la scansione simulata.
  List<WhoopDiscoveredDevice> simulatedDevices;

  /// Dispositivo attualmente connesso.
  WhoopDiscoveredDevice? connectedDevice;

  /// Se true, simula il rifiuto o annullamento del pairing di sistema.
  bool simulateBondFailure;

  /// Registro dei frame inviati durante la sessione.
  final List<Uint8List> sentFrames = [];

  @override
  Future<void> write(
    Uint8List frame, {
    PuffinCharacteristic characteristic = PuffinCharacteristic.cmdToStrap,
  }) async {
    sentFrames.add(Uint8List.fromList(frame));
  }

  @override
  Stream<List<WhoopDiscoveredDevice>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) async* {
    yield List.unmodifiable(simulatedDevices);
  }

  @override
  Future<bool> connectAndBond(
    WhoopDiscoveredDevice device, {
    void Function()? onBondingStarted,
  }) async {
    onBondingStarted?.call();
    if (simulateBondFailure) {
      isConnected = false;
      connectedDevice = null;
      return false;
    }
    isConnected = true;
    connectedDevice = device;
    return true;
  }

  @override
  Future<void> disconnect() async {
    isConnected = false;
    connectedDevice = null;
  }
}
