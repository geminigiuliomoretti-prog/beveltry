import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/ble.dart';
import '../records/record_decoder.dart';
import '../records/v18_record.dart';
import '../repository/whoop_repository.dart';

/// Stati possibili del processo di sincronizzazione con WHOOP.
enum SyncStatus {
  idle,
  connecting,
  syncing,
  completed,
  error,
}

/// Servizio che orchestra il ciclo di vita BLE (Scan, Select, Connect/Bond)
/// e l'offload dati dal WHOOP 5.0.
///
/// Si occupa di:
/// - Scansionare e filtrare i dispositivi WHOOP 5.0
/// - Gestire la transizione degli stati BLE: `Idle`, `Scanning`, `Discovered`, `Connecting`, `Bonding`, `Connected`, `Error`
/// - Avviare il flusso di ricezione frame
/// - Decodificare i frame `0x2F` tramite [RecordDecoder]
/// - Salvare i record [V18Record] nel [WhoopRepository]
/// - Inviare comandi al cinturino tramite [PuffinTransport] (es. vibrazione 0x42)
class SyncService {
  SyncService({
    required this.repository,
    this.strapSerial = '5AG0558675',
    Stream<Uint8List>? frameStream,
    this.simulateIfNoHardware = true,
    PuffinTransport? transport,
    BleConnectionStatus? initialConnectionState,
  })  : _customFrameStream = frameStream,
        transport = transport ?? SimulatedPuffinTransport() {
    if (initialConnectionState != null) {
      connectionStateNotifier.value = initialConnectionState;
    }
  }

  final WhoopRepository repository;
  final String strapSerial;
  final Stream<Uint8List>? _customFrameStream;
  final bool simulateIfNoHardware;
  final PuffinTransport transport;

  final ValueNotifier<BleConnectionStatus> connectionStateNotifier =
      ValueNotifier<BleConnectionStatus>(const BleStatusIdle());
  final ValueNotifier<SyncStatus> statusNotifier =
      ValueNotifier<SyncStatus>(SyncStatus.idle);
  final ValueNotifier<String> statusMessageNotifier =
      ValueNotifier<String>('Pronto per la ricerca o sincronizzazione.');
  final ValueNotifier<int> recordsSavedNotifier = ValueNotifier<int>(0);

  bool _isCancelled = false;
  int _commandSeq = 1;

  BleConnectionStatus get connectionState => connectionStateNotifier.value;
  bool get isConnected => connectionStateNotifier.value.isConnected;

  bool get isSyncing =>
      statusNotifier.value == SyncStatus.connecting ||
      statusNotifier.value == SyncStatus.syncing;

  int _nextSeq() {
    final s = _commandSeq;
    _commandSeq = (_commandSeq % 255) + 1;
    return s;
  }

  /// Avvia la scansione BLE filtrando i dispositivi per UUID 0xFD4B o prefisso WBB5AP / 5AG.
  Future<void> scanForDevices({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    connectionStateNotifier.value = const BleStatusScanning();
    statusMessageNotifier.value = '1. Scansione BLE avviata (filtro 0xFD4B / WBB5AP)...';

    try {
      final stream = transport.scan(timeout: timeout);
      await for (final devices in stream) {
        final filtered = devices.where((d) {
          final n = d.name.toUpperCase();
          return n.startsWith('WBB5AP') ||
              n.startsWith('5AG') ||
              n.contains('WHOOP');
        }).toList();

        final resultList = filtered.isNotEmpty ? filtered : devices;
        connectionStateNotifier.value = BleStatusDiscovered(resultList);
        statusMessageNotifier.value = resultList.isEmpty
            ? 'Nessun dispositivo WHOOP rilevato in pairing mode.'
            : 'Trovati ${resultList.length} dispositivi WHOOP.';
      }
    } catch (e) {
      connectionStateNotifier.value = BleStatusError(e.toString());
      statusMessageNotifier.value = 'Errore scansione BLE: $e';
    }
  }

  /// Avvia connessione GATT e procedura di accoppiamento (bonding) autenticato.
  Future<bool> connectAndBond(WhoopDiscoveredDevice device) async {
    connectionStateNotifier.value = BleStatusConnecting(device: device);
    statusMessageNotifier.value =
        'Connessione e Bonding... Connessione GATT a ${device.name} (${device.macAddress}).';

    try {
      final success = await transport.connectAndBond(
        device,
        onBondingStarted: () {
          connectionStateNotifier.value = BleStatusBonding(device: device);
          statusMessageNotifier.value =
              'Connessione e Bonding... In attesa di autorizzazione pairing dal sistema.';
        },
      );

      if (success) {
        connectionStateNotifier.value = BleStatusConnected(device);
        statusMessageNotifier.value = 'Connesso a ${device.name}';
        return true;
      } else {
        connectionStateNotifier.value =
            const BleStatusError('Bonding fallito o annullato');
        statusMessageNotifier.value =
            'Bonding fallito o annullato. Riprova verificando il pairing mode (LED blu).';
        return false;
      }
    } catch (e) {
      connectionStateNotifier.value =
          BleStatusError('Bonding fallito o annullato: $e');
      statusMessageNotifier.value = 'Errore durante connect/bond: $e';
      return false;
    }
  }

  /// Disconnette il dispositivo e reimposta lo stato su Idle.
  Future<void> disconnect() async {
    try {
      await transport.disconnect();
    } finally {
      connectionStateNotifier.value = const BleStatusIdle();
      statusNotifier.value = SyncStatus.idle;
      statusMessageNotifier.value = 'Disconnesso dal dispositivo.';
    }
  }

  /// Invia il comando 0x42 (SET_ALARM_TIME / ALARM_CONTROL) per far vibrare il cinturino.
  ///
  /// Parametri:
  /// - [slot]: indice slot sveglia (default 1)
  /// - [pattern]: pattern di vibrazione (default 1)
  /// - [durationMs]: durata in millisecondi (default 1000 ms)
  Future<bool> sendVibration({
    int slot = 1,
    int pattern = 1,
    int durationMs = 1000,
  }) async {
    if (!transport.isConnected) {
      statusMessageNotifier.value =
          'Impossibile inviare vibrazione: cinturino non connesso.';
      return false;
    }

    final seq = _nextSeq();
    final innerCmd = Uint8List.fromList([
      0x23,
      seq,
      0x42, // Opcode SET_ALARM_TIME / ALARM_CONTROL
      slot & 0xFF,
      pattern & 0xFF,
      durationMs & 0xFF,
      (durationMs >> 8) & 0xFF,
    ]);

    final frame = PuffinFrameCodec.encode(1, innerCmd);
    await transport.write(
      frame,
      characteristic: PuffinCharacteristic.cmdToStrap,
    );
    statusMessageNotifier.value =
        'Comando vibrazione 0x42 inviato con successo (slot $slot).';
    return true;
  }

  /// Avvia l'offload e la memorizzazione dei record.
  ///
  /// Restituisce il numero totale di record salvati in questa sessione.
  Future<int> startSync({int simulationRecordCount = 30}) async {
    if (isSyncing) {
      statusMessageNotifier.value = 'Sincronizzazione già in corso.';
      return 0;
    }

    _isCancelled = false;
    recordsSavedNotifier.value = 0;
    statusNotifier.value = SyncStatus.connecting;
    statusMessageNotifier.value = 'Connessione al cinturino $strapSerial...';

    try {
      if (_customFrameStream != null) {
        return await _syncFromStream(_customFrameStream);
      } else if (simulateIfNoHardware) {
        return await _syncSimulated(recordCount: simulationRecordCount);
      } else {
        statusNotifier.value = SyncStatus.error;
        statusMessageNotifier.value = 'Nessun canale BLE hardware disponibile.';
        return 0;
      }
    } catch (e) {
      statusNotifier.value = SyncStatus.error;
      statusMessageNotifier.value = 'Errore di sincronizzazione: $e';
      return recordsSavedNotifier.value;
    }
  }

  /// Interrompe la sincronizzazione in corso.
  void stopSync() {
    if (isSyncing) {
      _isCancelled = true;
      statusMessageNotifier.value = 'Interruzione sincronizzazione richiesta...';
    }
  }

  Future<int> _syncFromStream(Stream<Uint8List> stream) async {
    statusNotifier.value = SyncStatus.syncing;
    var saved = 0;

    await for (final rawFrame in stream) {
      if (_isCancelled) break;

      try {
        final decoded = RecordDecoder.decode(rawFrame);
        if (decoded is V18Record) {
          await repository.saveV18Record(decoded, strapSerial);
          saved++;
          recordsSavedNotifier.value = saved;
          statusMessageNotifier.value = 'Scaricati $saved record...';
        }
      } catch (err) {
        // Ignora frame non riconosciuti o corrotti e prosegue
      }
    }

    statusNotifier.value = SyncStatus.completed;
    statusMessageNotifier.value =
        _isCancelled ? 'Sincronizzazione interrotta.' : 'Sincronizzazione completata: $saved record salvati.';
    return saved;
  }

  Future<int> _syncSimulated({int recordCount = 360}) async {
    statusNotifier.value = SyncStatus.syncing;
    statusMessageNotifier.value = 'Avvio offload storico BLE (Puffin 0x16)...';

    final baseTime = DateTime.now().toUtc().subtract(Duration(seconds: recordCount));
    final records = <V18Record>[];

    for (var i = 0; i < recordCount; i++) {
      if (_isCancelled) break;

      final ts = baseTime.add(Duration(seconds: i));
      final isDeepSleep = i >= 30 && i < 330; // 5 minuti di deep sleep sostenuto a 52 bpm
      final hr = isDeepSleep ? 52 : 68;
      final rrMs = (60000 / hr).round();

      final payload = _generateV18Payload(
        seq: i + 1,
        timestampSeconds: ts.millisecondsSinceEpoch ~/ 1000,
        hrPrimary: hr,
        hrSecondary: hr - 1,
        rrIntervals: [rrMs],
        sleepState: isDeepSleep ? 2 : 1,
      );

      final record = RecordDecoder.decode(payload);
      if (record is V18Record) {
        records.add(record);
      }
    }

    if (records.isNotEmpty) {
      await repository.saveV18RecordsBatch(records, strapSerial);
    }

    final saved = records.length;
    recordsSavedNotifier.value = saved;
    statusNotifier.value = SyncStatus.completed;
    statusMessageNotifier.value =
        _isCancelled ? 'Sincronizzazione interrotta ($saved salvati).' : 'Sincronizzazione completata: $saved record salvati.';
    return saved;
  }

  /// Costruisce un payload interno V18 valido da 112 byte conforme al protocollo WHOOP.
  static Uint8List _generateV18Payload({
    required int seq,
    required int timestampSeconds,
    required int hrPrimary,
    required int hrSecondary,
    required List<int> rrIntervals,
    required int sleepState,
  }) {
    final payload = Uint8List(112);
    final data = ByteData.sublistView(payload);

    payload[0] = 0x2F; // Historical burst
    payload[1] = 0x12; // v18 version
    data.setUint16(2, seq, Endian.little);
    data.setUint32(7, timestampSeconds, Endian.little);
    payload[14] = hrPrimary;
    final rrCount = rrIntervals.length.clamp(0, 4);
    payload[15] = rrCount;

    for (var i = 0; i < rrCount; i++) {
      data.setUint16(16 + i * 2, rrIntervals[i], Endian.little);
    }

    payload[29] = hrSecondary;
    data.setFloat32(37, 0.0, Endian.little); // Gravity X
    data.setFloat32(41, 0.0, Endian.little); // Gravity Y
    data.setFloat32(45, 1.0, Endian.little); // Gravity Z
    data.setUint16(57, 100, Endian.little);  // Steps
    data.setInt16(61, 320, Endian.little);   // Skin temp (32.0 C)
    payload[64] = 0;                        // Activity flag
    payload[82] = 0;                        // SpO2 candidate
    payload[96] = sleepState;               // Sleep state
    data.setUint16(98, 35000, Endian.little);  // Optical baseline Ch1
    data.setUint16(106, 35000, Endian.little); // Optical baseline Ch2

    return payload;
  }
}
