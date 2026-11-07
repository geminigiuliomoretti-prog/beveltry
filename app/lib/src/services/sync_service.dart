import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/ble.dart';
import '../records/live28_record.dart';
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
/// - Eseguire l'autenticazione crittografica e handshake hardware con [DartPuffinHandshake]
/// - Avviare l'offload storico (0x16) e ascoltare i record reali su DATA_FROM_STRAP (0xFD4B0005)
/// - Rispondere in tempo reale agli eventi cursor (0x31) con ACK (0x17)
/// - Decodificare i record 0x2F v18 e 0x28 live salvando nel repository
/// - Inviare comandi di vibrazione 0x42 e verificare l'ACK 0x24 hardware
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

  // Notifier telemetrici in tempo reale
  final ValueNotifier<DateTime?> lastTimestampNotifier = ValueNotifier<DateTime?>(null);
  final ValueNotifier<int?> lastHrNotifier = ValueNotifier<int?>(null);
  final ValueNotifier<List<int>?> lastRrNotifier = ValueNotifier<List<int>?>(null);
  final ValueNotifier<double?> lastSkinTempNotifier = ValueNotifier<double?>(null);
  final ValueNotifier<int?> liveHrNotifier = ValueNotifier<int?>(null);
  final ValueNotifier<int?> liveRrNotifier = ValueNotifier<int?>(null);
  final ValueNotifier<int?> lastVibrationStatusNotifier = ValueNotifier<int?>(null);

  bool _isCancelled = false;
  int _commandSeq = 1;
  Completer<int>? _activeRealSyncCompleter;

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
          final m = d.macAddress.toUpperCase();
          return n.startsWith('WBB5AP') ||
              n.startsWith('5AG') ||
              n.contains('WHOOP') ||
              m == 'FD:49:44:66:1D:92' ||
              m.contains('FD:49:44');
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

  /// Avvia connessione GATT, procedura di accoppiamento (bonding) ed handshake hardware.
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

      if (!success) {
        connectionStateNotifier.value =
            const BleStatusError('Bonding fallito o annullato');
        statusMessageNotifier.value =
            'Bonding fallito o annullato. Riprova verificando il pairing mode (LED blu).';
        return false;
      }

      // Esecuzione Handshake Puffin Hardware per sbloccare la sessione del WHOOP
      if (transport is! SimulatedPuffinTransport) {
        statusMessageNotifier.value = 'Esecuzione Handshake di autenticazione con il WHOOP...';
        final handshake = DartPuffinHandshake(transport);
        await handshake.start(onProgress: (step) {
          statusMessageNotifier.value = step;
        });
      }

      connectionStateNotifier.value = BleStatusConnected(device, isHardwareVerified: true);
      statusMessageNotifier.value = 'Connesso a ${device.name} (Verificato Hardware)';
      return true;
    } catch (e) {
      connectionStateNotifier.value =
          BleStatusError('Connessione o Handshake fallito: $e');
      statusMessageNotifier.value = 'Errore durante connect/handshake: $e';
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
      liveHrNotifier.value = null;
      liveRrNotifier.value = null;
    }
  }

  /// Invia il comando 0x42 (ALARM_CONTROL / Haptics) per far vibrare il cinturino.
  ///
  /// Parametri:
  /// - [slot]: indice slot sveglia (default 1)
  /// - [pattern]: pattern di vibrazione (default 1)
  /// - [durationMs]: durata in millisecondi (default 1000 ms = 0x03E8 LE)
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
      0x42, // Opcode ALARM_CONTROL / Haptics
      slot & 0xFF,
      pattern & 0xFF,
      durationMs & 0xFF,
      (durationMs >> 8) & 0xFF,
    ]);

    final frame = PuffinFrameCodec.encode(1, innerCmd);

    if (transport is SimulatedPuffinTransport) {
      await transport.write(
        frame,
        characteristic: PuffinCharacteristic.cmdToStrap,
      );
      lastVibrationStatusNotifier.value = 0x00;
      statusMessageNotifier.value =
          'Comando vibrazione 0x42 inviato con successo (slot $slot).';
      return true;
    }

    final completer = Completer<int>();
    final subscription = transport.incomingFrames
        .where((event) =>
            event.characteristic == PuffinCharacteristic.cmdFromStrap)
        .listen((event) {
      final raw = event.frame.rawPayload;
      if (raw.length >= 4 && raw[0] == 0x24 && raw[2] == 0x42) {
        final status = raw.length >= 5 ? raw[4] : raw[3];
        if (!completer.isCompleted) completer.complete(status);
      }
    });

    try {
      await transport.write(
        frame,
        characteristic: PuffinCharacteristic.cmdToStrap,
      );

      final status = await completer.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () => -1,
      );

      lastVibrationStatusNotifier.value = status >= 0 ? status : null;

      if (status == -1) {
        statusMessageNotifier.value =
            'Comando vibrazione 0x42 inviato, ma nessun ACK 0x24 ricevuto.';
        return false;
      }

      final statusHex = '0x${status.toRadixString(16).padLeft(2, '0').toUpperCase()}';
      final ok = status == 0x00 || status == 0x01;
      statusMessageNotifier.value = ok
          ? 'Vibrazione attivata con successo! Status ACK cinturino: $statusHex'
          : 'Comando vibrazione respinto dal cinturino con status $statusHex';
      return ok;
    } finally {
      await subscription.cancel();
    }
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
      } else if (transport.isConnected && transport is! SimulatedPuffinTransport) {
        return await _syncRealBle();
      } else if (simulateIfNoHardware) {
        return await _syncSimulated(recordCount: simulationRecordCount);
      } else {
        statusNotifier.value = SyncStatus.error;
        statusMessageNotifier.value =
            'Nessun dispositivo WHOOP connesso via BLE reale.';
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
      if (_activeRealSyncCompleter != null && !_activeRealSyncCompleter!.isCompleted) {
        _activeRealSyncCompleter!.complete(recordsSavedNotifier.value);
      }
      statusMessageNotifier.value = 'Interruzione sincronizzazione richiesta...';
    }
  }

  Future<int> _syncRealBle({Duration timeout = const Duration(seconds: 60)}) async {
    statusNotifier.value = SyncStatus.syncing;
    statusMessageNotifier.value = 'Avvio offload storico WHOOP (comando 0x16)...';

    // 1. Invia il comando 0x16 (START_HISTORICAL_OFFLOAD) su CMD_TO_STRAP
    final startSeq = _nextSeq();
    final startCmd = Uint8List.fromList([0x23, startSeq, 0x16, 0x00]);
    final startFrame = PuffinFrameCodec.encode(1, startCmd);
    await transport.write(
      startFrame,
      characteristic: PuffinCharacteristic.cmdToStrap,
    );

    var saved = 0;
    Uint8List? lastCursor;
    final completer = Completer<int>();
    _activeRealSyncCompleter = completer;

    Timer? idleTimer;
    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(const Duration(seconds: 12), () {
        if (!completer.isCompleted) {
          completer.complete(saved);
        }
      });
    }

    resetIdleTimer();

    final subscription = transport.incomingFrames.listen((event) async {
      if (_isCancelled) {
        if (!completer.isCompleted) completer.complete(saved);
        return;
      }

      final frame = event.frame;
      final raw = frame.rawPayload;
      if (raw.isEmpty) return;

      final opcode = raw[0];

      if (opcode == 0x31) {
        // Auto-ACK 0x31 METADATA_CURSOR -> invio 0x17 con cursor 8 byte estratto da bytes 13..20
        if (raw.length >= 21) {
          final cursor = raw.sublist(13, 21);
          if (lastCursor == null || !_bytesEqual(cursor, lastCursor!)) {
            lastCursor = Uint8List.fromList(cursor);
            final ackSeq = _nextSeq();
            final ackPayload = Uint8List.fromList([
              0x23,
              ackSeq,
              0x17, // Opcode ACK_CURSOR
              0x01,
              ...cursor,
            ]);
            final ackFrame = PuffinFrameCodec.encode(1, ackPayload);
            try {
              await transport.write(
                ackFrame,
                characteristic: PuffinCharacteristic.cmdToStrap,
              );
            } catch (_) {}
          }
        }
        resetIdleTimer();
      } else if (opcode == 0x2F && raw.length >= 2 && raw[1] == 0x12) {
        // Record storico v18 (lunghezza standard 112 byte, minimo 108 byte)
        try {
          final record = V18Record.decode(raw);
          await repository.saveV18Record(record, strapSerial);
          saved++;
          recordsSavedNotifier.value = saved;
          lastTimestampNotifier.value = record.timestamp;
          lastHrNotifier.value = record.hrPrimary;
          lastRrNotifier.value = record.rrIntervalsMs;
          lastSkinTempNotifier.value = record.skinTempCelsius;
          final tempStr = record.skinTempCelsius != null
              ? '${record.skinTempCelsius!.toStringAsFixed(1)}°C'
              : 'N/A';
          statusMessageNotifier.value =
              'Scaricati $saved record (Ultimo: ${record.hrPrimary} bpm, '
              '$tempStr, ${record.timestamp.toIso8601String()})...';
          resetIdleTimer();
        } catch (_) {}
      } else if (opcode == 0x28 && raw.length >= 12 && raw[1] == 0x02) {
        // Live28Record (HR compatto live)
        try {
          final live = Live28Record.decode(raw);
          liveHrNotifier.value = live.hr;
          if (live.rrIntervalMs > 0) {
            liveRrNotifier.value = live.rrIntervalMs;
          }
          resetIdleTimer();
        } catch (_) {}
      }
    });

    try {
      final totalSaved = await completer.future.timeout(
        timeout,
        onTimeout: () => saved,
      );
      statusNotifier.value = SyncStatus.completed;
      statusMessageNotifier.value = _isCancelled
          ? 'Sincronizzazione interrotta ($totalSaved salvati).'
          : 'Sincronizzazione completata: $totalSaved record salvati.';
      return totalSaved;
    } finally {
      idleTimer?.cancel();
      _activeRealSyncCompleter = null;
      await subscription.cancel();
    }
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
          lastTimestampNotifier.value = decoded.timestamp;
          lastHrNotifier.value = decoded.hrPrimary;
          lastRrNotifier.value = decoded.rrIntervalsMs;
          lastSkinTempNotifier.value = decoded.skinTempCelsius;
          statusMessageNotifier.value = 'Scaricati $saved record...';
        } else if (decoded is Live28Record) {
          liveHrNotifier.value = decoded.hr;
          if (decoded.rrIntervalMs > 0) {
            liveRrNotifier.value = decoded.rrIntervalMs;
          }
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
      final isDeepSleep = i >= 30 && i < 330;
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
    if (records.isNotEmpty) {
      final last = records.last;
      lastTimestampNotifier.value = last.timestamp;
      lastHrNotifier.value = last.hrPrimary;
      lastRrNotifier.value = last.rrIntervalsMs;
      lastSkinTempNotifier.value = last.skinTempCelsius;
    }
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
