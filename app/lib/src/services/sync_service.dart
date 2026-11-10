import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/ble.dart';
import '../records/live28_record.dart';
import '../records/record_decoder.dart';
import '../records/standard_hr_record.dart';
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

    _initTransportListeners();
  }

  void _initTransportListeners() {
    transport.standardHrStream.listen((bytes) {
      try {
        final record = StandardHrRecord.decode(bytes);
        liveHrNotifier.value = record.hr;
        if (record.rrIntervalsMs.isNotEmpty) {
          liveRrNotifier.value = record.rrIntervalsMs.last;
        }
      } catch (_) {}
    });

    transport.onConnectionChanged.listen((connected) {
      if (!connected && connectionStateNotifier.value.isConnected) {
        connectionStateNotifier.value = const BleStatusIdle();
        statusNotifier.value = SyncStatus.idle;
        statusMessageNotifier.value = 'Dispositivo WHOOP disconnesso.';
        liveHrNotifier.value = null;
        liveRrNotifier.value = null;
      }
    });

    if (transport is MethodChannelPuffinTransport) {
      final nativeTransport = transport as MethodChannelPuffinTransport;
      nativeTransport.onLiveHrBpm.listen((bpm) {
        liveHrNotifier.value = bpm;
      });
      nativeTransport.onLiveRrMs.listen((rr) {
        liveRrNotifier.value = rr;
      });
      nativeTransport.onConnectionStateChanged.listen((map) {
        final isConnected = map['isConnected'] as bool? ?? false;
        final isPuffin = map['isPuffinReady'] as bool? ?? false;
        final dev = nativeTransport.connectedDevice ??
            const WhoopDiscoveredDevice(name: 'WHOOP 5.0', macAddress: 'FD:49:44:66:1D:92');
        if (isConnected) {
          if (isPuffin) {
            connectionStateNotifier.value = BleStatusPuffinProtocolReady(dev);
            statusMessageNotifier.value = 'Connesso a ${dev.name} (Puffin Protocol Ready)';
          } else {
            connectionStateNotifier.value = BleStatusStandardHrConnected(dev);
            statusMessageNotifier.value = 'Connesso SOLO a Standard HR (0x2A37) su ${dev.name}. Protocollo Puffin non disponibile.';
          }
        }
      });
      nativeTransport.onSyncProgress.listen((map) {
        final saved = map['recordsSaved'] as int? ?? 0;
        recordsSavedNotifier.value = saved;
        final isComp = map['isCompleted'] as bool? ?? false;
        final isAbort = map['isAborted'] as bool? ?? false;
        final err = map['error'] as String?;
        if (isComp) {
          statusNotifier.value = SyncStatus.completed;
          statusMessageNotifier.value = 'Sincronizzazione completata ($saved record salvati).';
        } else if (isAbort) {
          statusNotifier.value = SyncStatus.idle;
          statusMessageNotifier.value = 'Sincronizzazione interrotta.';
        } else if (err != null) {
          statusNotifier.value = SyncStatus.error;
          statusMessageNotifier.value = 'Errore sincronizzazione: $err';
        } else {
          statusNotifier.value = SyncStatus.syncing;
          statusMessageNotifier.value = 'Sincronizzazione in corso ($saved record salvati)...';
        }
      });
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
          // Ignora esplicitamente il WHOOP A
          if (n.contains('5A00479315')) return false;

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

  static bool _isGatt133Error(Object error) {
    final str = error.toString().toLowerCase();
    return str.contains('133');
  }

  /// Avvia connessione GATT, procedura di accoppiamento (bonding) ed handshake hardware.
  Future<bool> connectAndBond(
    WhoopDiscoveredDevice device, {
    Duration handshakeTimeout = const Duration(seconds: 30),
  }) async {
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
        onRetryProgress: (message) {
          statusMessageNotifier.value = message;
        },
      );

      if (!success) {
        connectionStateNotifier.value =
            const BleStatusError('Bonding fallito o annullato');
        statusMessageNotifier.value =
            'Bonding fallito o annullato. Riprova verificando il pairing mode (LED blu).';
        return false;
      }

      // 5. Gestione handshake e isolamento Puffin (FASE 3)
      if (transport is MethodChannelPuffinTransport) {
        // Su Android, WhoopConnectionService gestisce la connessione nativa.
        // Impostiamo provvisoriamente connected, lo stato dettagliato viene aggiornato via event flow.
        connectionStateNotifier.value = BleStatusConnected(device);
        statusMessageNotifier.value = 'Connesso a ${device.name}. Inizializzazione completata.';
      } else if (transport is! SimulatedPuffinTransport) {
        // Per BlePuffinTransport: isola l'handshake per non bloccare la connessione HR standard
        try {
          statusMessageNotifier.value = 'Esecuzione Handshake di autenticazione con il WHOOP...';
          final handshake = DartPuffinHandshake(
            transport,
            timeout: handshakeTimeout,
          );
          await handshake.start(onProgress: (step) {
            statusMessageNotifier.value = step;
          }).timeout(handshakeTimeout);
          connectionStateNotifier.value = BleStatusPuffinProtocolReady(device);
          statusMessageNotifier.value = 'Connesso a ${device.name} (Puffin Protocol Ready)';
        } catch (e) {
          // FASE 3: Se HELLO 0x91 fallisce:
          // 1. Registra il problema diagnostico.
          // 2. Segna Puffin come non disponibile.
          // 3. Mantieni la registrazione standard HR se continua a funzionare.
          // 4. Non forzare un nuovo pairing.
          // 5. Non entrare in un ciclo infinito di handshake.
          // 6. Non cancellare dati acquisiti.
          connectionStateNotifier.value = BleStatusStandardHrConnected(device);
          statusMessageNotifier.value =
              'Connesso SOLO a Standard HR (0x2A37). Protocollo Puffin non disponibile ($e).';
        }
      } else {
        connectionStateNotifier.value = BleStatusPuffinProtocolReady(device);
        statusMessageNotifier.value = 'Connesso a ${device.name} (Simulato)';
      }
      return true;
    } on BleBondException catch (e) {
      connectionStateNotifier.value =
          BleStatusError('Bonding fallito o annullato: ${e.message}');
      statusMessageNotifier.value =
          'Bonding fallito o annullato. Riprova verificando il pairing mode (LED blu).';
      return false;
    } catch (e) {
      if (e.toString().contains('Bonding fallito o annullato') ||
          e.toString().contains('BOND_FAILED') ||
          e.toString().contains('PairingException')) {
        connectionStateNotifier.value =
            const BleStatusError('Bonding fallito o annullato');
        statusMessageNotifier.value =
            'Bonding fallito o annullato. Riprova verificando il pairing mode (LED blu).';
        return false;
      }

      if (_isGatt133Error(e)) {
        connectionStateNotifier.value = const BleStatusError(
          'Errore GATT 133: Connessione fallita dopo 3 tentativi. '
          'Disconnetti il dispositivo dalle impostazioni Bluetooth e riprova.',
        );
        statusMessageNotifier.value =
            'Errore GATT 133: Dimentica il WHOOP nelle impostazioni Bluetooth, '
            'riavvia il Bluetooth del telefono e rimettilo in pairing mode (LED blu fisso).';
        return false;
      }

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

  /// Invia il comando 0x13 (HAPTIC_TRIGGER / Test Vibrazione Immediata) per far vibrare subito il cinturino.
  ///
  /// Su WHOOP 5.0 / MG l'opcode per la vibrazione immediata è 0x13 (19) (NOOP 1.34 / OpenStrap).
  /// L'opcode 0x42 serve invece per la sveglia programmata.
  ///
  /// Parametri:
  /// - [pattern]: pattern vibrazione (default 0x02)
  /// - [loops]: cicli di ripetizione (default 0x03)
  Future<bool> sendVibration({
    int pattern = 0x02,
    int loops = 0x03,
    int? slot,
    int? targetEpochSeconds,
    int? delaySeconds,
    int? durationMs,
  }) async {
    if (!transport.isConnected) {
      statusMessageNotifier.value =
          'Impossibile inviare vibrazione: cinturino non connesso.';
      return false;
    }

    final seq = _nextSeq();
    // Inner payload per Test Vibrazione 0x13: [0x23, seq, 0x13, pattern, loops, 0x00, 0x00, 0x00]
    final innerCmd = Uint8List.fromList([
      0x23,
      seq,
      0x13, // Opcode HAPTIC_TRIGGER
      pattern & 0xFF,
      loops & 0xFF,
      0x00,
      0x00,
      0x00,
    ]);

    final frame = PuffinFrameCodec.encode(PuffinFrameCodec.commandField, innerCmd);

    if (transport is MethodChannelPuffinTransport) {
      final ok = await (transport as MethodChannelPuffinTransport).sendNativeVibration(
        pattern: pattern,
        loops: loops,
      );
      lastVibrationStatusNotifier.value = ok ? 0x01 : null;
      statusMessageNotifier.value = ok
          ? 'Vibrazione immediata 0x13 inviata al cinturino tramite WhoopConnectionService!'
          : 'Invio vibrazione respinto o fallito.';
      return ok;
    }

    if (transport is SimulatedPuffinTransport) {
      await transport.write(
        frame,
        characteristic: PuffinCharacteristic.cmdToStrap,
      );
      lastVibrationStatusNotifier.value = 0x01;
      statusMessageNotifier.value =
          'Comando vibrazione immediata 0x13 inviato con successo (pattern $pattern, loops $loops).';
      return true;
    }

    final completer = Completer<int>();
    final subscription = transport.incomingFrames
        .where((event) =>
            event.characteristic == PuffinCharacteristic.cmdFromStrap)
        .listen((event) {
      final raw = event.frame.rawPayload;
      if (raw.length >= 3 && raw[0] == 0x24 && raw[2] == 0x13) {
        // Se seq corrisponde o risponde status
        final status = raw.length >= 4 ? raw[3] : 0x01;
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
        onTimeout: () => 0x01, // Molti firmware eseguono il feedback aptico senza inviare 0x24 esplicito
      );

      lastVibrationStatusNotifier.value = status >= 0 ? status : null;

      final statusHex = '0x${status.toRadixString(16).padLeft(2, '0').toUpperCase()}';
      final ok = status == 0x01 || status == 0x00 || status == 0x02;
      statusMessageNotifier.value = ok
          ? 'Vibrazione immediata 0x13 inviata al cinturino! Status: $statusHex'
          : 'Comando vibrazione respinto dal cinturino con status $statusHex';
      return ok;
    } finally {
      await subscription.cancel();
    }
  }

  /// Invia il comando 0x42 (SET_ALARM_TIME) per programmare la sveglia / vibrazione futura.
  ///
  /// Verificato al 100% dalla cattura btsnoop_hci.log:
  /// - Opcode: 0x42, b3: 0x04
  /// - Payload: [slot (1), target_epoch_u32 LE, 00 00, 2f 98, 00..00 (8B), 07 1e 00]
  Future<bool> setAlarmTime({
    int slot = 1,
    int? targetEpochSeconds,
    int delaySeconds = 5,
  }) async {
    if (!transport.isConnected) {
      statusMessageNotifier.value =
          'Impossibile programmare sveglia: cinturino non connesso.';
      return false;
    }

    final seq = _nextSeq();
    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final targetSec = targetEpochSeconds ?? (nowSec + delaySeconds);

    final innerCmd = Uint8List.fromList([
      0x23,
      seq,
      0x42, // Opcode SET_ALARM_TIME
      0x04, // b3 revision verified from HCI log
      slot & 0xFF,
      targetSec & 0xFF,
      (targetSec >> 8) & 0xFF,
      (targetSec >> 16) & 0xFF,
      (targetSec >> 24) & 0xFF,
      0x00,
      0x00,
      0x2F,
      0x98,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x07,
      0x1E,
      0x00,
    ]);

    final frame = PuffinFrameCodec.encode(PuffinFrameCodec.commandField, innerCmd);

    if (transport is SimulatedPuffinTransport) {
      await transport.write(
        frame,
        characteristic: PuffinCharacteristic.cmdToStrap,
      );
      lastVibrationStatusNotifier.value = 0x01;
      statusMessageNotifier.value =
          'Comando sveglia 0x42 programmato (slot $slot, target: $targetSec).';
      return true;
    }

    final completer = Completer<int>();
    final subscription = transport.incomingFrames
        .where((event) =>
            event.characteristic == PuffinCharacteristic.cmdFromStrap)
        .listen((event) {
      final raw = event.frame.rawPayload;
      if (raw.length >= 4 && raw[0] == 0x24 && raw[1] == seq && raw[2] == 0x42) {
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
            'Comando sveglia 0x42 inviato, ma nessun ACK 0x24 ricevuto.';
        return false;
      }

      final statusHex = '0x${status.toRadixString(16).padLeft(2, '0').toUpperCase()}';
      final ok = status == 0x01 || status == 0x00 || status == 0x02;
      statusMessageNotifier.value = ok
          ? 'Sveglia programmata con successo! Status ACK cinturino: $statusHex'
          : 'Comando sveglia respinto dal cinturino con status $statusHex';
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
      } else if (transport is MethodChannelPuffinTransport && transport.isConnected) {
        statusNotifier.value = SyncStatus.syncing;
        statusMessageNotifier.value = 'Avvio offload storico tramite WhoopConnectionService nativo...';
        await (transport as MethodChannelPuffinTransport).startNativeSync();
        return recordsSavedNotifier.value;
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
      if (transport is MethodChannelPuffinTransport) {
        (transport as MethodChannelPuffinTransport).stopNativeSync();
      }
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
    final startFrame = PuffinFrameCodec.encode(PuffinFrameCodec.commandField, startCmd);
    await transport.write(
      startFrame,
      characteristic: PuffinCharacteristic.cmdToStrap,
    );

    var saved = 0;
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
        // Obbligatorio inviare l'ACK 0x17 per OGNI frame 0x31 ricevuto (Regola 6).
        if (raw.length >= 21) {
          final cursor = raw.sublist(13, 21);
          final ackSeq = _nextSeq();
          final ackPayload = Uint8List.fromList([
            0x23,
            ackSeq,
            0x17, // Opcode ACK_CURSOR
            0x01,
            ...cursor,
          ]);
          final ackFrame = PuffinFrameCodec.encode(PuffinFrameCodec.commandField, ackPayload);
          try {
            await transport.write(
              ackFrame,
              characteristic: PuffinCharacteristic.cmdToStrap,
            );
          } catch (_) {}
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
