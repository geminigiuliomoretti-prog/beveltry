import 'dart:math' as math;

import '../dsp/hrv_rmssd.dart';
import '../records/night_session_summary.dart';

/// Flag di qualità per un'epoca da 30 secondi.
enum EpochQualityFlag {
  /// Meno di 10 campioni HR nell'epoca (copertura < 33%).
  insufficientSamples,

  /// Lacuna temporale superiore a 5 secondi tra campioni consecutivi.
  excessiveGap,

  /// Valore HR al di fuori del range fisiologico notturno plausibile (30-220 BPM).
  extremeValues,

  /// Nessun intervallo R-R ricevuto durante l'epoca.
  missingRr,
}

/// Rappresenta una singola epoca deterministica da 30 secondi.
class Epoch30s {
  const Epoch30s({
    required this.index,
    required this.startUtc,
    required this.endUtc,
    required this.hrSamplesCount,
    this.hrMean,
    this.hrMedian,
    this.hrMin,
    this.hrMax,
    this.hrStd,
    this.hrSlope = 0.0,
    required this.rrIntervalsCount,
    required this.validRrIntervalsCount,
    required this.maxGapSeconds,
    required this.hrCoveragePercent,
    required this.isUsable,
    required this.qualityFlags,
  });

  /// Indice progressivo dell'epoca (0-based) dall'inizio della sessione.
  final int index;

  /// Timestamp UTC di inizio dell'epoca (incluso).
  final DateTime startUtc;

  /// Timestamp UTC di fine dell'epoca (escluso).
  final DateTime endUtc;

  /// Numero di campioni HR presenti nell'epoca.
  final int hrSamplesCount;

  /// Frequenza cardiaca media nell'epoca (BPM).
  final double? hrMean;

  /// Frequenza cardiaca mediana nell'epoca (BPM).
  final double? hrMedian;

  /// Frequenza cardiaca minima nell'epoca (BPM).
  final int? hrMin;

  /// Frequenza cardiaca massima nell'epoca (BPM).
  final int? hrMax;

  /// Deviazione standard (variabilità) della frequenza cardiaca nell'epoca.
  final double? hrStd;

  /// Pendenza lineare (trend) della frequenza cardiaca nell'epoca (BPM/secondo).
  final double hrSlope;

  /// Numero totale di intervalli R-R associati fisiologicamente a questa epoca.
  final int rrIntervalsCount;

  /// Numero di intervalli R-R fisiologicamente validi [300, 2000] ms.
  final int validRrIntervalsCount;

  /// Massima lacuna osservata tra campioni consecutivi nell'epoca (secondi).
  final double maxGapSeconds;

  /// Percentuale di copertura temporale rispetto ai 30 campioni attesi (assumendo 1 Hz).
  final double hrCoveragePercent;

  /// Indica se l'epoca dispone di dati sufficienti per essere utilizzata nelle analisi.
  final bool isUsable;

  /// Insieme di flag di qualità associati all'epoca.
  final Set<EpochQualityFlag> qualityFlags;

  /// Durata dell'epoca in secondi (sempre 30.0).
  double get durationSeconds => 30.0;
}

/// Ricostruisce i timestamp fisiologici stimati di ciascun battito.
///
/// Previene la confusione metodologica tra l'orario di ricezione della notifica BLE
/// e l'orario fisiologico effettivo di accadimento di ogni battito cardiaco.
/// Quando una singola notifica BLE contiene più intervalli R-R (es. ordinals 0, 1):
/// l'ultimo battito è avvenuto immediatamente prima dell'orario di notifica,
/// mentre i battiti precedenti sono avvenuti arretrati nel tempo della somma
/// dei rispettivi intervalli R-R.
List<BeatInterval> reconstructPhysiologicalBeats(List<BeatInterval> rawBeats) {
  if (rawBeats.isEmpty) return const [];

  // Raggruppa i battiti per timestamp di notifica (in millisecondi UTC)
  final Map<int, List<BeatInterval>> grouped = {};
  for (final beat in rawBeats) {
    final key = beat.timestampUtc.millisecondsSinceEpoch;
    (grouped[key] ??= []).add(beat);
  }

  final reconstructed = <BeatInterval>[];

  // Ordina per timestamp di notifica crescente
  final sortedKeys = grouped.keys.toList()..sort();

  for (final notifMs in sortedKeys) {
    final beatsInNotif = grouped[notifMs]!
      ..sort((a, b) => a.beatOrdinal.compareTo(b.beatOrdinal));

    if (beatsInNotif.length == 1) {
      reconstructed.add(beatsInNotif.first);
    } else {
      // Notifica multipla: calcola i timestamp fisiologici arretrati
      // L'ultimo battito (indice length-1) è avvenuto a notifMs.
      // I battiti precedenti k sono avvenuti a: notifMs - sum(rr[k+1..end])
      final n = beatsInNotif.length;
      final offsetsMs = List<int>.filled(n, 0);

      var cumulative = 0;
      for (var i = n - 1; i >= 1; i--) {
        cumulative += beatsInNotif[i].rrMs;
        offsetsMs[i - 1] = cumulative;
      }

      for (var i = 0; i < n; i++) {
        final b = beatsInNotif[i];
        final physioTimeMs = notifMs - offsetsMs[i];
        reconstructed.add(
          BeatInterval(
            timestampUtc: DateTime.fromMillisecondsSinceEpoch(physioTimeMs, isUtc: true),
            rrMs: b.rrMs,
            beatOrdinal: b.beatOrdinal,
          ),
        );
      }
    }
  }

  // Ordina per timestamp fisiologico finale crescente
  reconstructed.sort((a, b) => a.timestampUtc.compareTo(b.timestampUtc));
  return reconstructed;
}

/// Costruisce una sequenza deterministica di epoche da 30 secondi.
///
/// Segmenta la sessione dall'inizio specificato a passi rigorosi di 30 secondi,
/// gestendo l'attraversamento della mezzanotte tramite timestamp UTC invarianti
/// e identificando epoche incomplete o con gap.
List<Epoch30s> build30sEpochs({
  required List<HrSamplePoint> hrSamples,
  required List<BeatInterval> rrBeats,
  DateTime? sessionStartUtc,
  DateTime? sessionEndUtc,
  int minSamplesForUsable = 10,
  double maxGapForUsableSeconds = 5.0,
  int minPhysiologicalRrMs = 300,
  int maxPhysiologicalRrMs = 2000,
}) {
  if (hrSamples.isEmpty && rrBeats.isEmpty) {
    return const [];
  }

  // 1. Determina l'inizio e la fine della sessione
  DateTime start;
  if (sessionStartUtc != null) {
    start = sessionStartUtc.toUtc();
  } else if (hrSamples.isNotEmpty) {
    start = hrSamples.first.timestampUtc.toUtc();
  } else {
    start = rrBeats.first.timestampUtc.toUtc();
  }

  DateTime end;
  if (sessionEndUtc != null) {
    end = sessionEndUtc.toUtc();
  } else if (hrSamples.isNotEmpty) {
    end = hrSamples.last.timestampUtc.toUtc();
  } else {
    end = rrBeats.last.timestampUtc.toUtc();
  }

  if (end.isBefore(start)) {
    return const [];
  }

  // 2. Ricostruisci i timestamp fisiologici dei battiti
  final physioBeats = reconstructPhysiologicalBeats(rrBeats);

  final startMs = start.millisecondsSinceEpoch;
  final endMs = end.millisecondsSinceEpoch;
  const epochDurationMs = 30000; // 30 secondi

  final totalDurationMs = endMs - startMs;
  final epochsCount = totalDurationMs <= 0
      ? 1
      : ((totalDurationMs + epochDurationMs - 1) ~/ epochDurationMs);

  final epochs = <Epoch30s>[];

  var sIdx = 0;
  var bIdx = 0;
  final nSamples = hrSamples.length;
  final nBeats = physioBeats.length;

  for (var i = 0; i < epochsCount; i++) {
    final epStartMs = startMs + (i * epochDurationMs);
    final epEndMs = epStartMs + epochDurationMs;
    final epStart = DateTime.fromMillisecondsSinceEpoch(epStartMs, isUtc: true);
    final epEnd = DateTime.fromMillisecondsSinceEpoch(epEndMs, isUtc: true);

    // Raccoglie campioni HR nell'intervallo [epStartMs, epEndMs)
    final epHrs = <int>[];
    final epSampleTimes = <int>[];

    while (sIdx < nSamples && hrSamples[sIdx].timestampUtc.millisecondsSinceEpoch < epEndMs) {
      final t = hrSamples[sIdx].timestampUtc.millisecondsSinceEpoch;
      if (t >= epStartMs) {
        epHrs.add(hrSamples[sIdx].hrBpm);
        epSampleTimes.add(t);
      }
      sIdx++;
    }
    // Riavvolgi leggermente l'indice se necessario
    while (sIdx > 0 && hrSamples[sIdx - 1].timestampUtc.millisecondsSinceEpoch >= epEndMs) {
      sIdx--;
    }

    // Raccoglie battiti RR nell'intervallo [epStartMs, epEndMs)
    final epRrs = <int>[];
    var validRrCount = 0;

    while (bIdx < nBeats && physioBeats[bIdx].timestampUtc.millisecondsSinceEpoch < epEndMs) {
      final t = physioBeats[bIdx].timestampUtc.millisecondsSinceEpoch;
      if (t >= epStartMs) {
        final rr = physioBeats[bIdx].rrMs;
        epRrs.add(rr);
        if (rr >= minPhysiologicalRrMs && rr <= maxPhysiologicalRrMs) {
          validRrCount++;
        }
      }
      bIdx++;
    }
    while (bIdx > 0 && physioBeats[bIdx - 1].timestampUtc.millisecondsSinceEpoch >= epEndMs) {
      bIdx--;
    }

    // Calcolo statistiche dell'epoca
    final flags = <EpochQualityFlag>{};
    final hrCount = epHrs.length;
    double? meanHr;
    double? medianHr;
    int? minHr;
    int? maxHr;
    double? stdHr;
    var slope = 0.0;
    var maxGapSec = 0.0;

    if (hrCount == 0) {
      flags.add(EpochQualityFlag.insufficientSamples);
      flags.add(EpochQualityFlag.excessiveGap);
      maxGapSec = 30.0;
    } else {
      final sumHr = epHrs.fold<int>(0, (a, b) => a + b);
      meanHr = sumHr / hrCount;

      final sorted = List<int>.from(epHrs)..sort();
      final mid = hrCount ~/ 2;
      medianHr = hrCount.isOdd
          ? sorted[mid].toDouble()
          : (sorted[mid - 1] + sorted[mid]) / 2.0;
      minHr = sorted.first;
      maxHr = sorted.last;

      if (minHr < 30 || maxHr > 220) {
        flags.add(EpochQualityFlag.extremeValues);
      }

      // Deviazione standard
      var sumSqDiff = 0.0;
      for (final val in epHrs) {
        final d = val - meanHr;
        sumSqDiff += d * d;
      }
      stdHr = math.sqrt(sumSqDiff / hrCount);

      // Pendenza lineare (regressione semplice BPM vs secondi)
      if (hrCount > 1) {
        final t0 = epSampleTimes[0];
        final xs = epSampleTimes.map((t) => (t - t0) / 1000.0).toList();
        final xMean = xs.fold<double>(0.0, (a, b) => a + b) / hrCount;
        var cov = 0.0;
        var varX = 0.0;
        for (var k = 0; k < hrCount; k++) {
          final dx = xs[k] - xMean;
          cov += dx * (epHrs[k] - meanHr);
          varX += dx * dx;
        }
        slope = varX > 0.0 ? (cov / varX) : 0.0;

        // Gap massimo tra campioni consecutivi
        for (var k = 1; k < hrCount; k++) {
          final gap = (epSampleTimes[k] - epSampleTimes[k - 1]) / 1000.0;
          if (gap > maxGapSec) {
            maxGapSec = gap;
          }
        }
      }

      if (hrCount < minSamplesForUsable) {
        flags.add(EpochQualityFlag.insufficientSamples);
      }
      if (maxGapSec > maxGapForUsableSeconds) {
        flags.add(EpochQualityFlag.excessiveGap);
      }
    }

    if (epRrs.isEmpty) {
      flags.add(EpochQualityFlag.missingRr);
    }

    final coverage = (hrCount / 30.0 * 100.0).clamp(0.0, 100.0);
    final isUsable = hrCount >= minSamplesForUsable && maxGapSec <= maxGapForUsableSeconds;

    epochs.add(
      Epoch30s(
        index: i,
        startUtc: epStart,
        endUtc: epEnd,
        hrSamplesCount: hrCount,
        hrMean: meanHr,
        hrMedian: medianHr,
        hrMin: minHr,
        hrMax: maxHr,
        hrStd: stdHr,
        hrSlope: slope,
        rrIntervalsCount: epRrs.length,
        validRrIntervalsCount: validRrCount,
        maxGapSeconds: maxGapSec,
        hrCoveragePercent: coverage,
        isUsable: isUsable,
        qualityFlags: flags,
      ),
    );
  }

  return List.unmodifiable(epochs);
}
