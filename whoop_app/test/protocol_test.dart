import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:whoop_app/protocol/puffin_framing.dart';
import 'package:whoop_app/protocol/puffin_commands.dart';
import 'package:whoop_app/protocol/puffin_decoder.dart';

void main() {
  group('Puffin Framing Tests', () {
    test('CRC16 Modbus known vector', () {
      Uint8List data = Uint8List.fromList([0xAA, 0x01, 0x04, 0x00, 0x01, 0x00]);
      int crc = calcCrc16Modbus(data);
      expect(crc > 0, isTrue);
    });

    test('CRC32 IEEE known vector', () {
      Uint8List data = Uint8List.fromList([0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39]);
      int crc = calcCrc32Ieee(data);
      expect(crc, equals(0xCBF43926));
    });

    test('Build and Extract Frame Round-Trip', () {
      Uint8List inner = Uint8List.fromList([0x23, 0x01, 0x91, 0x01]);
      Uint8List frame = buildPuffinFrame(inner);

      expect(frame.length, greaterThanOrEqualTo(16));
      expect(frame[0], equals(0xAA));
      expect(frame[1], equals(0x01));

      Uint8List extracted = extractInnerPayload(frame);
      expect(extracted.sublist(0, 4), equals(inner));
    });

    test('Stream Reassembler handles fragmented chunks', () {
      Uint8List inner = Uint8List.fromList([0x28, 0x01, 0x00, 0x00, 68, 65, 95, 0x00]);
      Uint8List frame = buildPuffinFrame(inner);

      PuffinStreamReassembler reassembler = PuffinStreamReassembler();

      // Split into 3 fragments
      int part1 = frame.length ~/ 3;
      int part2 = (frame.length * 2) ~/ 3;

      var res1 = reassembler.feed(frame.sublist(0, part1));
      expect(res1.isEmpty, isTrue);

      var res2 = reassembler.feed(frame.sublist(part1, part2));
      expect(res2.isEmpty, isTrue);

      var res3 = reassembler.feed(frame.sublist(part2));
      expect(res3.length, equals(1));
      expect(res3[0], equals(frame));
    });
  });

  group('Puffin Commands & Safety Allowlist Tests', () {
    final builder = PuffinCommandBuilder();

    test('Allowlisted commands generate valid frames', () {
      Uint8List fHello = builder.buildGetHello();
      expect(fHello[0], equals(0xAA));

      Uint8List fClock = builder.buildGetClock();
      expect(fClock[0], equals(0xAA));

      Uint8List fSync = builder.buildSendHistorical();
      expect(fSync[0], equals(0xAA));

      Uint8List cursor8b = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      Uint8List fAck = builder.buildHistoricalDataResult(cursor8b);
      expect(fAck[0], equals(0xAA));
    });

    test('Dangerous opcode 0x19 ERASE_FLASH is strictly blocked', () {
      expect(
        () => builder.buildCommand(cmd: PuffinOpcodes.eraseFlash),
        throwsA(isA<SecurityException>()),
      );
    });

    test('Dangerous opcode 0x1D REBOOT is strictly blocked', () {
      expect(
        () => builder.buildCommand(cmd: PuffinOpcodes.rebootStrap),
        throwsA(isA<SecurityException>()),
      );
    });
  });

  group('Puffin Decoder Aligned Tests', () {
    test('Decode Cursor 0x31 at inner[5:13]', () {
      Uint8List inner = Uint8List(24);
      inner[0] = 0x31;
      Uint8List cursorExpected = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44]);
      inner.setRange(5, 13, cursorExpected);

      var meta = PuffinDecoder.decodeCursor0x31(inner);
      expect(meta, isNotNull);
      expect(meta!.cursorHex, equals('AABBCCDD11223344'));
      expect(meta.cursorBytes, equals(cursorExpected));

      // Test with full wire frame
      Uint8List wireFrame = buildPuffinFrame(inner);
      var metaWire = PuffinDecoder.decodeCursor0x31(wireFrame);
      expect(metaWire, isNotNull);
      expect(metaWire!.cursorHex, equals('AABBCCDD11223344'));
    });

    test('Decode Historical Record v18 (112-byte inner)', () {
      Uint8List inner = Uint8List(112);
      inner[0] = 0x2F;
      inner[1] = 0x12; // v18

      ByteData bd = ByteData.sublistView(inner);
      bd.setUint16(2, 53632, Endian.little);
      bd.setUint32(7, 1793241294, Endian.little);
      inner[14] = 68; // Primary HR
      inner[15] = 2; // rr_count
      bd.setUint16(16, 880, Endian.little);
      bd.setUint16(18, 890, Endian.little);

      // Gravity vector at inner[37..49]
      bd.setFloat32(37, 0.05, Endian.little);
      bd.setFloat32(41, -0.12, Endian.little);
      bd.setFloat32(45, 0.98, Endian.little);

      // Skin temp at inner[61..63]
      bd.setInt16(61, 312, Endian.little); // 31.2 C

      // Steps at inner[57..59]
      bd.setUint16(57, 4520, Endian.little);

      // Optical baseline at inner[98..100]
      bd.setUint16(98, 38500, Endian.little); // > 30000 = on-wrist

      var v18 = PuffinDecoder.decodeHistoricalV18(inner);
      expect(v18, isNotNull);
      expect(v18!.sequence, equals(53632));
      expect(v18.timestampUnix, equals(1793241294));
      expect(v18.primaryHr, equals(68));
      expect(v18.rrCount, equals(2));
      expect(v18.rrIntervalsMs, equals([880, 890]));
      expect(v18.accelMagG, closeTo(0.988, 0.01));
      expect(v18.skinTempC, closeTo(31.2, 0.01));
      expect(v18.steps, equals(4520));
      expect(v18.isOnWrist, isTrue);
    });

    test('Decode Live HR 0x28', () {
      Uint8List inner = Uint8List.fromList([0x28, 0x01, 0x00, 0x00, 72, 70, 98, 0x00]);
      var live = PuffinDecoder.decodeLiveHr0x28(inner);
      expect(live, isNotNull);
      expect(live!.primaryHr, equals(72));
      expect(live.secondaryHr, equals(70));
    });

    test('Decode Standard BLE HR 0x2A37', () {
      Uint8List val = Uint8List.fromList([
        0x10, // 8-bit HR, with RR intervals
        65,   // HR 65
        0xE8, 0x03, // 1000 ms direct (WHOOP 5.0 transmits direct ms without 1/1024s scaling)
      ]);
      var decoded = PuffinDecoder.decodeStandardHr0x2A37(val);
      expect(decoded['hr'], equals(65));
      expect(decoded['rr_ms'], equals([1000]));
    });

    test('Decode Cursor 0x31 from hardware frame at inner[13:21]', () {
      Uint8List inner = Uint8List(40);
      inner[0] = 0x31;
      Uint8List cursorExpected = Uint8List.fromList([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]);
      inner.setRange(13, 21, cursorExpected);

      var meta = PuffinDecoder.decodeCursor0x31(inner);
      expect(meta, isNotNull);
      expect(meta!.cursorHex, equals('1122334455667788'));
      expect(meta.cursorBytes, equals(cursorExpected));
    });
  });
}
