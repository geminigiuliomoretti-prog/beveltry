import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';

import 'package:beveltry/src/dsp/hrv_rmssd.dart';
import 'package:beveltry/src/records/night_session_summary.dart';
import 'package:beveltry/src/sleep_lab/cardiac_sleep_wake_estimator.dart';
import 'package:beveltry/src/sleep_lab/respiration_and_rhr.dart';

void main() {
  group('Respiration & RHR Tests', () {
    test('RHR: Calcola minimo su rolling 5 min come metrica indipendente misurata', () {
      final start = DateTime.utc(2026, 11, 10, 0, 0, 0);
      final end = start.add(const Duration(minutes: 30));

      final samples = <HrSamplePoint>[];
      // 30 minuti di campioni ad 1 Hz = 1800 campioni
      for (var i = 0; i < 1800; i++) {
        final t = start.add(Duration(seconds: i));
        // Tra il minuto 10 e 15 (campioni 600..900), la frequenza scende a 45 BPM
        final bpm = (i >= 600 && i < 900) ? 45 : 60;
        samples.add(HrSamplePoint(timestampUtc: t, hrBpm: bpm));
      }

      final rhr = calculateRhrWindowLab(
        hrSamples: samples,
        sleepStartUtc: start,
        sleepEndUtc: end,
      );

      expect(rhr.min5MinStatus, equals(MetricProvenanceStatus.measured));
      expect(rhr.min5MinBpm, equals(45));
      expect(rhr.wholeSleepMeanBpm, closeTo(57.5, 0.5));
      expect(rhr.finalDeepMeanBpm.status, equals(MetricProvenanceStatus.unavailable));
    });

    test('Stima Respiratoria RSA: rileva frequenza sinusoidale nota (15 RPM)', () {
      final start = DateTime.utc(2026, 11, 10, 0, 0, 0);
      // 20 minuti di segnale sintetico con modulazione respiratoria a 0.25 Hz (15 RPM)
      final end = start.add(const Duration(minutes: 20));

      final beats = <BeatInterval>[];
      const respFreqHz = 0.25; // 15 respiri al minuto (0.25 * 60 = 15)

      var curSec = 0.0;
      while (curSec < 1200.0) {
        final t = start.add(Duration(milliseconds: (curSec * 1000).toInt()));
        // Modulazione sinusale: media 1000ms + oscillazione ±60ms a 0.25 Hz
        final rsa = 60.0 * math.sin(2.0 * math.pi * respFreqHz * curSec);
        final rrMs = (1000.0 + rsa).round();

        beats.add(BeatInterval(timestampUtc: t, rrMs: rrMs, beatOrdinal: 0));
        curSec += rrMs / 1000.0;
      }

      final resp = estimateRespirationRsa(
        beats: beats,
        sleepStartUtc: start,
        sleepEndUtc: end,
        minValidWindowsRequired: 5,
        minBeatsPerWindow: 80,
      );

      expect(resp.status, equals(MetricProvenanceStatus.experimental));
      expect(resp.medianBreathsPerMinute, isNotNull);
      // Frequenza attesa: 15.0 RPM (tolleranza 0.5 RPM)
      expect(resp.medianBreathsPerMinute!, closeTo(15.0, 0.5));
      expect(resp.validWindowsCount, greaterThanOrEqualTo(5));
    });

    test('Stima Respiratoria RSA: restituisce UNAVAILABLE se i dati sono insufficienti o rumorosi', () {
      final start = DateTime.utc(2026, 11, 10, 0, 0, 0);
      final end = start.add(const Duration(minutes: 5));

      // Solo 20 battiti in 5 minuti -> non raggiunge minBeatsPerWindow (120)
      final beats = List.generate(
        20,
        (i) => BeatInterval(timestampUtc: start.add(Duration(seconds: i * 15)), rrMs: 900),
      );

      final resp = estimateRespirationRsa(
        beats: beats,
        sleepStartUtc: start,
        sleepEndUtc: end,
      );

      expect(resp.status, equals(MetricProvenanceStatus.unavailable));
      expect(resp.medianBreathsPerMinute, isNull);
      expect(resp.unavailabilityReason, isNotNull);
    });

    test('Determinismo: calcolo RSA ripetuto produce risultati identici', () {
      final start = DateTime.utc(2026, 11, 10, 0, 0, 0);
      final end = start.add(const Duration(minutes: 15));

      final beats = List.generate(
        900,
        (i) => BeatInterval(
          timestampUtc: start.add(Duration(seconds: i)),
          rrMs: 900 + (30.0 * math.sin(i * 0.2)).toInt(),
        ),
      );

      final resp1 = estimateRespirationRsa(
        beats: beats,
        sleepStartUtc: start,
        sleepEndUtc: end,
        minValidWindowsRequired: 2,
        minBeatsPerWindow: 80,
      );
      final resp2 = estimateRespirationRsa(
        beats: beats,
        sleepStartUtc: start,
        sleepEndUtc: end,
        minValidWindowsRequired: 2,
        minBeatsPerWindow: 80,
      );

      expect(resp1.medianBreathsPerMinute, equals(resp2.medianBreathsPerMinute));
      expect(resp1.validWindowsCount, equals(resp2.validWindowsCount));
    });
  });
}
