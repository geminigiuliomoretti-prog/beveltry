import '../dsp/hrv_rmssd.dart';
import 'cardiac_sleep_wake_estimator.dart';
import 'epoch_engine.dart';

/// Rappresenta il risultato di un candidato di metrica HRV o RHR.
class MetricCandidateResult {
  const MetricCandidateResult({
    required this.name,
    this.valueDirectMs,
    this.value1024Ms,
    required this.status,
    this.unavailabilityReason,
    this.validPairsCount = 0,
    this.coveragePercent = 0.0,
  });

  /// Nome identificativo del candidato.
  final String name;

  /// Valore calcolato con interpretazione ms diretti (WHOOP 5.0).
  final double? valueDirectMs;

  /// Valore convertito con standard Bluetooth SIG 1/1024s (raw * 1000 / 1024).
  final double? value1024Ms;

  /// Stato di provenienza della metrica.
  final MetricProvenanceStatus status;

  /// Motivazione scientifica o tecnica nel caso di metrica non disponibile.
  final String? unavailabilityReason;

  /// Numero di coppie R-R consecutive valide su cui è stato calcolato il valore.
  final int validPairsCount;

  /// Percentuale di copertura dei dati nella finestra di analisi.
  final double coveragePercent;

  bool get isAvailable => status != MetricProvenanceStatus.unavailable && valueDirectMs != null;
}

/// Risultato di una singola finestra rolling da 5 minuti per HRV RMSSD.
class Rolling5MinWindowResult {
  const Rolling5MinWindowResult({
    required this.startUtc,
    required this.endUtc,
    required this.rmssdDirectMs,
    required this.rmssd1024Ms,
    required this.validBeatsCount,
    required this.validPairsCount,
    required this.maxGapSeconds,
    required this.isValid,
  });

  final DateTime startUtc;
  final DateTime endUtc;
  final double? rmssdDirectMs;
  final double? rmssd1024Ms;
  final int validBeatsCount;
  final int validPairsCount;
  final double maxGapSeconds;
  final bool isValid;
}

/// Risultato completo del laboratorio finestre HRV.
class HrvWindowLabResult {
  const HrvWindowLabResult({
    required this.algorithmVersion,
    required this.wholeSleepRmssd,
    this.rolling5MinMeanMs,
    this.rolling5MinMedianMs,
    this.rolling5MinMinMs,
    this.rolling5MinMaxMs,
    required this.rolling5MinTotalWindows,
    required this.rolling5MinValidWindows,
    required this.rolling5MinWindows,
    required this.rmssdAllDeep,
    required this.rmssdLastDeepEpisode,
    required this.rmssdLast5MinDeep,
    required this.rmssdBest5MinDeep,
    required this.rmssdWeightedLateDeep,
  });

  final String algorithmVersion;

  /// RMSSD calcolato sull'intero intervallo di sonno effettivo (baseline scientifica).
  final MetricCandidateResult wholeSleepRmssd;

  /// Media dei valori RMSSD delle finestre mobili da 5 minuti valide.
  final double? rolling5MinMeanMs;

  /// Mediana dei valori RMSSD delle finestre mobili da 5 minuti valide.
  final double? rolling5MinMedianMs;

  /// Minimo RMSSD tra le finestre mobili da 5 minuti valide.
  final double? rolling5MinMinMs;

  /// Massimo RMSSD tra le finestre mobili da 5 minuti valide.
  final double? rolling5MinMaxMs;

  /// Numero totale di finestre da 5 minuti valutate nell'intervallo di sonno.
  final int rolling5MinTotalWindows;

  /// Numero di finestre da 5 minuti che hanno soddisfatto i criteri di qualità.
  final int rolling5MinValidWindows;

  /// Lista delle singole finestre da 5 minuti calcolate.
  final List<Rolling5MinWindowResult> rolling5MinWindows;

  /// Candidato B2: RMSSD di tutte le epoche di sonno profondo (Slow-Wave Sleep).
  final MetricCandidateResult rmssdAllDeep;

  /// Candidato B3: RMSSD dell'ultimo episodio di sonno profondo.
  final MetricCandidateResult rmssdLastDeepEpisode;

  /// Candidato B4: Ultimi 5 minuti validi dell'ultimo episodio di sonno profondo (candidato pubblico WHOOP).
  final MetricCandidateResult rmssdLast5MinDeep;

  /// Candidato B5: Migliore finestra da 5 minuti all'interno dell'ultimo episodio profondo (brevetto WHOOP).
  final MetricCandidateResult rmssdBest5MinDeep;

  /// Candidato B6: Media ponderata dinamica dei segmenti di sonno profondo orientata verso la fine notte.
  final MetricCandidateResult rmssdWeightedLateDeep;
}

/// Calcola il laboratorio comparativo di finestre HRV RMSSD per la notte.
HrvWindowLabResult calculateHrvWindowLab({
  required List<BeatInterval> beats,
  required DateTime sleepStartUtc,
  required DateTime sleepEndUtc,
  List<Epoch30s>? epochs,
  List<bool>? isDeepSleepEpochMask,
}) {
  const algorithmVersion = '1.0.0-hrv-lab';

  // 1. Filtra i battiti appartenenti all'intervallo di sonno
  final sleepBeats = beats.where((b) {
    return (b.timestampUtc.isAfter(sleepStartUtc) || b.timestampUtc.isAtSameMomentAs(sleepStartUtc)) &&
        (b.timestampUtc.isBefore(sleepEndUtc) || b.timestampUtc.isAtSameMomentAs(sleepEndUtc));
  }).toList();

  // 2. Calcolo RMSSD sull'intero intervallo di sonno utilizzabile
  final wholeHrv = calculateSegmentedHrv(
    beats: sleepBeats,
    gapThresholdSeconds: 2.0,
    minPhysiologicalMs: 300,
    maxPhysiologicalMs: 2000,
  );

  final sleepDurationSec = sleepEndUtc.difference(sleepStartUtc).inSeconds;
  final expectedBeatsWhole = sleepDurationSec > 0 ? (sleepDurationSec / 1.0) : 1.0;
  final wholeCoverage = (wholeHrv.validBeats / expectedBeatsWhole * 100.0).clamp(0.0, 100.0);

  final wholeSleepCandidate = MetricCandidateResult(
    name: 'rmssd_whole_sleep',
    valueDirectMs: wholeHrv.segmentedRmssdMs,
    value1024Ms: wholeHrv.segmentedRmssd1024Ms,
    status: wholeHrv.segmentedRmssdMs != null
        ? MetricProvenanceStatus.measured
        : MetricProvenanceStatus.unavailable,
    unavailabilityReason: wholeHrv.segmentedRmssdMs == null
        ? 'Dati R-R insufficienti nell\'intervallo di sonno'
        : null,
    validPairsCount: wholeHrv.validSuccessiveDiffsCount,
    coveragePercent: wholeCoverage,
  );

  // 3. Finestre mobili da 5 minuti (300 secondi, step 60 secondi)
  const windowSec = 300;
  const stepSec = 60;
  final rollingWindows = <Rolling5MinWindowResult>[];
  final validRmssdValues = <double>[];

  if (sleepDurationSec >= windowSec && sleepBeats.isNotEmpty) {
    var curStartMs = sleepStartUtc.millisecondsSinceEpoch;
    final endMs = sleepEndUtc.millisecondsSinceEpoch;

    while (curStartMs + (windowSec * 1000) <= endMs) {
      final curStart = DateTime.fromMillisecondsSinceEpoch(curStartMs, isUtc: true);
      final curEnd = DateTime.fromMillisecondsSinceEpoch(curStartMs + (windowSec * 1000), isUtc: true);

      final winBeats = sleepBeats.where((b) {
        return (b.timestampUtc.isAfter(curStart) || b.timestampUtc.isAtSameMomentAs(curStart)) &&
            b.timestampUtc.isBefore(curEnd);
      }).toList();

      // Criteri di qualità per finestra valida da 5 minuti:
      // - Almeno 120 battiti fisiologici (corrispondente a 24 bpm minimi in 5 min)
      // - Nessuna lacuna > 5.0 secondi
      final winHrv = calculateSegmentedHrv(
        beats: winBeats,
        gapThresholdSeconds: 2.0,
        minPhysiologicalMs: 300,
        maxPhysiologicalMs: 2000,
      );

      final isValid = winHrv.validBeats >= 120 &&
          winHrv.maxGapSeconds <= 5.0 &&
          winHrv.validSuccessiveDiffsCount >= 100 &&
          winHrv.segmentedRmssdMs != null;

      if (isValid && winHrv.segmentedRmssdMs != null) {
        validRmssdValues.add(winHrv.segmentedRmssdMs!);
      }

      rollingWindows.add(
        Rolling5MinWindowResult(
          startUtc: curStart,
          endUtc: curEnd,
          rmssdDirectMs: winHrv.segmentedRmssdMs,
          rmssd1024Ms: winHrv.segmentedRmssd1024Ms,
          validBeatsCount: winHrv.validBeats,
          validPairsCount: winHrv.validSuccessiveDiffsCount,
          maxGapSeconds: winHrv.maxGapSeconds,
          isValid: isValid,
        ),
      );

      curStartMs += stepSec * 1000;
    }
  }

  double? rollingMean;
  double? rollingMedian;
  double? rollingMin;
  double? rollingMax;

  if (validRmssdValues.isNotEmpty) {
    final sum = validRmssdValues.fold<double>(0.0, (a, b) => a + b);
    rollingMean = sum / validRmssdValues.length;

    final sorted = List<double>.from(validRmssdValues)..sort();
    final mid = sorted.length ~/ 2;
    rollingMedian = sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2.0;

    rollingMin = sorted.first;
    rollingMax = sorted.last;
  }

  // 4. Candidati basati sulle fasi di sonno profondo (Deep / SWS)
  // REGOLA DI INTEGRITÀ SCIENTIFICA:
  // Calcola SOLO se esiste una classificazione Deep comprovata (almeno 10 epoche / 5 min).
  // In assenza di accelerometria e PPG (TASK 08A), restituisce esplicitamente UNAVAILABLE.
  const unavailableDeepReason =
      'Stadiazione sonno profondo (Deep/SWS) non disponibile: richiede accelerometria e fotopletismografia PPG (prevista per TASK 08B). Nessun valore simulato o arbitrario.';

  var hasValidDeepStaging = false;
  if (epochs != null && isDeepSleepEpochMask != null && epochs.length == isDeepSleepEpochMask.length) {
    final deepEpochsCount = isDeepSleepEpochMask.where((d) => d).length;
    // Richiede almeno 10 epoche di deep sleep (5 minuti)
    if (deepEpochsCount >= 10) {
      hasValidDeepStaging = true;
    }
  }

  final MetricCandidateResult rmssdAllDeep;
  final MetricCandidateResult rmssdLastDeepEpisode;
  final MetricCandidateResult rmssdLast5MinDeep;
  final MetricCandidateResult rmssdBest5MinDeep;
  final MetricCandidateResult rmssdWeightedLateDeep;

  if (!hasValidDeepStaging) {
    rmssdAllDeep = const MetricCandidateResult(
      name: 'rmssd_all_deep',
      status: MetricProvenanceStatus.unavailable,
      unavailabilityReason: unavailableDeepReason,
    );
    rmssdLastDeepEpisode = const MetricCandidateResult(
      name: 'rmssd_last_deep_episode',
      status: MetricProvenanceStatus.unavailable,
      unavailabilityReason: unavailableDeepReason,
    );
    rmssdLast5MinDeep = const MetricCandidateResult(
      name: 'rmssd_last5_deep',
      status: MetricProvenanceStatus.unavailable,
      unavailabilityReason: unavailableDeepReason,
    );
    rmssdBest5MinDeep = const MetricCandidateResult(
      name: 'rmssd_best5_last_deep',
      status: MetricProvenanceStatus.unavailable,
      unavailabilityReason: unavailableDeepReason,
    );
    rmssdWeightedLateDeep = const MetricCandidateResult(
      name: 'rmssd_weighted_late_deep',
      status: MetricProvenanceStatus.unavailable,
      unavailabilityReason: unavailableDeepReason,
    );
  } else {
    // Calcolo deterministico se la maschera Deep viene fornita (per test futuri / TASK 08B)
    final deepEpochs = <Epoch30s>[];
    for (var i = 0; i < epochs!.length; i++) {
      if (isDeepSleepEpochMask![i]) {
        deepEpochs.add(epochs[i]);
      }
    }

    // 4.1 rmssd_all_deep
    final deepBeats = sleepBeats.where((b) {
      return deepEpochs.any((e) =>
          (b.timestampUtc.isAfter(e.startUtc) || b.timestampUtc.isAtSameMomentAs(e.startUtc)) &&
          b.timestampUtc.isBefore(e.endUtc));
    }).toList();

    final allDeepHrv = calculateSegmentedHrv(beats: deepBeats);
    rmssdAllDeep = MetricCandidateResult(
      name: 'rmssd_all_deep',
      valueDirectMs: allDeepHrv.segmentedRmssdMs,
      value1024Ms: allDeepHrv.segmentedRmssd1024Ms,
      status: allDeepHrv.segmentedRmssdMs != null
          ? MetricProvenanceStatus.estimated
          : MetricProvenanceStatus.unavailable,
      validPairsCount: allDeepHrv.validSuccessiveDiffsCount,
    );

    // 4.2 Individuazione ultimo episodio Deep
    final deepEpisodes = <List<Epoch30s>>[];
    var currentEpisode = <Epoch30s>[];

    for (var i = 0; i < epochs.length; i++) {
      if (isDeepSleepEpochMask![i]) {
        currentEpisode.add(epochs[i]);
      } else {
        if (currentEpisode.isNotEmpty) {
          deepEpisodes.add(List.unmodifiable(currentEpisode));
          currentEpisode = [];
        }
      }
    }
    if (currentEpisode.isNotEmpty) {
      deepEpisodes.add(List.unmodifiable(currentEpisode));
    }

    if (deepEpisodes.isEmpty) {
      rmssdLastDeepEpisode = const MetricCandidateResult(
        name: 'rmssd_last_deep_episode',
        status: MetricProvenanceStatus.unavailable,
        unavailabilityReason: 'Nessun episodio Deep identificato',
      );
      rmssdLast5MinDeep = const MetricCandidateResult(
        name: 'rmssd_last5_deep',
        status: MetricProvenanceStatus.unavailable,
        unavailabilityReason: 'Nessun episodio Deep identificato',
      );
      rmssdBest5MinDeep = const MetricCandidateResult(
        name: 'rmssd_best5_last_deep',
        status: MetricProvenanceStatus.unavailable,
        unavailabilityReason: 'Nessun episodio Deep identificato',
      );
      rmssdWeightedLateDeep = const MetricCandidateResult(
        name: 'rmssd_weighted_late_deep',
        status: MetricProvenanceStatus.unavailable,
        unavailabilityReason: 'Nessun episodio Deep identificato',
      );
    } else {
      final lastEp = deepEpisodes.last;
      final epStart = lastEp.first.startUtc;
      final epEnd = lastEp.last.endUtc;

      final lastEpBeats = sleepBeats.where((b) {
        return (b.timestampUtc.isAfter(epStart) || b.timestampUtc.isAtSameMomentAs(epStart)) &&
            b.timestampUtc.isBefore(epEnd);
      }).toList();

      final lastEpHrv = calculateSegmentedHrv(beats: lastEpBeats);
      rmssdLastDeepEpisode = MetricCandidateResult(
        name: 'rmssd_last_deep_episode',
        valueDirectMs: lastEpHrv.segmentedRmssdMs,
        value1024Ms: lastEpHrv.segmentedRmssd1024Ms,
        status: lastEpHrv.segmentedRmssdMs != null
            ? MetricProvenanceStatus.estimated
            : MetricProvenanceStatus.unavailable,
        validPairsCount: lastEpHrv.validSuccessiveDiffsCount,
      );

      // 4.3 Last 5 minutes of last deep episode
      final last5MinStart = epEnd.subtract(const Duration(minutes: 5));
      final last5MinBeats = lastEpBeats.where((b) {
        return b.timestampUtc.isAfter(last5MinStart) || b.timestampUtc.isAtSameMomentAs(last5MinStart);
      }).toList();

      final last5Hrv = calculateSegmentedHrv(beats: last5MinBeats);
      rmssdLast5MinDeep = MetricCandidateResult(
        name: 'rmssd_last5_deep',
        valueDirectMs: last5Hrv.segmentedRmssdMs,
        value1024Ms: last5Hrv.segmentedRmssd1024Ms,
        status: last5Hrv.segmentedRmssdMs != null
            ? MetricProvenanceStatus.estimated
            : MetricProvenanceStatus.unavailable,
        validPairsCount: last5Hrv.validSuccessiveDiffsCount,
      );

      // 4.4 Best 5 min inside last deep episode
      // Rolling 5 min inside last episode with lowest gap / max valid pairs
      double? best5Val;
      var bestPairs = -1;
      final epDurationSec = epEnd.difference(epStart).inSeconds;

      if (epDurationSec >= 300) {
        var curMs = epStart.millisecondsSinceEpoch;
        final epEndMs = epEnd.millisecondsSinceEpoch;
        while (curMs + 300000 <= epEndMs) {
          final wS = DateTime.fromMillisecondsSinceEpoch(curMs, isUtc: true);
          final wE = DateTime.fromMillisecondsSinceEpoch(curMs + 300000, isUtc: true);
          final bSub = lastEpBeats.where((b) =>
              (b.timestampUtc.isAfter(wS) || b.timestampUtc.isAtSameMomentAs(wS)) &&
              b.timestampUtc.isBefore(wE)).toList();

          final h = calculateSegmentedHrv(beats: bSub);
          if (h.segmentedRmssdMs != null && h.validSuccessiveDiffsCount > bestPairs) {
            bestPairs = h.validSuccessiveDiffsCount;
            best5Val = h.segmentedRmssdMs;
          }
          curMs += 60000;
        }
      }

      rmssdBest5MinDeep = MetricCandidateResult(
        name: 'rmssd_best5_last_deep',
        valueDirectMs: best5Val,
        value1024Ms: best5Val != null ? best5Val * 1000.0 / 1024.0 : null,
        status: best5Val != null
            ? MetricProvenanceStatus.estimated
            : MetricProvenanceStatus.unavailable,
        validPairsCount: bestPairs > 0 ? bestPairs : 0,
      );

      // 4.5 Weighted late deep RMSSD
      // Linear weighting of deep episodes by their temporal position in sleep
      var sumWeight = 0.0;
      var sumWeightedRmssd = 0.0;
      for (var epIdx = 0; epIdx < deepEpisodes.length; epIdx++) {
        final ep = deepEpisodes[epIdx];
        final s = ep.first.startUtc;
        final e = ep.last.endUtc;
        final b = sleepBeats.where((x) =>
            (x.timestampUtc.isAfter(s) || x.timestampUtc.isAtSameMomentAs(s)) &&
            x.timestampUtc.isBefore(e)).toList();
        final h = calculateSegmentedHrv(beats: b);
        if (h.segmentedRmssdMs != null) {
          final weight = (epIdx + 1.0) / deepEpisodes.length;
          sumWeightedRmssd += h.segmentedRmssdMs! * weight;
          sumWeight += weight;
        }
      }

      final weightedVal = sumWeight > 0.0 ? sumWeightedRmssd / sumWeight : null;
      rmssdWeightedLateDeep = MetricCandidateResult(
        name: 'rmssd_weighted_late_deep',
        valueDirectMs: weightedVal,
        value1024Ms: weightedVal != null ? weightedVal * 1000.0 / 1024.0 : null,
        status: weightedVal != null
            ? MetricProvenanceStatus.estimated
            : MetricProvenanceStatus.unavailable,
      );
    }
  }

  return HrvWindowLabResult(
    algorithmVersion: algorithmVersion,
    wholeSleepRmssd: wholeSleepCandidate,
    rolling5MinMeanMs: rollingMean,
    rolling5MinMedianMs: rollingMedian,
    rolling5MinMinMs: rollingMin,
    rolling5MinMaxMs: rollingMax,
    rolling5MinTotalWindows: rollingWindows.length,
    rolling5MinValidWindows: validRmssdValues.length,
    rolling5MinWindows: List.unmodifiable(rollingWindows),
    rmssdAllDeep: rmssdAllDeep,
    rmssdLastDeepEpisode: rmssdLastDeepEpisode,
    rmssdLast5MinDeep: rmssdLast5MinDeep,
    rmssdBest5MinDeep: rmssdBest5MinDeep,
    rmssdWeightedLateDeep: rmssdWeightedLateDeep,
  );
}
