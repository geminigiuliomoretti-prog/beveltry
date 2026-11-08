import 'dart:async';
import 'dart:typed_data';

import 'ble_connection_state.dart';
import 'puffin_frame_codec.dart';

/// Characteristic GATT utilizzate dal servizio Puffin Gen 5 (`fd4b`).
enum PuffinCharacteristic {
  cmdToStrap,
  cmdFromStrap,
  eventsFromStrap,
  dataFromStrap,
  memfault,
}

/// Contenitore per un frame Puffin ricevuto e la caratteristica sorgente.
class PuffinIncomingFrame {
  const PuffinIncomingFrame({
    required this.frame,
    required this.characteristic,
  });

  final PuffinFrame frame;
  final PuffinCharacteristic characteristic;
}

/// Contratto per il trasporto BLE di basso livello verso il WHOOP 5.0.
abstract class PuffinTransport {
  /// Stream di tutti i frame Puffin decodificati con la caratteristica sorgente.
  Stream<PuffinIncomingFrame> get incomingFrames;

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
    void Function(String message)? onRetryProgress,
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
    this.simulate133FailuresBeforeSuccess = 0,
    this.simulatePersistent133 = false,
  }) : simulatedDevices = simulatedDevices ??
            [
              const WhoopDiscoveredDevice(
                name: 'WBB5AP-5AG0558675',
                macAddress: 'FD:49:44:66:1D:92',
                rssi: -62,
              ),
            ];

  final _incomingFramesController =
      StreamController<PuffinIncomingFrame>.broadcast();

  @override
  Stream<PuffinIncomingFrame> get incomingFrames =>
      _incomingFramesController.stream;

  /// Emette un frame simulato nello stream in ingresso.
  void emitFrame(
    PuffinFrame frame, [
    PuffinCharacteristic characteristic = PuffinCharacteristic.cmdFromStrap,
  ]) {
    _incomingFramesController.add(PuffinIncomingFrame(
      frame: frame,
      characteristic: characteristic,
    ));
  }

  @override
  bool isConnected;

  /// Dispositivi da restituire durante la scansione simulata.
  List<WhoopDiscoveredDevice> simulatedDevices;

  /// Dispositivo attualmente connesso.
  WhoopDiscoveredDevice? connectedDevice;

  /// Se true, simula il rifiuto o annullamento del pairing di sistema.
  bool simulateBondFailure;

  /// Conteggio dei tentativi di connessione effettuati.
  int connectAttempts = 0;

  /// Quante volte simulare un errore GATT 133 prima di completare con successo.
  int simulate133FailuresBeforeSuccess = 0;

  /// Se true, simula un errore persistente GATT 133 (superando tutti i retry).
  bool simulatePersistent133 = false;

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
    void Function(String message)? onRetryProgress,
  }) async {
    connectAttempts++;
    if (simulatePersistent133 || connectAttempts <= simulate133FailuresBeforeSuccess) {
      throw StateError(
        'UniversalBleException: Code: UniversalBleErrorCode.unknownError, Message: Unknown Error 133',
      );
    }

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
