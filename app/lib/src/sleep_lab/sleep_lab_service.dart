import '../repository/whoop_repository.dart';
import 'cardiac_sleep_wake_estimator.dart';
import 'epoch_engine.dart';
import 'hrv_window_lab.dart';
import 'respiration_and_rhr.dart';
import 'sleep_lab_models.dart';
import 'whoop_a_comparison.dart';

/// Servizio di analisi notturna deterministica per Beveltry Sleep Lab.
///
/// Implementa la pipeline scientifica downstream del Night Recorder:
/// 1. Lettura dati grezzi reali da SQLite (HR 0x2A37 e intervalli R-R).
/// 2. Ricostruzione fisiologica e partizionamento in epoche da 30s.
/// 3. Stimatore Sleep/Wake v1 cardiac-only con identificazione onset, offset e WASO.
/// 4. HRV Window Lab (RMSSD intero sonno, rolling 5 min, candidati Deep preservati/unavailable).
/// 5. RHR minimo rolling e frequenza respiratoria sperimentale da aritmia sinusale (RSA).
/// 6. Confronto incrociato rigoroso con le metriche ufficiali WHOOP A.
class SleepLabService {
  SleepLabService({required this.repository});

  final WhoopRepository repository;

  /// Esegue l'analisi completa per una sessione notturna memorizzata in SQLite.
  Future<SleepLabAnalysis> analyzeSession(
    String sessionId, {
    DateTime? manualOnsetUtc,
    DateTime? manualEndUtc,
  }) async {
    // 1. Recupera il riepilogo base della sessione
    final sessionSummary = await repository.getNightSessionSummary(sessionId);

    // 2. Recupera tutti i campioni HR e i battiti R-R grezzi
    final hrSamples = await repository.getRawNightSamples(sessionId);
    final rawRrBeats = await repository.getRawNightRrIntervals(sessionId);

    // 3. Controlla se esistono confini manuali salvati se non passati esplicitamente
    var effManualOnset = manualOnsetUtc;
    var effManualEnd = manualEndUtc;
    if (effManualOnset == null && effManualEnd == null) {
      final savedBoundaries = await repository.getManualSleepBoundaries(sessionId);
      effManualOnset = savedBoundaries['manualOnset'];
      effManualEnd = savedBoundaries['manualEnd'];
    }

    // 4. Costruzione deterministica delle epoche da 30 secondi
    final epochs = build30sEpochs(
      hrSamples: hrSamples,
      rrBeats: rawRrBeats,
      sessionStartUtc: sessionSummary.startTimeUtc,
      sessionEndUtc: sessionSummary.endTimeUtc,
    );

    // 5. Stima Sleep/Wake cardiac-only
    final sleepWake = CardiacSleepWakeEstimator.estimate(
      epochs: epochs,
      manualOnsetUtc: effManualOnset,
      manualEndUtc: effManualEnd,
    );

    // 6. Confini effettivi di sonno da utilizzare
    final sleepStart = sleepWake.effectiveOnsetUtc ?? sessionSummary.startTimeUtc;
    final sleepEnd = sleepWake.effectiveEndUtc ??
        sessionSummary.endTimeUtc ??
        DateTime.now().toUtc();

    // 7. Ricostruzione fisiologica dei battiti R-R
    final physioBeats = reconstructPhysiologicalBeats(rawRrBeats);

    // 8. HRV Window Lab
    final hrvLab = calculateHrvWindowLab(
      beats: physioBeats,
      sleepStartUtc: sleepStart,
      sleepEndUtc: sleepEnd,
      epochs: epochs,
    );

    // 9. RHR Window Lab
    final rhr = calculateRhrWindowLab(
      hrSamples: hrSamples,
      sleepStartUtc: sleepStart,
      sleepEndUtc: sleepEnd,
      epochs: epochs,
    );

    // 10. Frequenza respiratoria sperimentale da modulazione RSA
    final respiration = estimateRespirationRsa(
      beats: physioBeats,
      sleepStartUtc: sleepStart,
      sleepEndUtc: sleepEnd,
    );

    // 11. Confronto con WHOOP A (se inserito)
    final whoopA = await repository.getWhoopAComparisonForSession(sessionId);
    final comparisonDeltas = whoopA != null
        ? computeWhoopAComparisonDeltas(
            whoopA: whoopA,
            beveltryOnsetUtc: sleepWake.effectiveOnsetUtc,
            beveltryEndUtc: sleepWake.effectiveEndUtc,
            beveltryTstSeconds: sleepWake.totalSleepDurationSeconds,
            beveltryWasoSeconds: sleepWake.wasoDurationSeconds,
            beveltryHrvWholeMs: hrvLab.wholeSleepRmssd.valueDirectMs,
            beveltryHrvRollingMedianMs: hrvLab.rolling5MinMedianMs,
            beveltryRhrBpm: rhr.min5MinBpm,
            beveltryRespRpm: respiration.medianBreathsPerMinute,
          )
        : const <MetricDeltaItem>[];

    // 12. Sintesi della qualità dei dati
    final usableEpochs = epochs.where((e) => e.isUsable).length;
    final totalEpochs = epochs.length;
    final usabilityPct = totalEpochs > 0 ? (usableEpochs / totalEpochs * 100.0) : 0.0;

    final allFlags = <EpochQualityFlag>{};
    var maxGapSec = 0.0;
    var gapsCount = 0;
    for (final ep in epochs) {
      allFlags.addAll(ep.qualityFlags);
      if (ep.maxGapSeconds > maxGapSec) {
        maxGapSec = ep.maxGapSeconds;
      }
      if (ep.maxGapSeconds > 2.0) {
        gapsCount++;
      }
    }

    final quality = SleepLabDataQuality(
      totalSamplesCount: hrSamples.length,
      totalBeatsCount: physioBeats.length,
      usableEpochsCount: usableEpochs,
      totalEpochsCount: totalEpochs,
      epochUsabilityPercent: usabilityPct,
      sampleCoveragePercent: sessionSummary.coveragePercent,
      gapsCount: gapsCount,
      maxGapSeconds: maxGapSec,
      qualityFlags: allFlags,
    );

    return SleepLabAnalysis(
      sessionSummary: sessionSummary,
      epochs: epochs,
      sleepWake: sleepWake,
      hrvLab: hrvLab,
      rhr: rhr,
      respiration: respiration,
      whoopAComparison: whoopA,
      comparisonDeltas: comparisonDeltas,
      quality: quality,
    );
  }

  /// Salva i confini manuali per una sessione.
  Future<void> saveManualBoundaries({
    required String sessionId,
    DateTime? manualOnsetUtc,
    DateTime? manualEndUtc,
  }) async {
    await repository.saveManualSleepBoundaries(
      sessionId: sessionId,
      manualOnset: manualOnsetUtc,
      manualEnd: manualEndUtc,
    );
  }

  /// Salva o aggiorna il record di confronto WHOOP A per una sessione.
  Future<void> saveWhoopAComparison(WhoopAComparisonRecord record) async {
    await repository.saveWhoopAComparison(record);
  }

  /// Recupera l'elenco di tutte le sessioni notturne registrate.
  Future<List<Map<String, dynamic>>> getAvailableSessions() {
    return repository.getAllNightSessions();
  }
}
