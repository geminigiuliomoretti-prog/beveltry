import 'dart:typed_data';

import 'record_decode_exception.dart';

/// Decodifica il payload WHOOP della caratteristica Heart Rate Measurement (0x2A37).
class StandardHrRecord {
  const StandardHrRecord({
    required this.hr,
    required this.energyExpended,
    required this.rrIntervalsMs,
    List<int>? rawRrIntervals,
    List<double>? rrIntervals1024Ms,
  })  : rawRrIntervals = rawRrIntervals ?? rrIntervalsMs,
        rrIntervals1024Ms = rrIntervals1024Ms ?? const [];

  final int hr;
  final int? energyExpended;

  /// Intervalli R-R grezzi in millisecondi diretti (WHOOP 5.0).
  final List<int> rrIntervalsMs;

  /// Copia esplicita degli intervalli R-R grezzi u16 originali.
  final List<int> rawRrIntervals;

  /// Intervalli R-R convertiti secondo lo standard Bluetooth SIG 1/1024s (raw * 1000 / 1024).
  final List<double> rrIntervals1024Ms;

  static StandardHrRecord decode(Uint8List payload) {
    if (payload.isEmpty) {
      throw const RecordDecodeException('0x2A37: payload vuoto');
    }

    final flags = payload[0];
    var offset = 1;
    final wideHr = (flags & 0x01) != 0;
    final hrWidth = wideHr ? 2 : 1;
    _requireBytes(payload, offset, hrWidth, 'heart rate');
    final data = ByteData.sublistView(payload);
    final hr = wideHr ? data.getUint16(offset, Endian.little) : payload[offset];
    offset += hrWidth;

    int? energyExpended;
    if ((flags & 0x08) != 0) {
      _requireBytes(payload, offset, 2, 'energy expended');
      energyExpended = data.getUint16(offset, Endian.little);
      offset += 2;
    }

    final rawRrList = <int>[];
    final rr1024List = <double>[];
    if ((flags & 0x10) != 0) {
      final remaining = payload.length - offset;
      if (remaining.isOdd) {
        throw const RecordDecodeException('0x2A37: intervallo R-R incompleto');
      }
      while (offset < payload.length) {
        final rawU16 = data.getUint16(offset, Endian.little);
        rawRrList.add(rawU16);
        // Calcolo conforme alla specifica Bluetooth SIG (1/1024 di secondo)
        rr1024List.add(rawU16 * 1000.0 / 1024.0);
        offset += 2;
      }
    } else if (offset != payload.length) {
      throw const RecordDecodeException('0x2A37: byte finali senza flag R-R');
    }

    return StandardHrRecord(
      hr: hr,
      energyExpended: energyExpended,
      rrIntervalsMs: List<int>.unmodifiable(rawRrList),
      rawRrIntervals: List<int>.unmodifiable(rawRrList),
      rrIntervals1024Ms: List<double>.unmodifiable(rr1024List),
    );
  }

  static void _requireBytes(
    Uint8List payload,
    int offset,
    int length,
    String field,
  ) {
    if (payload.length - offset < length) {
      throw RecordDecodeException('0x2A37: $field incompleto');
    }
  }
}
