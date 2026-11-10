import 'package:flutter_test/flutter_test.dart';

import 'package:beveltry/src/sleep_lab/whoop_a_comparison.dart';

void main() {
  group('WhoopAComparison Tests', () {
    test('Serializzazione toMap e fromMap reversibile per SQLite', () {
      final now = DateTime.utc(2026, 11, 10, 8, 30, 0);
      final onset = DateTime.utc(2026, 11, 10, 0, 15, 0);
      final offset = DateTime.utc(2026, 11, 10, 7, 45, 0);

      final record = WhoopAComparisonRecord(
        id: 1,
        sessionId: 'night_test_123',
        createdAtUtc: now,
        algorithmVersion: '1.0.0',
        sleepOnsetUtc: onset,
        sleepEndUtc: offset,
        sleepDurationSeconds: 25200, // 7h
        awakeDurationSeconds: 1800,  // 30m
        lightDurationSeconds: 14400,
        deepDurationSeconds: 5400,
        remDurationSeconds: 5400,
        hrvRmssd: 45.5,
        rhrBpm: 52,
        respiratoryRate: 14.2,
        recoveryScore: 78,
        sleepPerformanceScore: 89,
        notes: 'Notte di test ben riposata',
      );

      final map = record.toMap();
      final restored = WhoopAComparisonRecord.fromMap(map);

      expect(restored.id, equals(1));
      expect(restored.sessionId, equals('night_test_123'));
      expect(restored.createdAtUtc, equals(now));
      expect(restored.sleepOnsetUtc, equals(onset));
      expect(restored.sleepEndUtc, equals(offset));
      expect(restored.sleepDurationSeconds, equals(25200));
      expect(restored.awakeDurationSeconds, equals(1800));
      expect(restored.hrvRmssd, equals(45.5));
      expect(restored.rhrBpm, equals(52));
      expect(restored.respiratoryRate, equals(14.2));
      expect(restored.recoveryScore, equals(78));
      expect(restored.notes, equals('Notte di test ben riposata'));
    });

    test('Calcolo deltas produce confronti numerici solo su metriche comparabili', () {
      final onsetA = DateTime.utc(2026, 11, 10, 0, 10, 0);
      final onsetB = DateTime.utc(2026, 11, 10, 0, 20, 0); // +10 min
      final offsetA = DateTime.utc(2026, 11, 10, 8, 0, 0);
      final offsetB = DateTime.utc(2026, 11, 10, 7, 55, 0); // -5 min

      final record = WhoopAComparisonRecord(
        sessionId: 'sess_1',
        createdAtUtc: DateTime.utc(2026, 11, 10, 8, 30, 0),
        algorithmVersion: '1.0.0',
        sleepOnsetUtc: onsetA,
        sleepEndUtc: offsetA,
        sleepDurationSeconds: 27000, // 7.5h
        awakeDurationSeconds: 1200,  // 20m
        hrvRmssd: 40.0,
        rhrBpm: 50,
        respiratoryRate: 14.0,
      );

      final deltas = computeWhoopAComparisonDeltas(
        whoopA: record,
        beveltryOnsetUtc: onsetB,
        beveltryEndUtc: offsetB,
        beveltryTstSeconds: 25200, // 7h (-30m)
        beveltryWasoSeconds: 1800, // 30m (+10m)
        beveltryHrvWholeMs: 44.0,  // +4 ms (+10%)
        beveltryHrvRollingMedianMs: 42.0,
        beveltryRhrBpm: 52,        // +2 bpm
        beveltryRespRpm: 13.8,     // -0.2 rpm
      );

      expect(deltas.length, equals(7));

      // 1. Onset
      final onsetDelta = deltas.firstWhere((d) => d.metricLabel.contains('Inizio Sonno'));
      expect(onsetDelta.difference, equals('+10 min'));

      // 2. Offset
      final offsetDelta = deltas.firstWhere((d) => d.metricLabel.contains('Risveglio Finale'));
      expect(offsetDelta.difference, equals('-5 min'));

      // 3. TST
      final tstDelta = deltas.firstWhere((d) => d.metricLabel.contains('TST'));
      expect(tstDelta.difference, equals('-30 min'));

      // 4. WASO
      final wasoDelta = deltas.firstWhere((d) => d.metricLabel.contains('WASO'));
      expect(wasoDelta.difference, equals('+10 min'));

      // 5. HRV
      final hrvDelta = deltas.firstWhere((d) => d.metricLabel.contains('HRV'));
      // Preferisce rolling median (42.0) vs 40.0 = +2.0 ms
      expect(hrvDelta.difference, equals('+2.0 ms'));
      expect(hrvDelta.percentDifference, equals('+5.0%'));

      // 6. RHR
      final rhrDelta = deltas.firstWhere((d) => d.metricLabel.contains('RHR'));
      expect(rhrDelta.difference, equals('+2 BPM'));

      // 7. Respiration
      final respDelta = deltas.firstWhere((d) => d.metricLabel.contains('Respiratoria'));
      expect(respDelta.difference, equals('-0.2 RPM'));
    });
  });
}
