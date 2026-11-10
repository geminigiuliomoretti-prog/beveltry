import 'dart:math' as math;

/// Rappresenta un battito cardiaco con timestamp per l'analisi temporale e la segmentazione.
class BeatInterval {
  const BeatInterval({
    required this.timestampUtc,
    required this.rrMs,
    this.beatOrdinal = 0,
  });

  final DateTime timestampUtc;
  final int rrMs;
  final int beatOrdinal;
}

/// Risultato del calcolo HRV segmentato conforme agli standard Task Force 1996.
class SegmentedHrvResult {
  const SegmentedHrvResult({
    required this.segmentedRmssdMs,
    required this.legacyRmssdMs,
    this.segmentedRmssd1024Ms,
    this.legacyRmssd1024Ms,
    required this.totalBeats,
    required this.validBeats,
    required this.excludedPhysiologicalBeats,
    required this.excludedGapsCount,
    required this.maxGapSeconds,
    required this.segmentsCount,
    required this.validSuccessiveDiffsCount,
    required this.segments,
    this.gapThresholdSeconds = 2.0,
    this.minPhysiologicalMs = 300,
    this.maxPhysiologicalMs = 2000,
  });

  /// RMSSD calcolato sui valori grezzi u16 / interpretazione ms diretti.
  final double? segmentedRmssdMs;

  /// RMSSD segmentato convertito secondo lo standard Bluetooth SIG (raw * 1000 / 1024).
  final double? segmentedRmssd1024Ms;

  /// RMSSD storico precedente calcolato senza segmentazione temporale (v1).
  final double? legacyRmssdMs;

  /// RMSSD storico precedente convertito secondo lo standard Bluetooth SIG.
  final double? legacyRmssd1024Ms;

  /// Numero totale di intervalli R-R analizzati.
  final int totalBeats;

  /// Numero di battiti validi che rientrano nei limiti fisiologici.
  final int validBeats;

  /// Numero di battiti scartati perché fuori dai limiti fisiologici [minPhysiologicalMs, maxPhysiologicalMs].
  final int excludedPhysiologicalBeats;

  /// Numero di lacune (> gapThresholdSeconds) escluse dal calcolo delle differenze.
  final int excludedGapsCount;

  /// Durata massima osservata per una lacuna tra battiti (in secondi).
  final double maxGapSeconds;

  /// Numero di segmenti continui identificati (ciascuno con almeno 2 battiti).
  final int segmentsCount;

  /// Numero di coppie successive valide (M) su cui è calcolato l'RMSSD segmentato.
  final int validSuccessiveDiffsCount;

  /// I singoli segmenti di intervalli R-R continui.
  final List<List<int>> segments;

  final double gapThresholdSeconds;
  final int minPhysiologicalMs;
  final int maxPhysiologicalMs;
}

/// Calcola l'indice HRV RMSSD (Root Mean Square of Successive Differences) legacy (v1).
///
/// Formula standard Task Force 1996 su lista non segmentata:
/// ```
/// RMSSD = sqrt( sum( (RR[i] - RR[i-1])^2 ) / (N - 1) )
/// ```
/// Richiede almeno 2 intervalli R-R per poter calcolare almeno una differenza.
/// Restituisce `null` se [filteredRrIntervalsMs] ha meno di 2 elementi.
double? calculateRmssd(List<int> filteredRrIntervalsMs) {
  if (filteredRrIntervalsMs.length < 2) {
    return null;
  }

  var sumSquaredDiffs = 0.0;
  final n = filteredRrIntervalsMs.length;

  for (var i = 1; i < n; i++) {
    final diff = (filteredRrIntervalsMs[i] - filteredRrIntervalsMs[i - 1]).toDouble();
    sumSquaredDiffs += diff * diff;
  }

  final meanSquaredDiff = sumSquaredDiffs / (n - 1);
  return math.sqrt(meanSquaredDiff);
}

/// Calcola l'HRV RMSSD segmentando rigorosamente le serie continue (v2).
///
/// Previene l'errore metodologico di unire artificialmente battiti separati da lacune temporali
/// o artefatti non fisiologici. Rispetta lo standard scientifico Task Force 1996:
/// le differenze successive ΔRR sono calcolate esclusivamente tra battiti consecutivi all'interno
/// dello stesso segmento continuo.
SegmentedHrvResult calculateSegmentedHrv({
  required List<BeatInterval> beats,
  double gapThresholdSeconds = 2.0,
  int minPhysiologicalMs = 300,
  int maxPhysiologicalMs = 2000,
}) {
  if (beats.isEmpty) {
    return const SegmentedHrvResult(
      segmentedRmssdMs: null,
      legacyRmssdMs: null,
      totalBeats: 0,
      validBeats: 0,
      excludedPhysiologicalBeats: 0,
      excludedGapsCount: 0,
      maxGapSeconds: 0.0,
      segmentsCount: 0,
      validSuccessiveDiffsCount: 0,
      segments: [],
    );
  }

  // 1. Calcolo legacy (v1) per conservazione storica dell'HRV già archiviata
  final physioFilteredBeats = beats
      .where((b) => b.rrMs >= minPhysiologicalMs && b.rrMs <= maxPhysiologicalMs)
      .toList();
  final legacyRmssd = calculateRmssd(physioFilteredBeats.map((b) => b.rrMs).toList());

  // 2. Segmentazione continua gap-aware
  final segments = <List<int>>[];
  var currentSegment = <int>[];
  var excludedPhysioCount = 0;
  var excludedGapsCount = 0;
  var maxGapSec = 0.0;

  DateTime? lastTimestamp;
  int? lastOrdinal;
  var lastWasValid = false;

  for (final beat in beats) {
    final isPhysio = beat.rrMs >= minPhysiologicalMs && beat.rrMs <= maxPhysiologicalMs;
    if (!isPhysio) {
      excludedPhysioCount++;
      if (currentSegment.length >= 2) {
        segments.add(List.unmodifiable(currentSegment));
      }
      currentSegment = [];
      lastTimestamp = beat.timestampUtc;
      lastOrdinal = beat.beatOrdinal;
      lastWasValid = false;
      continue;
    }

    if (lastTimestamp != null) {
      final gapSec = beat.timestampUtc.difference(lastTimestamp).inMilliseconds / 1000.0;
      if (gapSec > maxGapSec) {
        maxGapSec = gapSec;
      }

      final isSameNotificationNextBeat = (gapSec == 0.0) && (beat.beatOrdinal > (lastOrdinal ?? 0));
      final isContinuousInTime = (gapSec > 0.0) && (gapSec <= gapThresholdSeconds);

      if (!lastWasValid || (!isSameNotificationNextBeat && !isContinuousInTime && gapSec > gapThresholdSeconds)) {
        if (gapSec > gapThresholdSeconds) {
          excludedGapsCount++;
        }
        if (currentSegment.length >= 2) {
          segments.add(List.unmodifiable(currentSegment));
        }
        currentSegment = [];
      }
    }

    currentSegment.add(beat.rrMs);
    lastTimestamp = beat.timestampUtc;
    lastOrdinal = beat.beatOrdinal;
    lastWasValid = true;
  }

  if (currentSegment.length >= 2) {
    segments.add(List.unmodifiable(currentSegment));
  }

  // 3. Calcolo RMSSD aggregato pesato sui segmenti validi:
  // RMSSD = sqrt( (sum_{k} sum_{j} (RR_{k,j} - RR_{k,j-1})^2) / M )
  // dove M = sum_{k} (N_k - 1)
  var totalSquaredDiffs = 0.0;
  var totalDiffsCount = 0;

  for (final seg in segments) {
    for (var i = 1; i < seg.length; i++) {
      final diff = (seg[i] - seg[i - 1]).toDouble();
      totalSquaredDiffs += diff * diff;
      totalDiffsCount++;
    }
  }

  final double? segmentedRmssd = totalDiffsCount > 0
      ? math.sqrt(totalSquaredDiffs / totalDiffsCount)
      : null;

  return SegmentedHrvResult(
    segmentedRmssdMs: segmentedRmssd,
    segmentedRmssd1024Ms: segmentedRmssd != null ? segmentedRmssd * 1000.0 / 1024.0 : null,
    legacyRmssdMs: legacyRmssd,
    legacyRmssd1024Ms: legacyRmssd != null ? legacyRmssd * 1000.0 / 1024.0 : null,
    totalBeats: beats.length,
    validBeats: physioFilteredBeats.length,
    excludedPhysiologicalBeats: excludedPhysioCount,
    excludedGapsCount: excludedGapsCount,
    maxGapSeconds: maxGapSec,
    segmentsCount: segments.length,
    validSuccessiveDiffsCount: totalDiffsCount,
    segments: List.unmodifiable(segments),
    gapThresholdSeconds: gapThresholdSeconds,
    minPhysiologicalMs: minPhysiologicalMs,
    maxPhysiologicalMs: maxPhysiologicalMs,
  );
}
