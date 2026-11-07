import 'dart:typed_data';

import 'crc.dart';

/// Eccezioni sollevate durante la codifica o decodifica dei frame Puffin.
class PuffinFrameException implements Exception {
  PuffinFrameException(this.message);
  final String message;

  @override
  String toString() => 'PuffinFrameException: $message';
}

/// Rappresentazione strutturata di un frame Puffin decodificato e verificato.
class PuffinFrame {
  const PuffinFrame({
    required this.field,
    required this.payload,
    required this.rawPayload,
    required this.headerCRC,
    required this.payloadCRC,
  });

  /// Identificatore del campo/servizio Puffin (u16).
  final int field;

  /// Payload privo di padding a zero finale.
  final Uint8List payload;

  /// Payload grezzo completo (inclusi eventuali byte di padding a 4 byte).
  final Uint8List rawPayload;

  /// Checksum CRC16 Modbus verificato dell'header.
  final int headerCRC;

  /// Checksum CRC32 IEEE 802.3 verificato del payload.
  final int payloadCRC;
}

/// Codec binario per l'envelope custom del WHOOP 5.0 (Puffin Gen 5).
///
/// Struttura:
/// - Header (8 byte): `[0xAA, 0x01, len_u16, field_u16, crc16_u16]`
/// - Payload paddato: multiplo di 4 byte (minimo 4 byte)
/// - Trailer (4 byte): `crc32_u32` (IEEE 802.3 su payload paddato)
class PuffinFrameCodec {
  PuffinFrameCodec._();

  static const int headerSize = 8;
  static const Set<int> blockedOpcodes = {0x19, 0x1D};

  /// Legge un intero a 16 bit unsigned in ordine little-endian.
  static int readU16(Uint8List bytes, int offset) => _readU16(bytes, offset);

  /// Codifica un comando o payload nel frame binario conforme al protocollo.
  static Uint8List encode(int field, Uint8List payload) {
    if (payload.isEmpty) {
      throw PuffinFrameException('Il payload non può essere vuoto (minimo 16 byte su cavo)');
    }

    // Regola di sicurezza: MAI inviare comandi distruttivi (0x19 ERASE, 0x1D REBOOT)
    if (payload.length >= 3 && payload[0] == 0x23) {
      final opcode = payload[2];
      if (blockedOpcodes.contains(opcode)) {
        throw ArgumentError(
          'CRITICAL SAFETY VIOLATION: Opcode 0x${opcode.toRadixString(16).padLeft(2, '0')} '
          'bloccato per prevenire bricking o cancellazione del dispositivo.',
        );
      }
    }

    final padLen = (4 - (payload.length % 4)) % 4;
    final paddedLength = payload.length + padLen;
    final payloadLength = paddedLength + 4; // Include 4 byte di CRC32 trailer

    if (headerSize + payloadLength < 16) {
      throw PuffinFrameException('Frame troppo corto (minimo 16 byte)');
    }

    final rawPayload = Uint8List(paddedLength);
    rawPayload.setRange(0, payload.length, payload);

    final frame = Uint8List(headerSize + payloadLength);
    frame[0] = 0xAA;
    frame[1] = 0x01;
    _putU16(frame, 2, payloadLength);
    _putU16(frame, 4, field);

    final headerCrc = CRC.crc16Modbus(Uint8List.sublistView(frame, 0, 6));
    _putU16(frame, 6, headerCrc);

    frame.setRange(headerSize, headerSize + paddedLength, rawPayload);

    final trailerCrc = CRC.crc32IEEE(rawPayload);
    _putU32(frame, headerSize + paddedLength, trailerCrc);

    return frame;
  }

  /// Decodifica e verifica un frame Puffin ricevuto.
  static Uint8List decode(Uint8List frame) {
    if (frame.length < 16) {
      throw PuffinFrameException('Frame troppo corto: ${frame.length} byte');
    }
    if (frame[0] != 0xAA || frame[1] != 0x01) {
      throw PuffinFrameException('SOF o versione non validi: 0x${frame[0].toRadixString(16)}, 0x${frame[1].toRadixString(16)}');
    }

    final payloadLength = _readU16(frame, 2);
    if (frame.length != headerSize + payloadLength) {
      throw PuffinFrameException('Lunghezza frame incoerente con l\'header: ${frame.length} != ${headerSize + payloadLength}');
    }

    final expectedHeaderCrc = CRC.crc16Modbus(Uint8List.sublistView(frame, 0, 6));
    final actualHeaderCrc = _readU16(frame, 6);
    if (expectedHeaderCrc != actualHeaderCrc) {
      throw PuffinFrameException('CRC16 header non valido: atteso $expectedHeaderCrc, ottenuto $actualHeaderCrc');
    }

    final paddedLength = payloadLength - 4;
    final rawPayload = Uint8List.sublistView(frame, headerSize, headerSize + paddedLength);
    final expectedTrailerCrc = CRC.crc32IEEE(rawPayload);
    final actualTrailerCrc = _readU32(frame, headerSize + paddedLength);
    if (expectedTrailerCrc != actualTrailerCrc) {
      throw PuffinFrameException('CRC32 payload non valido');
    }

    return rawPayload;
  }

  /// Decodifica e restituisce un [PuffinFrame] completo verificando header e trailer.
  static PuffinFrame decodeFrame(Uint8List frame) {
    if (frame.length < 16) {
      throw PuffinFrameException('Frame troppo corto: ${frame.length} byte');
    }
    if (frame[0] != 0xAA || frame[1] != 0x01) {
      throw PuffinFrameException(
        'SOF o versione non validi: 0x${frame[0].toRadixString(16)}, 0x${frame[1].toRadixString(16)}',
      );
    }

    final payloadLength = _readU16(frame, 2);
    if (payloadLength < 4 || payloadLength % 4 != 0) {
      throw PuffinFrameException('payloadLen non valido: $payloadLength');
    }
    if (frame.length != headerSize + payloadLength) {
      throw PuffinFrameException(
        'Lunghezza frame incoerente con l\'header: ${frame.length} != ${headerSize + payloadLength}',
      );
    }

    final expectedHeaderCrc = CRC.crc16Modbus(Uint8List.sublistView(frame, 0, 6));
    final actualHeaderCrc = _readU16(frame, 6);
    if (expectedHeaderCrc != actualHeaderCrc) {
      throw PuffinFrameException(
        'CRC16 header non valido: atteso $expectedHeaderCrc, ottenuto $actualHeaderCrc',
      );
    }

    final paddedLength = payloadLength - 4;
    final rawPayload = Uint8List.sublistView(frame, headerSize, headerSize + paddedLength);
    final expectedTrailerCrc = CRC.crc32IEEE(rawPayload);
    final actualTrailerCrc = _readU32(frame, headerSize + paddedLength);
    if (expectedTrailerCrc != actualTrailerCrc) {
      throw PuffinFrameException('CRC32 payload non valido');
    }

    var logicalLength = rawPayload.length;
    while (logicalLength > 0 && rawPayload[logicalLength - 1] == 0) {
      logicalLength--;
    }
    final strippedPayload = Uint8List.fromList(
      rawPayload.sublist(0, logicalLength),
    );

    return PuffinFrame(
      field: _readU16(frame, 4),
      payload: strippedPayload,
      rawPayload: Uint8List.fromList(rawPayload),
      headerCRC: actualHeaderCrc,
      payloadCRC: actualTrailerCrc,
    );
  }

  static void _putU16(Uint8List bytes, int offset, int value) {
    bytes[offset] = value & 0xFF;
    bytes[offset + 1] = (value >> 8) & 0xFF;
  }

  static int _readU16(Uint8List bytes, int offset) {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  static void _putU32(Uint8List bytes, int offset, int value) {
    bytes[offset] = value & 0xFF;
    bytes[offset + 1] = (value >> 8) & 0xFF;
    bytes[offset + 2] = (value >> 16) & 0xFF;
    bytes[offset + 3] = (value >> 24) & 0xFF;
  }

  static int _readU32(Uint8List bytes, int offset) {
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }
}

/// Riassemblatore di stream a pacchetti frammentati per il protocollo Puffin Gen 5.
class PuffinFrameReassembler {
  Uint8List _buffer = Uint8List(0);

  /// Resetta il buffer interno dei chunk incompleti.
  void reset() {
    _buffer = Uint8List(0);
  }

  /// Alimenta il riassemblatore con un chunk grezzo ricevuto via BLE notify
  /// ed estrae tutti i frame completi e verificati.
  List<PuffinFrame> feed(Uint8List chunk) {
    if (chunk.isEmpty) return const [];
    final builder = BytesBuilder(copy: false);
    builder.add(_buffer);
    builder.add(chunk);
    _buffer = builder.toBytes();

    final frames = <PuffinFrame>[];
    while (true) {
      final start = _findSof(_buffer);
      if (start < 0) {
        _buffer = _buffer.isNotEmpty && _buffer.last == 0xAA
            ? Uint8List.fromList([0xAA])
            : Uint8List(0);
        break;
      }
      if (start > 0) {
        _buffer = Uint8List.sublistView(_buffer, start);
      }
      if (_buffer.length < 2) break;
      if (_buffer[1] != 0x01) {
        _discardSof();
        continue;
      }
      if (_buffer.length < 8) break;

      final payloadLength = PuffinFrameCodec.readU16(_buffer, 2);
      if (payloadLength < 4 || payloadLength % 4 != 0) {
        _discardSof();
        continue;
      }
      final headerCrc = CRC.crc16Modbus(Uint8List.sublistView(_buffer, 0, 6));
      if (headerCrc != PuffinFrameCodec.readU16(_buffer, 6)) {
        _discardSof();
        continue;
      }

      final totalLength = 8 + payloadLength;
      if (totalLength <= 15) {
        _discardSof();
        continue;
      }
      if (_buffer.length < totalLength) break;

      final candidate = Uint8List.sublistView(_buffer, 0, totalLength);
      try {
        final frame = PuffinFrameCodec.decodeFrame(candidate);
        frames.add(frame);
        _buffer = Uint8List.sublistView(_buffer, totalLength);
      } on PuffinFrameException {
        // Fallimento checksum payload: scarta il SOF e riparte
        _discardSof();
      }
    }
    return frames;
  }

  void _discardSof() {
    if (_buffer.isNotEmpty) {
      _buffer = Uint8List.sublistView(_buffer, 1);
    }
  }

  static int _findSof(Uint8List bytes) {
    for (var i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0xAA && bytes[i + 1] == 0x01) {
        return i;
      }
    }
    return -1;
  }
}
