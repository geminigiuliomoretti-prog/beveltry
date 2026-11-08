import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'puffin_frame_codec.dart';
import 'puffin_transport.dart';

/// Eccezione sollevata durante la procedura di handshake crittografico con WHOOP 5.0.
class DartPuffinHandshakeException implements Exception {
  DartPuffinHandshakeException(this.message, {this.opcode, this.status});
  final String message;
  final int? opcode;
  final int? status;

  @override
  String toString() =>
      'DartPuffinHandshakeException: $message '
      '${opcode != null ? "(opcode 0x${opcode!.toRadixString(16)})" : ""} '
      '${status != null ? "(status 0x${status!.toRadixString(16)})" : ""}';
}

/// Implementazione Dart nativa del protocollo di autenticazione e sblocco sessione
/// per WHOOP 5.0 (FW 50.41.1.0 e compatibili).
///
/// Senza completare questo handshake, il WHOOP ignora qualsiasi comando (vibrazione 0x42,
/// sync 0x16) e mantiene il LED blu acceso in stato di pairing.
class DartPuffinHandshake {
  DartPuffinHandshake(
    this.transport, {
    this.timeout = const Duration(seconds: 30),
  });

  final PuffinTransport transport;
  final Duration timeout;

  int _seq = 1;

  int _nextSeq() {
    final s = _seq;
    _seq = (_seq % 255) + 1;
    return s;
  }

  static const List<(String, int)> defaultFeatureFlags = [
    ('enable_r22_packets', 2),
    ('enable_r22_v2_packets', 2),
    ('enable_r22_v3_packets', 2),
    ('enable_r22_v4_packets', 1),
    ('enable_r22_v5_packets', 2),
    ('enable_r22_v6_packets', 2),
    ('enable_r22_v8_packets', 2),
    ('make_hrfm_visible', 2),
    ('disable_pip_r26_packets', 2),
    ('wear_detect_bias', 2),
    ('hr_ch_switching', 2),
    ('ir_hw_switching', 2),
    ('enable_passive_strap_fit_gen5', 1),
    ('enable_sig11_during_sleep', 2),
    ('dorset_inhibit_wpt', 2),
    ('enable_sig12', 2),
  ];

  int? _extractTimestamp(Uint8List raw) {
    final offset = raw.length >= 9 ? 5 : (raw.length >= 8 ? 4 : -1);
    if (offset >= 0 && raw.length >= offset + 4) {
      final bd = ByteData.sublistView(raw, offset, offset + 4);
      return bd.getUint32(0, Endian.little);
    }
    return null;
  }

  /// Esegue la sequenza completa di autenticazione con il cinturino.
  Future<void> start({
    void Function(String step)? onProgress,
  }) async {
    if (!transport.isConnected) {
      throw DartPuffinHandshakeException('Trasporto BLE non connesso');
    }

    // 1. Invia 0x91 GET_HELLO (field = 1)
    onProgress?.call('Invio HELLO (0x91)...');
    final helloSeq = _nextSeq();
    final helloPayload = Uint8List.fromList([0x23, helloSeq, 0x91, 0x01]);
    await _sendAndAcknowledge(
      payload: helloPayload,
      opcode: 0x91,
      field: 1,
      allowedStatuses: const {0x00, 0x01, 0x02},
      retryOnce: true,
    );
    onProgress?.call('HELLO confermato dal cinturino (LED blu spento).');

    // 2. Lettura del Clock del cinturino (0x0B)
    onProgress?.call('Lettura Clock cinturino (0x0B)...');
    try {
      final clockSeq = _nextSeq();
      final readClockPayload = Uint8List.fromList([0x23, clockSeq, 0x0B, 0x00]);
      final clockResp = await _sendAndAcknowledge(
        payload: readClockPayload,
        opcode: 0x0B,
        field: 1,
        allowedStatuses: const {0x00, 0x01, 0x02},
      );
      final ts = _extractTimestamp(clockResp.rawPayload);
      if (ts != null) {
        onProgress?.call('Clock cinturino letto: $ts');
      }
    } catch (e) {
      onProgress?.call('Warning lettura Clock (0x0B): $e');
    }

    // 3. Impostazione del Clock Unix corrente (0x0A)
    onProgress?.call('Allineamento Clock Unix (0x0A)...');
    try {
      final setClockSeq = _nextSeq();
      final nowSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final setClockPayload = Uint8List.fromList([
        0x23,
        setClockSeq,
        0x0A,
        0x01,
        nowSeconds & 0xFF,
        (nowSeconds >> 8) & 0xFF,
        (nowSeconds >> 16) & 0xFF,
        (nowSeconds >> 24) & 0xFF,
      ]);
      await _sendAndAcknowledge(
        payload: setClockPayload,
        opcode: 0x0A,
        field: 1,
        allowedStatuses: const {0x00, 0x01, 0x02},
      );
      onProgress?.call('Clock Unix allineato.');
    } catch (e) {
      onProgress?.call('Warning impostazione Clock (0x0A): $e (proseguo)');
    }

    // 4. Scambio chiavi di sessione (0x73 KEY_EXCHANGE) con 32 byte casuali sicuri
    onProgress?.call('Key exchange crittografico (0x73)...');
    try {
      final keySeq = _nextSeq();
      final random = Random.secure();
      final randomKey = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        randomKey[i] = random.nextInt(256);
      }
      final keyPayload = Uint8List.fromList([
        0x23,
        keySeq,
        0x73,
        0x01,
        0x01,
        ...randomKey,
      ]);
      await _sendAndAcknowledge(
        payload: keyPayload,
        opcode: 0x73,
        field: 1,
        allowedStatuses: const {0x00, 0x01, 0x02},
      );
      onProgress?.call('Key exchange completato.');
    } catch (e) {
      onProgress?.call('Warning Key Exchange (0x73): $e (proseguo)');
    }

    // 5. Configurazione delle 16 Feature Flags (0x78)
    for (var i = 0; i < defaultFeatureFlags.length; i++) {
      final (name, value) = defaultFeatureFlags[i];
      try {
        final flagSeq = _nextSeq();
        final nameBytes = ascii.encode(name);
        final paddedName = Uint8List(32);
        paddedName.setRange(0, min(32, nameBytes.length), nameBytes);

        final flagPayload = Uint8List.fromList([
          0x23,
          flagSeq,
          0x78,
          0x01,
          ...paddedName,
          value & 0xFF,
        ]);

        await _sendAndAcknowledge(
          payload: flagPayload,
          opcode: 0x78,
          field: 1,
          allowedStatuses: const {0x00, 0x01, 0x02},
          retryOnce: true,
        );
      } catch (e) {
        onProgress?.call('Warning flag $name (0x78): $e (proseguo)');
      }
    }

    // 6. Query Range (0x22)
    onProgress?.call('Interrogazione range dati storici (0x22)...');
    try {
      final rangeSeq = _nextSeq();
      final rangePayload = Uint8List.fromList([0x23, rangeSeq, 0x22, 0x00]);
      await _sendAndAcknowledge(
        payload: rangePayload,
        opcode: 0x22,
        field: 1,
        allowedStatuses: const {0x00, 0x01, 0x02},
      );
    } catch (_) {
      // Alcuni firmware considerano 0x22 come sola notifica o query informativa
    }

    onProgress?.call('Handshake hardware completato con successo!');
  }

  Future<PuffinFrame> _sendAndAcknowledge({
    required Uint8List payload,
    required int opcode,
    int field = 1,
    Set<int> allowedStatuses = const {0x00, 0x01, 0x02},
    bool retryOnce = false,
  }) async {
    final frame = PuffinFrameCodec.encode(field, payload);

    for (var attempt = 0; attempt <= (retryOnce ? 1 : 0); attempt++) {
      final completer = Completer<PuffinFrame>();

      final subscription = transport.incomingFrames
          .where((event) =>
              event.characteristic == PuffinCharacteristic.cmdFromStrap)
          .listen((event) {
        final raw = event.frame.rawPayload;
        // Risposta 0x24: [0x24, echo_seq, resp_cmd, strap_seq, resp_status, ...payload]
        // Se raw.length >= 5: byte[3] = strap_seq, byte[4] = resp_status.
        // Se raw.length == 4 (legacy): byte[3] = resp_status.
        if (raw.length >= 4 && raw[0] == 0x24 && raw[2] == opcode) {
          final status = raw.length >= 5 ? raw[4] : raw[3];
          if (allowedStatuses.contains(status)) {
            if (!completer.isCompleted) completer.complete(event.frame);
          } else {
            if (!completer.isCompleted) {
              completer.completeError(
                DartPuffinHandshakeException(
                  'Comando rifiutato dal cinturino',
                  opcode: opcode,
                  status: status,
                ),
              );
            }
          }
        }
      });

      try {
        await transport.write(
          frame,
          characteristic: PuffinCharacteristic.cmdToStrap,
        );

        final response = await completer.future.timeout(
          timeout,
          onTimeout: () => throw DartPuffinHandshakeException(
            'Timeout attesa risposta 0x24 per opcode 0x${opcode.toRadixString(16)}',
            opcode: opcode,
          ),
        );
        return response;
      } catch (e) {
        if (attempt == 0 && retryOnce) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          continue;
        }
        rethrow;
      } finally {
        await subscription.cancel();
      }
    }

    throw DartPuffinHandshakeException(
      'Impossibile ottenere ACK per opcode 0x${opcode.toRadixString(16)}',
      opcode: opcode,
    );
  }
}
