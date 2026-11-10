import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:beveltry/src/dsp/hrv_rmssd.dart';

void main() {
  test('verify segmented HRV on real night CSV', () async {
    var file = File('../exports/whoop_night_data_night_1794264340726.csv');
    if (!await file.exists()) {
      file = File('exports/whoop_night_data_night_1794264340726.csv');
    }
    if (!await file.exists()) {
      file = File('C:/Users/costa/Downloads/Deepseek_Bevel/exports/whoop_night_data_night_1794264340726.csv');
    }
    expect(await file.exists(), isTrue, reason: 'Real night CSV must be available for testing');

    final lines = await file.readAsLines();
    final beats = <BeatInterval>[];

    // Format: timestamp,hr,rr_raw
    DateTime? lastDt;
    var currentOrdinal = 0;

    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final parts = line.split(',');
      if (parts.length < 3) continue;

      final rrStr = parts[2].trim();
      if (rrStr.isEmpty) continue;

      final rrVal = int.tryParse(rrStr);
      if (rrVal == null) continue;

      final dt = DateTime.parse(parts[0]);
      if (lastDt != null && dt == lastDt) {
        currentOrdinal++;
      } else {
        currentOrdinal = 0;
        lastDt = dt;
      }

      beats.add(BeatInterval(
        timestampUtc: dt,
        rrMs: rrVal,
        beatOrdinal: currentOrdinal,
      ));
    }

    expect(beats.length, equals(27424));

    final result = calculateSegmentedHrv(
      beats: beats,
      gapThresholdSeconds: 2.0,
      minPhysiologicalMs: 300,
      maxPhysiologicalMs: 2000,
    );

    // Verifiche quantitative esatte sui dati reali:
    expect(result.totalBeats, equals(27424));
    expect(result.validBeats, equals(27421));
    expect(result.excludedPhysiologicalBeats, equals(3)); // [2052, 2332, 2400]
    expect(result.legacyRmssdMs, closeTo(93.74, 0.05));
    expect(result.segmentedRmssdMs, closeTo(89.74, 0.05));
    expect(result.segmentedRmssd1024Ms, closeTo(87.64, 0.05));
    expect(result.legacyRmssd1024Ms, closeTo(91.55, 0.05));
    expect(result.excludedGapsCount, equals(2172));
    expect(result.segmentsCount, equals(2162));
    expect(result.validSuccessiveDiffsCount, equals(25246));
    expect(result.maxGapSeconds, closeTo(181.805, 0.01));

    // Riconciliazione matematica formale:
    final beatsInGe2 = result.segments.fold<int>(0, (sum, seg) => sum + seg.length);
    expect(beatsInGe2, equals(27408));
    final singletonBeats = result.validBeats - beatsInGe2;
    expect(singletonBeats, equals(13));
    expect(beatsInGe2 + singletonBeats, equals(result.validBeats));
    expect(result.validBeats + result.excludedPhysiologicalBeats, equals(result.totalBeats));
    expect(result.validSuccessiveDiffsCount, equals(beatsInGe2 - result.segmentsCount));
    expect(result.validSuccessiveDiffsCount, equals(25246));
  });

  test('segmentation isolates beats across artificial gaps', () {
    final t0 = DateTime.utc(2026, 11, 9, 23, 0, 0);
    final beats = [
      // Segment 1 (3 beats)
      BeatInterval(timestampUtc: t0, rrMs: 1000, beatOrdinal: 0),
      BeatInterval(timestampUtc: t0.add(const Duration(seconds: 1)), rrMs: 1020, beatOrdinal: 0),
      BeatInterval(timestampUtc: t0.add(const Duration(seconds: 2)), rrMs: 980, beatOrdinal: 0),

      // Artificial GAP of 10 seconds!
      // Segment 2 (2 beats)
      BeatInterval(timestampUtc: t0.add(const Duration(seconds: 12)), rrMs: 800, beatOrdinal: 0),
      BeatInterval(timestampUtc: t0.add(const Duration(seconds: 13)), rrMs: 810, beatOrdinal: 0),
    ];

    final result = calculateSegmentedHrv(beats: beats, gapThresholdSeconds: 2.0);

    // Segment 1 diffs: (1020 - 1000) = 20, (980 - 1020) = -40 -> sum sq = 400 + 1600 = 2000
    // Segment 2 diffs: (810 - 800) = 10 -> sum sq = 100
    // Total valid diffs: 3. Total sum sq: 2100. Mean sq: 700. RMSSD = sqrt(700) = 26.4575 ms
    // In unsegmented legacy: also calculates (800 - 980) = -180 across the 10s gap!
    // -> sum sq = 2100 + 32400 = 34500. Mean sq: 34500 / 4 = 8625. RMSSD = sqrt(8625) = 92.87 ms! (inflated by 250%!)

    expect(result.segmentsCount, equals(2));
    expect(result.excludedGapsCount, equals(1));
    expect(result.validSuccessiveDiffsCount, equals(3));
    expect(result.segmentedRmssdMs, closeTo(26.46, 0.01));
    expect(result.legacyRmssdMs, closeTo(92.87, 0.01));
  });
}
