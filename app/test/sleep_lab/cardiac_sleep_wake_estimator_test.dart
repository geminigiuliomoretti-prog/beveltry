import 'package:flutter_test/flutter_test.dart';

import 'package:beveltry/src/sleep_lab/cardiac_sleep_wake_estimator.dart';
import 'package:beveltry/src/sleep_lab/epoch_engine.dart';

void main() {
  group('CardiacSleepWakeEstimator Tests', () {
    test('Epoche vuote restituiscono risultato safe a zero', () {
      final res = CardiacSleepWakeEstimator.estimate(epochs: []);
      expect(res.algorithmVersion, equals('1.0.0-cardiac-only'));
      expect(res.provenance, equals(MetricProvenanceStatus.experimentalCardiacOnly));
      expect(res.totalSleepDurationSeconds, equals(0));
      expect(res.wasoDurationSeconds, equals(0));
      expect(res.sleepEfficiencyPercent, equals(0.0));
    });

    test('Calcola probabilità continua per ciascuna epoca in [0.0, 1.0]', () {
      final base = DateTime.utc(2026, 11, 10, 0, 0, 0);
      final epochs = <Epoch30s>[];

      // 20 epoche con FC variabile
      for (var i = 0; i < 20; i++) {
        final hr = (i < 10) ? 75.0 : 50.0;
        epochs.add(
          Epoch30s(
            index: i,
            startUtc: base.add(Duration(seconds: i * 30)),
            endUtc: base.add(Duration(seconds: (i + 1) * 30)),
            hrSamplesCount: 30,
            hrMean: hr,
            hrMedian: hr,
            hrMin: hr.toInt(),
            hrMax: hr.toInt(),
            hrStd: 1.0,
            hrSlope: 0.0,
            rrIntervalsCount: 25,
            validRrIntervalsCount: 25,
            maxGapSeconds: 1.0,
            hrCoveragePercent: 100.0,
            isUsable: true,
            qualityFlags: {},
          ),
        );
      }

      final res = CardiacSleepWakeEstimator.estimate(epochs: epochs);

      expect(res.epochs.length, equals(20));
      for (final ep in res.epochs) {
        expect(ep.rawSleepProbability, greaterThanOrEqualTo(0.0));
        expect(ep.rawSleepProbability, lessThanOrEqualTo(1.0));
        expect(ep.smoothedSleepProbability, greaterThanOrEqualTo(0.0));
        expect(ep.smoothedSleepProbability, lessThanOrEqualTo(1.0));
      }

      // Le prime epoche (75 BPM) hanno probabilità di sonno molto inferiore alle seconde (50 BPM)
      expect(res.epochs[0].smoothedSleepProbability, lessThan(res.epochs[15].smoothedSleepProbability));
    });

    test('Non assume l\'inizio della registrazione come sonno: rileva latenza e onset', () {
      final base = DateTime.utc(2026, 11, 10, 23, 0, 0);
      final epochs = <Epoch30s>[];

      // Prime 10 epoche (5 minuti): veglia pre-sonno (HR = 80, std = 3.5)
      for (var i = 0; i < 10; i++) {
        epochs.add(
          Epoch30s(
            index: i,
            startUtc: base.add(Duration(seconds: i * 30)),
            endUtc: base.add(Duration(seconds: (i + 1) * 30)),
            hrSamplesCount: 30,
            hrMean: 80.0,
            hrMedian: 80.0,
            hrMin: 76,
            hrMax: 85,
            hrStd: 3.5,
            rrIntervalsCount: 20,
            validRrIntervalsCount: 20,
            maxGapSeconds: 1.0,
            hrCoveragePercent: 100.0,
            isUsable: true,
            qualityFlags: {},
          ),
        );
      }

      // Successive 30 epoche (15 minuti): sonno profondo/stabile (HR = 52, std = 0.8)
      for (var i = 10; i < 40; i++) {
        epochs.add(
          Epoch30s(
            index: i,
            startUtc: base.add(Duration(seconds: i * 30)),
            endUtc: base.add(Duration(seconds: (i + 1) * 30)),
            hrSamplesCount: 30,
            hrMean: 52.0,
            hrMedian: 52.0,
            hrMin: 50,
            hrMax: 54,
            hrStd: 0.8,
            rrIntervalsCount: 25,
            validRrIntervalsCount: 25,
            maxGapSeconds: 1.0,
            hrCoveragePercent: 100.0,
            isUsable: true,
            qualityFlags: {},
          ),
        );
      }

      // Ultime 10 epoche: risveglio finale (HR = 82)
      for (var i = 40; i < 50; i++) {
        epochs.add(
          Epoch30s(
            index: i,
            startUtc: base.add(Duration(seconds: i * 30)),
            endUtc: base.add(Duration(seconds: (i + 1) * 30)),
            hrSamplesCount: 30,
            hrMean: 82.0,
            hrMedian: 82.0,
            hrMin: 78,
            hrMax: 88,
            hrStd: 4.0,
            rrIntervalsCount: 18,
            validRrIntervalsCount: 18,
            maxGapSeconds: 1.0,
            hrCoveragePercent: 100.0,
            isUsable: true,
            qualityFlags: {},
          ),
        );
      }

      final res = CardiacSleepWakeEstimator.estimate(
        epochs: epochs,
        consecutiveEpochsForOnset: 10,
        consecutiveEpochsForOffset: 5,
      );

      expect(res.estimatedOnsetUtc, isNotNull);
      // L'inizio del sonno NON è l'inizio della registrazione (base), ma attorno a epoca 10
      expect(res.estimatedOnsetUtc!.isAfter(base), isTrue);
      expect(res.sleepOnsetLatencySeconds, inInclusiveRange(300, 360));

      expect(res.estimatedEndUtc, isNotNull);
      expect(res.estimatedEndUtc!.isBefore(epochs.last.endUtc), isTrue);
    });

    test('Distingue risveglio intermedio (WASO) da risveglio definitivo', () {
      final base = DateTime.utc(2026, 11, 10, 0, 0, 0);
      final epochs = <Epoch30s>[];

      // 0..19 (10 min): sonno
      for (var i = 0; i < 20; i++) {
        epochs.add(_makeEpoch(i, base, 50.0, 0.6));
      }
      // 20..23 (2 min): risveglio breve notturno (WASO)
      for (var i = 20; i < 24; i++) {
        epochs.add(_makeEpoch(i, base, 78.0, 3.0));
      }
      // 24..49 (13 min): ritorno al sonno
      for (var i = 24; i < 50; i++) {
        epochs.add(_makeEpoch(i, base, 50.0, 0.6));
      }
      // 50..59 (5 min): risveglio finale
      for (var i = 50; i < 60; i++) {
        epochs.add(_makeEpoch(i, base, 85.0, 4.0));
      }

      final res = CardiacSleepWakeEstimator.estimate(
        epochs: epochs,
        consecutiveEpochsForOnset: 5,
        consecutiveEpochsForOffset: 5,
      );

      // Risvegli intermedi
      expect(res.awakeningsCount, greaterThanOrEqualTo(1));
      expect(res.wasoDurationSeconds, greaterThan(0));
      expect(res.totalSleepDurationSeconds, greaterThan(0));
      expect(res.sleepEfficiencyPercent, greaterThan(75.0));
      expect(res.sleepEfficiencyPercent, lessThan(100.0));
    });

    test('Sovrascrittura manuale: preserva stima originale e ricalcola metriche con confini utente', () {
      final base = DateTime.utc(2026, 11, 10, 0, 0, 0);
      final epochs = List.generate(60, (i) => _makeEpoch(i, base, 52.0, 0.8));

      final manualOnset = base.add(const Duration(minutes: 10));
      final manualEnd = base.add(const Duration(minutes: 25));

      final res = CardiacSleepWakeEstimator.estimate(
        epochs: epochs,
        manualOnsetUtc: manualOnset,
        manualEndUtc: manualEnd,
      );

      expect(res.isManualOverride, isTrue);
      expect(res.effectiveOnsetUtc, equals(manualOnset));
      expect(res.effectiveEndUtc, equals(manualEnd));
      // TST calcolato sui 15 minuti tra manualOnset e manualEnd = 900 secondi
      expect(res.totalSleepDurationSeconds, equals(900));
    });
  });
}

Epoch30s _makeEpoch(int index, DateTime base, double hr, double std) {
  return Epoch30s(
    index: index,
    startUtc: base.add(Duration(seconds: index * 30)),
    endUtc: base.add(Duration(seconds: (index + 1) * 30)),
    hrSamplesCount: 30,
    hrMean: hr,
    hrMedian: hr,
    hrMin: (hr - 2).toInt(),
    hrMax: (hr + 2).toInt(),
    hrStd: std,
    hrSlope: 0.0,
    rrIntervalsCount: 25,
    validRrIntervalsCount: 25,
    maxGapSeconds: 1.0,
    hrCoveragePercent: 100.0,
    isUsable: true,
    qualityFlags: {},
  );
}
