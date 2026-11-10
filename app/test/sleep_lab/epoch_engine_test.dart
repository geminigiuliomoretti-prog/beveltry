import 'package:flutter_test/flutter_test.dart';

import 'package:beveltry/src/dsp/hrv_rmssd.dart';
import 'package:beveltry/src/records/night_session_summary.dart';
import 'package:beveltry/src/sleep_lab/epoch_engine.dart';

void main() {
  group('EpochEngine Tests (30-second deterministic epochs)', () {
    test('Partizionamento deterministico: stesse entrate producono epoche identiche', () {
      final baseTime = DateTime.utc(2026, 11, 10, 0, 0, 0);
      final samples = <HrSamplePoint>[];
      final beats = <BeatInterval>[];

      for (var i = 0; i < 90; i++) {
        final t = baseTime.add(Duration(seconds: i));
        samples.add(HrSamplePoint(timestampUtc: t, hrBpm: 60 + (i % 5)));
        beats.add(BeatInterval(timestampUtc: t, rrMs: 1000 + (i % 50)));
      }

      final epochs1 = build30sEpochs(hrSamples: samples, rrBeats: beats);
      final epochs2 = build30sEpochs(hrSamples: samples, rrBeats: beats);

      expect(epochs1.length, equals(3));
      expect(epochs2.length, equals(3));

      for (var i = 0; i < 3; i++) {
        expect(epochs1[i].index, equals(epochs2[i].index));
        expect(epochs1[i].startUtc, equals(epochs2[i].startUtc));
        expect(epochs1[i].endUtc, equals(epochs2[i].endUtc));
        expect(epochs1[i].hrMean, equals(epochs2[i].hrMean));
        expect(epochs1[i].hrMedian, equals(epochs2[i].hrMedian));
        expect(epochs1[i].hrSamplesCount, equals(epochs2[i].hrSamplesCount));
        expect(epochs1[i].rrIntervalsCount, equals(epochs2[i].rrIntervalsCount));
        expect(epochs1[i].isUsable, equals(epochs2[i].isUsable));
      }
    });

    test('Attraversamento della mezzanotte: mantiene timestamp UTC e calcolo coerente', () {
      // Dalle 23:58:00 UTC alle 00:04:00 UTC (6 minuti = 12 epoche)
      final start = DateTime.utc(2026, 11, 9, 23, 58, 0);
      final samples = <HrSamplePoint>[];
      final beats = <BeatInterval>[];

      for (var i = 0; i < 360; i++) {
        final t = start.add(Duration(seconds: i));
        samples.add(HrSamplePoint(timestampUtc: t, hrBpm: 55));
        beats.add(BeatInterval(timestampUtc: t, rrMs: 1090));
      }

      final epochs = build30sEpochs(hrSamples: samples, rrBeats: beats);

      expect(epochs.length, equals(12));
      expect(epochs.first.startUtc, equals(start));
      expect(epochs[4].startUtc, equals(DateTime.utc(2026, 11, 10, 0, 0, 0)));
      expect(epochs.last.endUtc, equals(DateTime.utc(2026, 11, 10, 0, 4, 0)));

      for (final ep in epochs) {
        expect(ep.isUsable, isTrue);
        expect(ep.hrMean, equals(55.0));
        expect(ep.hrSamplesCount, equals(30));
      }
    });

    test('Ricostruzione fisiologica RR multipli: arretra nel tempo i battiti precedenti', () {
      final notifTime = DateTime.utc(2026, 11, 10, 2, 0, 10);
      // Notifica con 3 battiti: ordinal 0 (850ms), ordinal 1 (900ms), ordinal 2 (950ms)
      final rawBeats = [
        BeatInterval(timestampUtc: notifTime, rrMs: 850, beatOrdinal: 0),
        BeatInterval(timestampUtc: notifTime, rrMs: 900, beatOrdinal: 1),
        BeatInterval(timestampUtc: notifTime, rrMs: 950, beatOrdinal: 2),
      ];

      final physio = reconstructPhysiologicalBeats(rawBeats);

      expect(physio.length, equals(3));
      // L'ultimo battito (ordinal 2) è a notifTime:
      expect(physio[2].timestampUtc, equals(notifTime));
      expect(physio[2].rrMs, equals(950));

      // Il penultimo battito (ordinal 1) è a notifTime - 950ms:
      final expectedT1 = notifTime.subtract(const Duration(milliseconds: 950));
      expect(physio[1].timestampUtc, equals(expectedT1));
      expect(physio[1].rrMs, equals(900));

      // Il primo battito (ordinal 0) è a notifTime - 950ms - 900ms = notifTime - 1850ms:
      final expectedT0 = notifTime.subtract(const Duration(milliseconds: 1850));
      expect(physio[0].timestampUtc, equals(expectedT0));
      expect(physio[0].rrMs, equals(850));
    });

    test('Epoche incomplete: gestisce correttamente la coda della sessione', () {
      final base = DateTime.utc(2026, 11, 10, 1, 0, 0);
      // 45 campioni = 1 epoca completa da 30s + 1 epoca incompleta da 15s
      final samples = List.generate(
        45,
        (i) => HrSamplePoint(timestampUtc: base.add(Duration(seconds: i)), hrBpm: 60),
      );

      final epochs = build30sEpochs(
        hrSamples: samples,
        rrBeats: [],
        minSamplesForUsable: 10,
      );

      expect(epochs.length, equals(2));
      expect(epochs[0].hrSamplesCount, equals(30));
      expect(epochs[0].isUsable, isTrue);

      expect(epochs[1].hrSamplesCount, equals(15));
      expect(epochs[1].isUsable, isTrue); // 15 >= 10
      expect(epochs[1].hrCoveragePercent, closeTo(50.0, 0.1));
    });

    test('Rilevamento lacune temporali e flag qualità', () {
      final base = DateTime.utc(2026, 11, 10, 1, 0, 0);
      // Primi 5 secondi presenti, poi gap di 15 secondi, poi altri 5 campioni
      final samples = <HrSamplePoint>[
        HrSamplePoint(timestampUtc: base, hrBpm: 60),
        HrSamplePoint(timestampUtc: base.add(const Duration(seconds: 1)), hrBpm: 62),
        HrSamplePoint(timestampUtc: base.add(const Duration(seconds: 2)), hrBpm: 61),
        // Gap di 18 secondi fino al secondo 20
        HrSamplePoint(timestampUtc: base.add(const Duration(seconds: 20)), hrBpm: 65),
        HrSamplePoint(timestampUtc: base.add(const Duration(seconds: 21)), hrBpm: 64),
      ];

      final epochs = build30sEpochs(
        hrSamples: samples,
        rrBeats: [],
        minSamplesForUsable: 10,
        maxGapForUsableSeconds: 5.0,
      );

      expect(epochs.length, equals(1));
      final ep = epochs.first;
      expect(ep.hrSamplesCount, equals(5));
      expect(ep.maxGapSeconds, equals(18.0));
      expect(ep.isUsable, isFalse);
      expect(ep.qualityFlags, contains(EpochQualityFlag.insufficientSamples));
      expect(ep.qualityFlags, contains(EpochQualityFlag.excessiveGap));
      expect(ep.qualityFlags, contains(EpochQualityFlag.missingRr));
    });

    test('Flag valori estremi HR fuori range fisiologico', () {
      final base = DateTime.utc(2026, 11, 10, 1, 0, 0);
      final samples = List.generate(
        30,
        (i) => HrSamplePoint(
          timestampUtc: base.add(Duration(seconds: i)),
          hrBpm: i == 15 ? 230 : 60, // Spike anomalo a 230 BPM
        ),
      );

      final epochs = build30sEpochs(hrSamples: samples, rrBeats: []);
      expect(epochs.first.qualityFlags, contains(EpochQualityFlag.extremeValues));
    });
  });
}
