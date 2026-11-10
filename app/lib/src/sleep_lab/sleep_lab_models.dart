import '../records/night_session_summary.dart';
import 'cardiac_sleep_wake_estimator.dart';
import 'epoch_engine.dart';
import 'hrv_window_lab.dart';
import 'respiration_and_rhr.dart';
import 'whoop_a_comparison.dart';

/// Riepilogo globale della qualità del segnale e della copertura notturna.
class SleepLabDataQuality {
  const SleepLabDataQuality({
    required this.totalSamplesCount,
    required this.totalBeatsCount,
    required this.usableEpochsCount,
    required this.totalEpochsCount,
    required this.epochUsabilityPercent,
    required this.sampleCoveragePercent,
    required this.gapsCount,
    required this.maxGapSeconds,
    required this.qualityFlags,
  });

  final int totalSamplesCount;
  final int totalBeatsCount;
  final int usableEpochsCount;
  final int totalEpochsCount;
  final double epochUsabilityPercent;
  final double sampleCoveragePercent;
  final int gapsCount;
  final double maxGapSeconds;
  final Set<EpochQualityFlag> qualityFlags;
}

/// Contenitore principale di tutte le analisi di Beveltry Sleep Lab per una sessione.
class SleepLabAnalysis {
  const SleepLabAnalysis({
    required this.sessionSummary,
    required this.epochs,
    required this.sleepWake,
    required this.hrvLab,
    required this.rhr,
    required this.respiration,
    this.whoopAComparison,
    required this.comparisonDeltas,
    required this.quality,
  });

  final NightSessionSummary sessionSummary;
  final List<Epoch30s> epochs;
  final SleepWakeResult sleepWake;
  final HrvWindowLabResult hrvLab;
  final RhrResult rhr;
  final RespirationResult respiration;
  final WhoopAComparisonRecord? whoopAComparison;
  final List<MetricDeltaItem> comparisonDeltas;
  final SleepLabDataQuality quality;
}
