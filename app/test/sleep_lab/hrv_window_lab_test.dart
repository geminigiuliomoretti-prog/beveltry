import 'package:flutter_test/flutter_test.dart';

import 'package:beveltry/src/dsp/hrv_rmssd.dart';
import 'package:beveltry/src/sleep_lab/cardiac_sleep_wake_estimator.dart';
import 'package:beveltry/src/sleep_lab/epoch_engine.dart';
import 'package:beveltry/src/sleep_lab/hrv_window_lab.dart';

void main() {
  group('HrvWindowLab Tests', () {
    test('Calcolo RMSSD intero sonno: produce valori diretti e conversione SIG 1024', () {
      final start = DateTime.utc(2026, 11, 10, 0, 0, 0);
      final end = start.add(const Duration(minutes: 30));

      // 600 battiti sintetici (1 battito ogni secondo) con alternanza 900ms / 950ms (diff = 50ms)
      final beats = <BeatInterval>[];
      for (var i = 0; i < 600; i++) {
        final rr = (i % 2 == 0) ? 900 : 950;
        beats.add(BeatInterval(timestampUtc: start.add(Duration(seconds: i)), rrMs: rr));
      }

      final res = calculateHrvWindowLab(
        beats: beats,
        sleepStartUtc: start,
        sleepEndUtc: end,
      );

      expect(res.wholeSleepRmssd.isAvailable, isTrue);
      expect(res.wholeSleepRmssd.status, equals(MetricProvenanceStatus.measured));
      // Con alternanza costante di 50 ms, RMSSD teorico è esattamente 50.0 ms
      expect(res.wholeSleepRmssd.valueDirectMs, closeTo(50.0, 0.01));
      // Conversione standard Bluetooth SIG (50 * 1000 / 1024) = 48.828 ms
      expect(res.wholeSleepRmssd.value1024Ms, closeTo(50.0 * 1000.0 / 1024.0, 0.01));
      expect(res.wholeSleepRmssd.validPairsCount, equals(599));
    });

    test('Finestre mobili da 5 minuti: calcola statistiche su finestre valide', () {
      final start = DateTime.utc(2026, 11, 10, 0, 0, 0);
      final end = start.add(const Duration(minutes: 20)); // 20 minuti

      final beats = <BeatInterval>[];
      for (var i = 0; i < 1200; i++) {
        // battiti regolari ogni secondo
        final rr = 900 + (i % 10) * 10;
        beats.add(BeatInterval(timestampUtc: start.add(Duration(seconds: i)), rrMs: rr));
      }

      final res = calculateHrvWindowLab(
        beats: beats,
        sleepStartUtc: start,
        sleepEndUtc: end,
      );

      expect(res.rolling5MinTotalWindows, greaterThan(0));
      expect(res.rolling5MinValidWindows, greaterThan(0));
      expect(res.rolling5MinMedianMs, isNotNull);
      expect(res.rolling5MinMeanMs, isNotNull);
      expect(res.rolling5MinMinMs, isNotNull);
      expect(res.rolling5MinMaxMs, isNotNull);
      expect(res.rolling5MinMinMs!, lessThanOrEqualTo(res.rolling5MinMaxMs!));
    });

    test('Senza stadiazione Deep validata: candidati Deep sono rigorosamente UNAVAILABLE', () {
      final start = DateTime.utc(2026, 11, 10, 0, 0, 0);
      final end = start.add(const Duration(minutes: 15));
      final beats = List.generate(
        600,
        (i) => BeatInterval(timestampUtc: start.add(Duration(seconds: i)), rrMs: 950),
      );

      final res = calculateHrvWindowLab(
        beats: beats,
        sleepStartUtc: start,
        sleepEndUtc: end,
        epochs: null,
        isDeepSleepEpochMask: null,
      );

      expect(res.rmssdAllDeep.status, equals(MetricProvenanceStatus.unavailable));
      expect(res.rmssdLastDeepEpisode.status, equals(MetricProvenanceStatus.unavailable));
      expect(res.rmssdLast5MinDeep.status, equals(MetricProvenanceStatus.unavailable));
      expect(res.rmssdBest5MinDeep.status, equals(MetricProvenanceStatus.unavailable));
      expect(res.rmssdWeightedLateDeep.status, equals(MetricProvenanceStatus.unavailable));

      expect(res.rmssdLast5MinDeep.unavailabilityReason, contains('TASK 08B'));
      expect(res.rmssdLast5MinDeep.valueDirectMs, isNull);
    });

    test('Con maschera Deep valida (>= 10 epoche): calcola i candidati SWS', () {
      final start = DateTime.utc(2026, 11, 10, 0, 0, 0);
      final end = start.add(const Duration(minutes: 30)); // 60 epoche

      final epochs = <Epoch30s>[];
      final deepMask = <bool>[];
      final beats = <BeatInterval>[];

      for (var ep = 0; ep < 60; ep++) {
        final epStart = start.add(Duration(seconds: ep * 30));
        final epEnd = epStart.add(const Duration(seconds: 30));
        // Epoche 20..35 sono Deep (16 epoche = 8 minuti)
        final isDeep = ep >= 20 && ep <= 35;
        deepMask.add(isDeep);

        epochs.add(
          Epoch30s(
            index: ep,
            startUtc: epStart,
            endUtc: epEnd,
            hrSamplesCount: 30,
            hrMean: isDeep ? 48.0 : 60.0,
            hrMedian: isDeep ? 48.0 : 60.0,
            hrMin: isDeep ? 46 : 58,
            hrMax: isDeep ? 50 : 62,
            hrStd: 0.5,
            rrIntervalsCount: 30,
            validRrIntervalsCount: 30,
            maxGapSeconds: 1.0,
            hrCoveragePercent: 100.0,
            isUsable: true,
            qualityFlags: {},
          ),
        );

        for (var s = 0; s < 30; s++) {
          final t = epStart.add(Duration(seconds: s));
          final rr = isDeep ? ((s % 2 == 0) ? 1100 : 1160) : 1000;
          beats.add(BeatInterval(timestampUtc: t, rrMs: rr));
        }
      }

      final res = calculateHrvWindowLab(
        beats: beats,
        sleepStartUtc: start,
        sleepEndUtc: end,
        epochs: epochs,
        isDeepSleepEpochMask: deepMask,
      );

      expect(res.rmssdAllDeep.isAvailable, isTrue);
      expect(res.rmssdLastDeepEpisode.isAvailable, isTrue);
      expect(res.rmssdLast5MinDeep.isAvailable, isTrue);
      expect(res.rmssdBest5MinDeep.isAvailable, isTrue);
      expect(res.rmssdWeightedLateDeep.isAvailable, isTrue);

      expect(res.rmssdAllDeep.valueDirectMs, closeTo(60.0, 0.5));
      expect(res.rmssdLast5MinDeep.valueDirectMs, closeTo(60.0, 0.5));
    });
  });
}
