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
    this.timeout = const Duration(seconds: 4),
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

  /// Esegue la sequenza completa di autenticazione con il cinturino.
  Future<void> start({
    void Function(String step)? onProgress,
  }) async {
    if (!transport.isConnected) {
      throw DartPuffinHandshakeException('Trasporto BLE non connesso');
    }

    // 1. Invia 0x91 GET_HELLO (field 0x0100)
    onProgress?.call('Invio HELLO (0x91)...');
    final helloSeq = _nextSeq();
    final helloPayload = Uint8List.fromList([0x23, helloSeq, 0x91, 0x01]);
    await _sendAndAcknowledge(
      payload: helloPayload,
      opcode: 0x91,
      field: 0x0100,
    );
    onProgress?.call('HELLO confermato dal cinturino (LED blu spento).');

    // 2. Lettura del Clock del cinturino (0x0B)
    onProgress?.call('Lettura Clock cinturino (0x0B)...');
    final clockSeq = _nextSeq();
    final readClockPayload = Uint8List.fromList([0x23, clockSeq, 0x0B, 0x00]);
    await _sendAndAcknowledge(
      payload: readClockPayload,
      opcode: 0x0B,
      field: 1,
    );

    // 3. Impostazione del Clock Unix corrente (0x0A)
    onProgress?.call('Allineamento Clock Unix (0x0A)...');
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
    );

    // 4. Scambio chiavi di sessione (0x73 KEY_EXCHANGE) con 32 byte casuali sicuri
    onProgress?.call('Key exchange crittografico (0x73)...');
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
    );

    // 5. Configurazione delle 16 Feature Flags (0x78)
    for (var i = 0; i < defaultFeatureFlags.length; i++) {
      final (name, value) = defaultFeatureFlags[i];
      onProgress?.call('Configurazione flag ${i + 1}/${defaultFeatureFlags.length} ($name)...');

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
        retryOnce: true,
      );
    }

    // 6. Query Range (0x22)
    onProgress?.call('Interrogazione range dati storici (0x22)...');
    final rangeSeq = _nextSeq();
    final rangePayload = Uint8List.fromList([0x23, rangeSeq, 0x22, 0x00]);
    try {
      await _sendAndAcknowledge(
        payload: rangePayload,
        opcode: 0x22,
        field: 1,
      );
    } catch (_) {
      // Alcuni firmware considerano 0x22 come sola notifica o query informativa
    }

    onProgress?.call('Handshake hardware completato con successo!');
  }

  Future<PuffinFrame> _sendAndAcknowledge({
    required Uint8List payload,
    required int opcode,
    required int field,
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
        // La risposta 0x24 ha formato: [0x24, seq, opcode, ..., status]
        if (raw.length >= 4 && raw[0] == 0x24 && raw[2] == opcode) {
          final status = raw.length >= 5 ? raw[4] : raw[3];
          if (status == 0x00 || status == 0x01) {
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
