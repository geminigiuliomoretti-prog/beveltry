import 'dart:typed_data';

import 'package:beveltry/src/records/record_decode_exception.dart';
import 'package:beveltry/src/records/standard_hr_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('flag 0 e u8 HR sem R-R', () {
    final record = StandardHrRecord.decode(Uint8List.fromList([0x00, 72]));

    expect(record.hr, 72);
    expect(record.energyExpended, isNull);
    expect(record.rrIntervalsMs, isEmpty);
  });

  test('flag R-R: mantiene i millisecondi senza conversione', () {
    final payload = Uint8List.fromList([0x10, 72, 0x60, 0x03, 0x5C, 0x03]);
    final original = Uint8List.fromList(payload);
    final record = StandardHrRecord.decode(payload);

    expect(record.hr, 72);
    expect(record.rrIntervalsMs, [864, 860]);
    expect(record.rawRrIntervals, [864, 860]);
    expect(record.rrIntervals1024Ms.length, 2);
    expect(record.rrIntervals1024Ms[0], closeTo(864 * 1000.0 / 1024.0, 0.001));
    expect(record.rrIntervals1024Ms[1], closeTo(860 * 1000.0 / 1024.0, 0.001));
    expect(payload, original);
  });

  test('flag 0x01 legge HR u16 little-endian', () {
    final record = StandardHrRecord.decode(
      Uint8List.fromList([0x01, 0x48, 0x00]),
    );

    expect(record.hr, 72);
  });

  test('flag energia legge u16 little-endian', () {
    final record = StandardHrRecord.decode(
      Uint8List.fromList([0x08, 72, 0x10, 0x27]),
    );

    expect(record.hr, 72);
    expect(record.energyExpended, 10000);
  });

  test('legge tre intervalli R-R quando il flag è presente', () {
    final record = StandardHrRecord.decode(
      Uint8List.fromList([0x10, 72, 0x60, 0x03, 0x5C, 0x03, 0x58, 0x03]),
    );

    expect(record.rrIntervalsMs, [864, 860, 856]);
  });

  test('rifiuta payload vuoti e campi troncati o incoerenti', () {
    expect(
      () => StandardHrRecord.decode(Uint8List(0)),
      throwsA(isA<RecordDecodeException>()),
    );
    expect(
      () => StandardHrRecord.decode(Uint8List.fromList([0x01, 0x48])),
      throwsA(isA<RecordDecodeException>()),
    );
    expect(
      () => StandardHrRecord.decode(Uint8List.fromList([0x08, 72, 0x10])),
      throwsA(isA<RecordDecodeException>()),
    );
    expect(
      () => StandardHrRecord.decode(Uint8List.fromList([0x10, 72, 0x60])),
      throwsA(isA<RecordDecodeException>()),
    );
  });
}
