import 'dart:math' as math;

import 'epoch_engine.dart';

/// Livello di confidenza e provenienza scientifica della metrica.
enum MetricProvenanceStatus {
  /// Misurato direttamente dai sensori senza inferenze modellistiche.
  measured,

  /// Stimato tramite modello deterministico documentato.
  estimated,

  /// Stimato sperimentalmente con soli segnali cardiaci (senza accelerometro/PPG).
  experimentalCardiacOnly,

  /// Metrica sperimentale con qualità o confidenza condizionata.
  experimental,

  /// Non disponibile a causa di segnali mancanti o qualità insufficiente.
  unavailable,
}

/// Classificazione sonno/veglia per una singola epoca da 30 secondi.
class EpochSleepWakeClassification {
  const EpochSleepWakeClassification({
    required this.epochIndex,
    required this.startUtc,
    required this.endUtc,
    required this.rawSleepProbability,
    required this.smoothedSleepProbability,
    required this.isAsleep,
  });

  final int epochIndex;
  final DateTime startUtc;
  final DateTime endUtc;

  /// Probabilità istantanea di sonno per l'epoca [0.0 = veglia certa, 1.0 = sonno certo].
  final double rawSleepProbability;

  /// Probabilità di sonno con regolarizzazione temporale (finestra mobile 5 epoche).
  final double smoothedSleepProbability;

  /// Classificazione binaria risultante (true = Sonno, false = Veglia).
  final bool isAsleep;
}

/// Risultato complessivo della stima Sleep/Wake per la notte.
class SleepWakeResult {
  const SleepWakeResult({
    required this.algorithmVersion,
    required this.provenance,
    required this.baselineHrBpm,
    this.estimatedOnsetUtc,
    this.estimatedEndUtc,
    this.manualOnsetUtc,
    this.manualEndUtc,
    this.effectiveOnsetUtc,
    this.effectiveEndUtc,
    required this.isManualOverride,
    required this.totalSleepDurationSeconds,
    required this.wasoDurationSeconds,
    required this.sleepEfficiencyPercent,
    required this.awakeningsCount,
    required this.epochs,
    required this.sleepOnsetLatencySeconds,
  });

  /// Versione dell'algoritmo impiegato.
  final String algorithmVersion;

  /// Stato di provenienza della metrica (sempre `experimentalCardiacOnly` per HR/RR).
  final MetricProvenanceStatus provenance;

  /// Frequenza cardiaca di base notturna (20° percentile delle epoche utilizzabili).
  final double baselineHrBpm;

  /// Inizio del sonno stimato dall'algoritmo (UTC).
  final DateTime? estimatedOnsetUtc;

  /// Risveglio finale stimato dall'algoritmo (UTC).
  final DateTime? estimatedEndUtc;

  /// Eventuale correzione manuale dell'inizio sonno (UTC).
  final DateTime? manualOnsetUtc;

  /// Eventuale correzione manuale del risveglio finale (UTC).
  final DateTime? manualEndUtc;

  /// Inizio sonno effettivo utilizzato per il calcolo delle metriche.
  final DateTime? effectiveOnsetUtc;

  /// Risveglio finale effettivo utilizzato per il calcolo delle metriche.
  final DateTime? effectiveEndUtc;

  /// Indica se i confini della notte sono stati sovrascritti manualmente.
  final bool isManualOverride;

  /// Durata totale del sonno effettivo (Total Sleep Time - TST) in secondi.
  final int totalSleepDurationSeconds;

  /// Durata della veglia dopo l'addormentamento (Wake After Sleep Onset - WASO) in secondi.
  final int wasoDurationSeconds;

  /// Efficienza del sonno: TST / (TST + WASO) * 100.
  final double sleepEfficiencyPercent;

  /// Numero di risvegli intermedi compresi tra inizio sonno e risveglio finale.
  final int awakeningsCount;

  /// Classificazioni per ciascuna epoca da 30s.
  final List<EpochSleepWakeClassification> epochs;

  /// Latenza di addormentamento in secondi (intervallo tra avvio registrazione e inizio sonno).
  final int sleepOnsetLatencySeconds;
}

/// Stimatore sperimentale di sonno/veglia basato unicamente su segnali cardiaci (HR / RR).
///
/// DOCUMENTAZIONE DELL'ALGORITMO v1.0.0:
/// In assenza di accelerometria multiasse (non trasmessa sulla caratteristica standard GATT 0x2A37),
/// l'algoritmo sfrutta la fisiologia cardiovascolare durante il sonno:
/// 1. Calcola la frequenza cardiaca basale notturna ($HR_{base}$) come 20° percentile
///    delle epoche con dati HR stabili e utilizzabili.
/// 2. Per ciascuna epoca $k$, stima la probabilità continua di sonno $P(Sleep)$ tramite funzione logistica:
///    $$z_k = \beta_0 - \beta_1 (HR_{mean, k} - HR_{base}) - \beta_2 \cdot HR_{std, k} - \beta_3 \cdot \max(0, slope_k)$$
///    dove $\beta_0 = 1.8$, $\beta_1 = 0.28$, $\beta_2 = 0.45$, $\beta_3 = 0.35$.
/// 3. Applica un filtro di smoothing contestuale bilaterale (finestra mobile a 5 epoche / 2.5 minuti)
///    per evitare oscillazioni non fisiologiche tra epoche adiacenti.
/// 4. State Machine dei confini:
///    - Inizio sonno (Sleep Onset): primo blocco continuo di almeno 10 epoche (5 minuti)
///      con probabilità di sonno $\ge 0.50$.
///    - Risveglio finale (Sleep Offset): ultimo cluster continuo di sonno (almeno 5 epoche consecutive),
///      seguito da veglia persistente fino al termine della registrazione.
///    - Risvegli intermedi (WASO): tutte le epoche classificate come veglia collocate
///      all'interno dell'intervallo [Sleep Onset, Sleep Offset].
class CardiacSleepWakeEstimator {
  static const String algorithmVersion = '1.0.0-cardiac-only';

  /// Esegue la stima sonno/veglia a partire dalla sequenza di epoche da 30 secondi.
  static SleepWakeResult estimate({
    required List<Epoch30s> epochs,
    DateTime? manualOnsetUtc,
    DateTime? manualEndUtc,
    int consecutiveEpochsForOnset = 10, // 5 minuti
    int consecutiveEpochsForOffset = 5,  // 2.5 minuti
    int contextWindowEpochs = 5,
  }) {
    if (epochs.isEmpty) {
      return const SleepWakeResult(
        algorithmVersion: algorithmVersion,
        provenance: MetricProvenanceStatus.experimentalCardiacOnly,
        baselineHrBpm: 0.0,
        isManualOverride: false,
        totalSleepDurationSeconds: 0,
        wasoDurationSeconds: 0,
        sleepEfficiencyPercent: 0.0,
        awakeningsCount: 0,
        epochs: [],
        sleepOnsetLatencySeconds: 0,
      );
    }

    // 1. Calcolo del baseline HR notturno (20° percentile tra le epoche utilizzabili)
    final usableEpochs = epochs.where((e) => e.isUsable && e.hrMean != null).toList();
    double baselineHr;
    if (usableEpochs.isNotEmpty) {
      final sortedMeans = usableEpochs.map((e) => e.hrMean!).toList()..sort();
      final idx20 = (sortedMeans.length * 0.20).floor().clamp(0, sortedMeans.length - 1);
      baselineHr = sortedMeans[idx20];
    } else {
      baselineHr = 60.0;
    }

    // 2. Calcolo probabilità grezza per ogni epoca
    final rawProbs = <double>[];
    for (final ep in epochs) {
      if (!ep.isUsable || ep.hrMean == null) {
        rawProbs.add(0.0);
        continue;
      }

      final hrElev = ep.hrMean! - baselineHr;
      final hrStd = ep.hrStd ?? 0.0;
      final posSlope = math.max(0.0, ep.hrSlope);

      // Score z logistico
      final z = 1.8 - (0.28 * hrElev) - (0.45 * hrStd) - (0.35 * posSlope);
      final prob = 1.0 / (1.0 + math.exp(-z.clamp(-10.0, 10.0)));
      rawProbs.add(prob);
    }

    // 3. Regolarizzazione temporale (smoothing su finestra contestuale)
    final smoothedProbs = <double>[];
    final halfWin = contextWindowEpochs ~/ 2;
    final n = epochs.length;

    for (var i = 0; i < n; i++) {
      final wStart = math.max(0, i - halfWin);
      final wEnd = math.min(n, i + halfWin + 1);
      var sum = 0.0;
      var count = 0;
      for (var k = wStart; k < wEnd; k++) {
        sum += rawProbs[k];
        count++;
      }
      smoothedProbs.add(count > 0 ? sum / count : rawProbs[i]);
    }

    final classifiedEpochs = <EpochSleepWakeClassification>[];
    for (var i = 0; i < n; i++) {
      final isAsleep = smoothedProbs[i] >= 0.50;
      classifiedEpochs.add(
        EpochSleepWakeClassification(
          epochIndex: i,
          startUtc: epochs[i].startUtc,
          endUtc: epochs[i].endUtc,
          rawSleepProbability: rawProbs[i],
          smoothedSleepProbability: smoothedProbs[i],
          isAsleep: isAsleep,
        ),
      );
    }

    // 4. Identificazione Inizio Sonno (Sleep Onset)
    int? estimatedOnsetIdx;
    for (var i = 0; i <= n - consecutiveEpochsForOnset; i++) {
      var allSleep = true;
      for (var k = 0; k < consecutiveEpochsForOnset; k++) {
        if (!classifiedEpochs[i + k].isAsleep) {
          allSleep = false;
          break;
        }
      }
      if (allSleep) {
        estimatedOnsetIdx = i;
        break;
      }
    }

    // 5. Identificazione Risveglio Finale (Sleep Offset)
    int? estimatedOffsetIdx;
    for (var i = n - 1; i >= consecutiveEpochsForOffset; i--) {
      var allSleep = true;
      for (var k = 0; k < consecutiveEpochsForOffset; k++) {
        if (!classifiedEpochs[i - k].isAsleep) {
          allSleep = false;
          break;
        }
      }
      if (allSleep) {
        estimatedOffsetIdx = i;
        break;
      }
    }

    // Se non troviamo confini validi, usa il primo/ultimo epoch di sonno o l'intera sessione
    final estimatedOnsetUtc = estimatedOnsetIdx != null
        ? epochs[estimatedOnsetIdx].startUtc
        : null;
    final estimatedEndUtc = estimatedOffsetIdx != null
        ? epochs[estimatedOffsetIdx].endUtc
        : null;

    final isManualOverride = manualOnsetUtc != null || manualEndUtc != null;
    final effectiveOnset = manualOnsetUtc ?? estimatedOnsetUtc;
    final effectiveEnd = manualEndUtc ?? estimatedEndUtc;

    // 6. Calcolo metriche sleep / WASO / efficienza nell'intervallo effettivo
    var tstSeconds = 0;
    var wasoSeconds = 0;
    var awakenings = 0;
    var inAwakening = false;
    var onsetLatencySeconds = 0;

    if (effectiveOnset != null) {
      onsetLatencySeconds = math.max(
        0,
        effectiveOnset.difference(epochs.first.startUtc).inSeconds,
      );
    }

    if (effectiveOnset != null && effectiveEnd != null && effectiveEnd.isAfter(effectiveOnset)) {
      for (var i = 0; i < n; i++) {
        final ep = classifiedEpochs[i];
        final isInWindow = (ep.startUtc.isAfter(effectiveOnset) || ep.startUtc.isAtSameMomentAs(effectiveOnset)) &&
            (ep.endUtc.isBefore(effectiveEnd) || ep.endUtc.isAtSameMomentAs(effectiveEnd));

        if (!isInWindow) continue;

        if (ep.isAsleep) {
          tstSeconds += 30;
          inAwakening = false;
        } else {
          wasoSeconds += 30;
          if (!inAwakening) {
            awakenings++;
            inAwakening = true;
          }
        }
      }
    }

    final totalSessionInBedSeconds = tstSeconds + wasoSeconds;
    final efficiency = totalSessionInBedSeconds > 0
        ? (tstSeconds / totalSessionInBedSeconds * 100.0).clamp(0.0, 100.0)
        : 0.0;

    return SleepWakeResult(
      algorithmVersion: algorithmVersion,
      provenance: MetricProvenanceStatus.experimentalCardiacOnly,
      baselineHrBpm: baselineHr,
      estimatedOnsetUtc: estimatedOnsetUtc,
      estimatedEndUtc: estimatedEndUtc,
      manualOnsetUtc: manualOnsetUtc,
      manualEndUtc: manualEndUtc,
      effectiveOnsetUtc: effectiveOnset,
      effectiveEndUtc: effectiveEnd,
      isManualOverride: isManualOverride,
      totalSleepDurationSeconds: tstSeconds,
      wasoDurationSeconds: wasoSeconds,
      sleepEfficiencyPercent: efficiency,
      awakeningsCount: awakenings,
      epochs: List.unmodifiable(classifiedEpochs),
      sleepOnsetLatencySeconds: onsetLatencySeconds,
    );
  }
}
