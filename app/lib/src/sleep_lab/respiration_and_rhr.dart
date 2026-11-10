import 'dart:math' as math;

import '../dsp/hrv_rmssd.dart';
import '../records/night_session_summary.dart';
import 'cardiac_sleep_wake_estimator.dart';
import 'epoch_engine.dart';
import 'hrv_window_lab.dart';

/// Risultato di una singola finestra di stima della frequenza respiratoria basata su RSA.
class RespirationWindowEstimate {
  const RespirationWindowEstimate({
    required this.startUtc,
    required this.endUtc,
    required this.breathsPerMinute,
    required this.snr,
    required this.validBeatsCount,
    required this.maxGapSeconds,
    required this.isValid,
  });

  final DateTime startUtc;
  final DateTime endUtc;
  final double breathsPerMinute;
  final double snr;
  final int validBeatsCount;
  final double maxGapSeconds;
  final bool isValid;
}

/// Risultato complessivo della stima della frequenza respiratoria notturna.
class RespirationResult {
  const RespirationResult({
    required this.algorithmVersion,
    this.medianBreathsPerMinute,
    this.meanBreathsPerMinute,
    this.minBreathsPerMinute,
    this.maxBreathsPerMinute,
    required this.validWindowsCount,
    required this.totalWindowsEvaluated,
    required this.status,
    this.unavailabilityReason,
    required this.windowEstimates,
  });

  final String algorithmVersion;

  /// Frequenza respiratoria mediana della notte (respiri al minuto).
  final double? medianBreathsPerMinute;

  /// Frequenza respiratoria media delle finestre valide.
  final double? meanBreathsPerMinute;

  /// Minima frequenza respiratoria osservata nelle finestre valide.
  final double? minBreathsPerMinute;

  /// Massima frequenza respiratoria osservata nelle finestre valide.
  final double? maxBreathsPerMinute;

  /// Numero di finestre da 4 minuti che hanno superato i rigorosi controlli di qualità spettrale.
  final int validWindowsCount;

  /// Numero totale di finestre da 4 minuti esaminate durante il sonno.
  final int totalWindowsEvaluated;

  /// Stato di provenienza della metrica.
  final MetricProvenanceStatus status;

  /// Motivazione esplicita se la metrica è contrassegnata come non disponibile.
  final String? unavailabilityReason;

  /// Lista delle singole finestre valutate.
  final List<RespirationWindowEstimate> windowEstimates;
}

/// Risultato del calcolo di Resting Heart Rate (RHR) notturno.
class RhrResult {
  const RhrResult({
    required this.algorithmVersion,
    this.min5MinBpm,
    this.wholeSleepMeanBpm,
    required this.finalDeepMeanBpm,
    required this.finalDeepLast5MinBpm,
    required this.finalDeepBest5MinBpm,
    required this.min5MinStatus,
  });

  final String algorithmVersion;

  /// Minimo della media HR su finestra rolling da 5 minuti (metrica indipendente e misurata).
  final int? min5MinBpm;

  /// Media della frequenza cardiaca sull'intero intervallo di sonno.
  final double? wholeSleepMeanBpm;

  /// Candidato RHR 1: Media HR durante tutte le epoche di sonno profondo.
  final MetricCandidateResult finalDeepMeanBpm;

  /// Candidato RHR 2: Media HR negli ultimi 5 minuti dell'ultimo episodio profondo.
  final MetricCandidateResult finalDeepLast5MinBpm;

  /// Candidato RHR 3: Media HR della migliore finestra da 5 minuti dell'ultimo episodio profondo.
  final MetricCandidateResult finalDeepBest5MinBpm;

  /// Provenienza di min5MinBpm (sempre `measured` se ci sono campioni).
  final MetricProvenanceStatus min5MinStatus;
}

/// Calcola l'RHR notturno e prepara i candidati SWS.
RhrResult calculateRhrWindowLab({
  required List<HrSamplePoint> hrSamples,
  required DateTime sleepStartUtc,
  required DateTime sleepEndUtc,
  List<Epoch30s>? epochs,
  List<bool>? isDeepSleepEpochMask,
}) {
  const algorithmVersion = '1.0.0-rhr-lab';

  // Filtra campioni nell'intervallo di sonno
  final sleepSamples = hrSamples.where((s) {
    return (s.timestampUtc.isAfter(sleepStartUtc) || s.timestampUtc.isAtSameMomentAs(sleepStartUtc)) &&
        (s.timestampUtc.isBefore(sleepEndUtc) || s.timestampUtc.isAtSameMomentAs(sleepEndUtc));
  }).toList();

  int? min5Min;
  double? wholeSleepMean;

  if (sleepSamples.isNotEmpty) {
    final hrVals = sleepSamples.map((s) => s.hrBpm).toList();
    final sum = hrVals.fold<int>(0, (a, b) => a + b);
    wholeSleepMean = sum / hrVals.length;

    // Rolling 5-min window (300 campioni nominali ad 1 Hz)
    const winSize = 300;
    if (hrVals.length >= winSize) {
      var currentSum = 0;
      for (var i = 0; i < winSize; i++) {
        currentSum += hrVals[i];
      }
      var minRollingSum = currentSum;

      for (var i = winSize; i < hrVals.length; i++) {
        currentSum += hrVals[i] - hrVals[i - winSize];
        if (currentSum < minRollingSum) {
          minRollingSum = currentSum;
        }
      }
      min5Min = (minRollingSum / winSize).round();
    } else {
      min5Min = hrVals.reduce(math.min);
    }
  }

  // Candidati relativi al Deep Sleep:
  // Se il sonno profondo non è validato, imposta esplicitamente UNAVAILABLE.
  const deepUnavailableReason =
      'Richiede stadiazione delle fasi del sonno validata con accelerometria e PPG (TASK 08B).';

  var hasValidDeep = false;
  if (epochs != null && isDeepSleepEpochMask != null && epochs.length == isDeepSleepEpochMask.length) {
    if (isDeepSleepEpochMask.where((d) => d).length >= 10) {
      hasValidDeep = true;
    }
  }

  final MetricCandidateResult finalDeepMean;
  final MetricCandidateResult finalDeepLast5;
  final MetricCandidateResult finalDeepBest5;

  if (!hasValidDeep) {
    finalDeepMean = const MetricCandidateResult(
      name: 'rhr_final_deep_mean',
      status: MetricProvenanceStatus.unavailable,
      unavailabilityReason: deepUnavailableReason,
    );
    finalDeepLast5 = const MetricCandidateResult(
      name: 'rhr_final_deep_last5',
      status: MetricProvenanceStatus.unavailable,
      unavailabilityReason: deepUnavailableReason,
    );
    finalDeepBest5 = const MetricCandidateResult(
      name: 'rhr_final_deep_best5',
      status: MetricProvenanceStatus.unavailable,
      unavailabilityReason: deepUnavailableReason,
    );
  } else {
    // Calcolo condizionato per estensione futura
    final deepEpochs = <Epoch30s>[];
    for (var i = 0; i < epochs!.length; i++) {
      if (isDeepSleepEpochMask![i]) deepEpochs.add(epochs[i]);
    }
    final deepMeans = deepEpochs.where((e) => e.hrMean != null).map((e) => e.hrMean!).toList();
    final avgDeep = deepMeans.isNotEmpty
        ? deepMeans.reduce((a, b) => a + b) / deepMeans.length
        : null;

    finalDeepMean = MetricCandidateResult(
      name: 'rhr_final_deep_mean',
      valueDirectMs: avgDeep,
      status: avgDeep != null ? MetricProvenanceStatus.estimated : MetricProvenanceStatus.unavailable,
    );
    finalDeepLast5 = const MetricCandidateResult(
      name: 'rhr_final_deep_last5',
      status: MetricProvenanceStatus.unavailable,
      unavailabilityReason: 'Non sufficienti epoche finali Deep',
    );
    finalDeepBest5 = const MetricCandidateResult(
      name: 'rhr_final_deep_best5',
      status: MetricProvenanceStatus.unavailable,
      unavailabilityReason: 'Non sufficienti epoche finali Deep',
    );
  }

  return RhrResult(
    algorithmVersion: algorithmVersion,
    min5MinBpm: min5Min,
    wholeSleepMeanBpm: wholeSleepMean,
    finalDeepMeanBpm: finalDeepMean,
    finalDeepLast5MinBpm: finalDeepLast5,
    finalDeepBest5MinBpm: finalDeepBest5,
    min5MinStatus: min5Min != null ? MetricProvenanceStatus.measured : MetricProvenanceStatus.unavailable,
  );
}

/// Stimatore sperimentale della frequenza respiratoria basato sull'Aritmia Sinusale Respiratoria (RSA).
///
/// DOCUMENTAZIONE DELL'ALGORITMO v1.0.0:
/// 1. Prende in input la serie temporale dei battiti cardiaci con timestamp fisiologici.
/// 2. Filtra gli intervalli R-R fisiologici [300, 2000] ms inclusi nell'intervallo di sonno.
/// 3. Esegue finestre mobili di 4 minuti (240 secondi) con step di 60 secondi.
/// 4. Criteri di qualità per finestra:
///    - Almeno 120 battiti nell'intervallo.
///    - Massima lacuna tra battiti $\le 3.0$ secondi.
/// 5. Ricampionamento della serie R-R su griglia uniforme a 4 Hz (dt = 0.25s) tramite interpolazione lineare.
/// 6. Detrending (rimozione della media).
/// 7. Calcolo della trasformata discreta di Fourier (DFT) nella banda fisiologica respiratoria:
///    frequenze tra 0.15 Hz e 0.45 Hz (da 9 a 27 respiri al minuto) a passi di 0.005 Hz (0.3 RPM).
/// 8. Identificazione del picco di potenza $P_{max}$ e del rapporto segnale/rumore (SNR) rispetto
///    alla potenza media della banda respiratoria.
/// 9. Criterio di ammissione: $SNR \ge 2.0$.
/// 10. Se almeno 10 finestre superano il test, calcola la mediana notturna con stato `EXPERIMENTAL`.
///     Altrimenti, restituisce `UNAVAILABLE` senza inventare alcun dato.
RespirationResult estimateRespirationRsa({
  required List<BeatInterval> beats,
  required DateTime sleepStartUtc,
  required DateTime sleepEndUtc,
  int minValidWindowsRequired = 10,
  double windowDurationSeconds = 240.0, // 4 minuti
  double stepDurationSeconds = 60.0,    // 1 minuto
  int minBeatsPerWindow = 120,
  double maxGapAllowedSeconds = 3.0,
  double minSnrThreshold = 2.0,
}) {
  const algorithmVersion = '1.0.0-rsa-respiration';

  final physioBeats = beats.where((b) {
    final isPhysio = b.rrMs >= 300 && b.rrMs <= 2000;
    final inSleep = (b.timestampUtc.isAfter(sleepStartUtc) || b.timestampUtc.isAtSameMomentAs(sleepStartUtc)) &&
        (b.timestampUtc.isBefore(sleepEndUtc) || b.timestampUtc.isAtSameMomentAs(sleepEndUtc));
    return isPhysio && inSleep;
  }).toList();

  if (physioBeats.length < minBeatsPerWindow) {
    return const RespirationResult(
      algorithmVersion: algorithmVersion,
      validWindowsCount: 0,
      totalWindowsEvaluated: 0,
      status: MetricProvenanceStatus.unavailable,
      unavailabilityReason: 'Numero insufficiente di battiti fisiologici nell\'intervallo di sonno',
      windowEstimates: [],
    );
  }

  final sleepDurationSec = sleepEndUtc.difference(sleepStartUtc).inSeconds;
  if (sleepDurationSec < windowDurationSeconds) {
    return const RespirationResult(
      algorithmVersion: algorithmVersion,
      validWindowsCount: 0,
      totalWindowsEvaluated: 0,
      status: MetricProvenanceStatus.unavailable,
      unavailabilityReason: 'Durata della sessione inferiore a una singola finestra di analisi (4 min)',
      windowEstimates: [],
    );
  }

  // Griglia di interpolazione a 4 Hz
  const fs = 4.0;
  const dt = 1.0 / fs;

  final windowEstimates = <RespirationWindowEstimate>[];
  final validRpms = <double>[];

  final startMs = sleepStartUtc.millisecondsSinceEpoch;
  final endMs = sleepEndUtc.millisecondsSinceEpoch;
  final winDurationMs = (windowDurationSeconds * 1000).toInt();
  final stepDurationMs = (stepDurationSeconds * 1000).toInt();

  var curStartMs = startMs;

  while (curStartMs + winDurationMs <= endMs) {
    final curStart = DateTime.fromMillisecondsSinceEpoch(curStartMs, isUtc: true);
    final curEnd = DateTime.fromMillisecondsSinceEpoch(curStartMs + winDurationMs, isUtc: true);

    final winBeats = physioBeats.where((b) {
      return (b.timestampUtc.isAfter(curStart) || b.timestampUtc.isAtSameMomentAs(curStart)) &&
          b.timestampUtc.isBefore(curEnd);
    }).toList();

    var maxGapSec = 0.0;
    if (winBeats.length > 1) {
      for (var i = 1; i < winBeats.length; i++) {
        final g = winBeats[i].timestampUtc.difference(winBeats[i - 1].timestampUtc).inMilliseconds / 1000.0;
        if (g > maxGapSec) maxGapSec = g;
      }
    } else {
      maxGapSec = windowDurationSeconds;
    }

    final hasEnoughBeats = winBeats.length >= minBeatsPerWindow;
    final isContinuous = maxGapSec <= maxGapAllowedSeconds;

    if (!hasEnoughBeats || !isContinuous) {
      windowEstimates.add(
        RespirationWindowEstimate(
          startUtc: curStart,
          endUtc: curEnd,
          breathsPerMinute: 0.0,
          snr: 0.0,
          validBeatsCount: winBeats.length,
          maxGapSeconds: maxGapSec,
          isValid: false,
        ),
      );
      curStartMs += stepDurationMs;
      continue;
    }

    // Ricampionamento uniforme a 4 Hz
    final timesSec = winBeats.map((b) => (b.timestampUtc.millisecondsSinceEpoch - curStartMs) / 1000.0).toList();
    final rrValues = winBeats.map((b) => b.rrMs.toDouble()).toList();

    final numGridPoints = (windowDurationSeconds * fs).toInt();
    final resampledRr = List<double>.filled(numGridPoints, 0.0);

    var bIdx = 0;
    final nBeats = timesSec.length;

    for (var k = 0; k < numGridPoints; k++) {
      final tGrid = k * dt;
      while (bIdx < nBeats - 2 && timesSec[bIdx + 1] < tGrid) {
        bIdx++;
      }
      final t0 = timesSec[bIdx];
      final t1 = timesSec[bIdx + 1];
      final v0 = rrValues[bIdx];
      final v1 = rrValues[bIdx + 1];
      if (t1 == t0) {
        resampledRr[k] = v0;
      } else {
        resampledRr[k] = v0 + (v1 - v0) * (tGrid - t0) / (t1 - t0);
      }
    }

    // Detrending (rimozione media)
    final meanVal = resampledRr.reduce((a, b) => a + b) / numGridPoints;
    for (var k = 0; k < numGridPoints; k++) {
      resampledRr[k] -= meanVal;
    }

    // DFT nella banda 0.15 Hz - 0.45 Hz (9 - 27 RPM) a passi di 0.005 Hz
    var bestPower = 0.0;
    var bestFreq = 0.0;
    final powers = <double>[];

    const minFreq = 0.15;
    const maxFreq = 0.45;
    const freqStep = 0.005;
    final freqStepsCount = ((maxFreq - minFreq) / freqStep).round() + 1;

    for (var step = 0; step < freqStepsCount; step++) {
      final freq = minFreq + (step * freqStep);
      var cosSum = 0.0;
      var sinSum = 0.0;

      for (var n = 0; n < numGridPoints; n++) {
        final angle = 2.0 * math.pi * freq * (n * dt);
        final x = resampledRr[n];
        cosSum += x * math.cos(angle);
        sinSum += x * math.sin(angle);
      }

      final power = (cosSum * cosSum) + (sinSum * sinSum);
      powers.add(power);

      if (power > bestPower) {
        bestPower = power;
        bestFreq = freq;
      }
    }

    final avgPower = powers.isNotEmpty
        ? powers.reduce((a, b) => a + b) / powers.length
        : 0.0;
    final snr = bestPower / (avgPower + 1e-9);

    final isValidWindow = snr >= minSnrThreshold;
    final rpm = bestFreq * 60.0;

    if (isValidWindow) {
      validRpms.add(rpm);
    }

    windowEstimates.add(
      RespirationWindowEstimate(
        startUtc: curStart,
        endUtc: curEnd,
        breathsPerMinute: rpm,
        snr: snr,
        validBeatsCount: winBeats.length,
        maxGapSeconds: maxGapSec,
        isValid: isValidWindow,
      ),
    );

    curStartMs += stepDurationMs;
  }

  // Risultato complessivo notturno
  if (validRpms.length >= minValidWindowsRequired) {
    validRpms.sort();
    final mid = validRpms.length ~/ 2;
    final medianRpm = validRpms.length.isOdd
        ? validRpms[mid]
        : (validRpms[mid - 1] + validRpms[mid]) / 2.0;

    final sum = validRpms.reduce((a, b) => a + b);
    final meanRpm = sum / validRpms.length;

    return RespirationResult(
      algorithmVersion: algorithmVersion,
      medianBreathsPerMinute: double.parse(medianRpm.toStringAsFixed(1)),
      meanBreathsPerMinute: double.parse(meanRpm.toStringAsFixed(1)),
      minBreathsPerMinute: double.parse(validRpms.first.toStringAsFixed(1)),
      maxBreathsPerMinute: double.parse(validRpms.last.toStringAsFixed(1)),
      validWindowsCount: validRpms.length,
      totalWindowsEvaluated: windowEstimates.length,
      status: MetricProvenanceStatus.experimental,
      windowEstimates: List.unmodifiable(windowEstimates),
    );
  } else {
    return RespirationResult(
      algorithmVersion: algorithmVersion,
      validWindowsCount: validRpms.length,
      totalWindowsEvaluated: windowEstimates.length,
      status: MetricProvenanceStatus.unavailable,
      unavailabilityReason:
          'Solo ${validRpms.length} finestre su $minValidWindowsRequired richieste hanno superato il controllo di picco spettrale RSA.',
      windowEstimates: List.unmodifiable(windowEstimates),
    );
  }
}
