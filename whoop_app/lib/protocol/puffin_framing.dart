import 'dart:typed_data';

/// CRC-16 Modbus (Polynomial 0xA001, Initial 0xFFFF).
int calcCrc16Modbus(Uint8List data) {
  int crc = 0xFFFF;
  for (int b in data) {
    crc ^= (b & 0xFF);
    for (int i = 0; i < 8; i++) {
      if ((crc & 1) != 0) {
        crc = (crc >> 1) ^ 0xA001;
      } else {
        crc = crc >> 1;
      }
    }
  }
  return crc & 0xFFFF;
}

/// CRC-32 IEEE 802.3 standard (Polynomial 0xEDB88320).
int calcCrc32Ieee(Uint8List data) {
  int crc = 0xFFFFFFFF;
  for (int b in data) {
    crc ^= (b & 0xFF);
    for (int i = 0; i < 8; i++) {
      if ((crc & 1) != 0) {
        crc = (crc >>> 1) ^ 0xEDB88320;
      } else {
        crc = crc >>> 1;
      }
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Builds a valid Puffin Gen 5 binary envelope (FW 50.41.1.0).
/// Header len_u16 = paddedInnerLen + 4 (includes 4-byte CRC32 trailer).
Uint8List buildPuffinFrame(Uint8List innerPayload, {int field = 0x0001}) {
  int innerLen = innerPayload.length;
  int padLen = (4 - (innerLen % 4)) % 4;
  if (innerLen + padLen < 4) {
    padLen = 4 - innerLen;
  }
  int paddedInnerLen = innerLen + padLen;
  int wireLenField = paddedInnerLen + 4; // Includes 4-byte CRC32

  // Header 8 bytes
  Uint8List header = Uint8List(8);
  header[0] = 0xAA;
  header[1] = 0x01;
  header[2] = wireLenField & 0xFF;
  header[3] = (wireLenField >> 8) & 0xFF;
  header[4] = field & 0xFF;
  header[5] = (field >> 8) & 0xFF;

  int crc16 = calcCrc16Modbus(header.sublist(0, 6));
  header[6] = crc16 & 0xFF;
  header[7] = (crc16 >> 8) & 0xFF;

  // Padded inner
  Uint8List paddedInner = Uint8List(paddedInnerLen);
  paddedInner.setRange(0, innerLen, innerPayload);

  // CRC32 is computed over paddedInner ONLY (or header+paddedInner depending on FW;
  // in FW 50.41.1.0 CRC32 is over paddedInner)
  int crc32 = calcCrc32Ieee(paddedInner);

  // Full Frame (8 + paddedInnerLen + 4)
  Uint8List fullFrame = Uint8List(8 + paddedInnerLen + 4);
  fullFrame.setRange(0, 8, header);
  fullFrame.setRange(8, 8 + paddedInnerLen, paddedInner);
  int cOff = 8 + paddedInnerLen;
  fullFrame[cOff] = crc32 & 0xFF;
  fullFrame[cOff + 1] = (crc32 >> 8) & 0xFF;
  fullFrame[cOff + 2] = (crc32 >> 16) & 0xFF;
  fullFrame[cOff + 3] = (crc32 >> 24) & 0xFF;

  return fullFrame;
}

/// Extracts the raw inner payload (without header and 4-byte CRC32 trailer).
Uint8List extractInnerPayload(Uint8List frame) {
  if (frame.length < 12) {
    return frame;
  }
  if (frame[0] != 0xAA || frame[1] != 0x01) {
    return frame;
  }
  return frame.sublist(8, frame.length - 4);
}

/// Anti-fragmentation streaming reassembler for incoming BLE notifications.
class PuffinStreamReassembler {
  final List<int> _buffer = [];

  List<Uint8List> feed(Uint8List chunk) {
    _buffer.addAll(chunk);
    List<Uint8List> frames = [];

    while (true) {
      if (_buffer.length < 8) break;

      // Look for sync header 0xAA 0x01
      int syncIdx = -1;
      for (int i = 0; i <= _buffer.length - 2; i++) {
        if (_buffer[i] == 0xAA && _buffer[i + 1] == 0x01) {
          syncIdx = i;
          break;
        }
      }

      if (syncIdx == -1) {
        int lastByte = _buffer.isNotEmpty ? _buffer.last : 0;
        _buffer.clear();
        if (lastByte == 0xAA) _buffer.add(lastByte);
        break;
      }

      if (syncIdx > 0) {
        _buffer.removeRange(0, syncIdx);
      }

      if (_buffer.length < 8) break;

      // Validate header CRC16
      Uint8List header = Uint8List.fromList(_buffer.sublist(0, 8));
      int calcHdrCrc = calcCrc16Modbus(header.sublist(0, 6));
      ByteData bd = ByteData.sublistView(header);
      int wireHdrCrc = bd.getUint16(6, Endian.little);
      if (calcHdrCrc != wireHdrCrc) {
        _buffer.removeAt(0);
        continue;
      }

      // In FW 50.41.1.0, len_u16 at bytes 2..4 is (innerPayloadLen + 4 bytes CRC32)
      int payloadPlusCrcLen = bd.getUint16(2, Endian.little);
      if (payloadPlusCrcLen < 4 || payloadPlusCrcLen > 512) {
        _buffer.removeAt(0);
        continue;
      }

      int totalFrameLen = 8 + payloadPlusCrcLen;
      if (_buffer.length < totalFrameLen) {
        // Awaiting remaining BLE chunks
        break;
      }

      Uint8List frameBytes = Uint8List.fromList(_buffer.sublist(0, totalFrameLen));
      Uint8List innerBytes = frameBytes.sublist(8, totalFrameLen - 4);
      Uint8List bodyBytes = frameBytes.sublist(0, totalFrameLen - 4);

      ByteData fbd = ByteData.sublistView(frameBytes);
      int wireCrc32 = fbd.getUint32(totalFrameLen - 4, Endian.little);

      // Accept if CRC32 matches either innerBytes (Gen 5 standard) or bodyBytes
      if (calcCrc32Ieee(innerBytes) == wireCrc32 || calcCrc32Ieee(bodyBytes) == wireCrc32) {
        frames.add(frameBytes);
        _buffer.removeRange(0, totalFrameLen);
      } else {
        _buffer.removeAt(0);
      }
    }

    return frames;
  }

  void clear() {
    _buffer.clear();
  }
}
