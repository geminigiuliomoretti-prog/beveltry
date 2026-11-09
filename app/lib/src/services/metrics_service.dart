import '../dsp/dsp.dart';
import '../repository/whoop_repository.dart';

/// Modello immutabile contenente le metriche fisiologiche giornaliere calcolate.
class DailyMetrics {
  const DailyMetrics({
    required this.rhr,
    required this.hrvRmssd,
    required this.recordCount,
    required this.calculatedAt,
  });

  /// Frequenza cardiaca a riposo (RHR) in bpm (null se dati insufficienti).
  final int? rhr;

  /// Variabilità della frequenza cardiaca (RMSSD) in ms (null se dati insufficienti).
  final double? hrvRmssd;

  /// Numero totale di record analizzati nell'intervallo temporale.
  final int recordCount;

  /// Data e ora del calcolo.
  final DateTime calculatedAt;

  /// Indica se il valore RMSSD calcolato è fisiologicamente valido
  /// (non nullo, maggiore di zero e calcolato su almeno 10 record).
  bool get isHrvValid =>
      hrvRmssd != null && hrvRmssd! > 0.0 && recordCount >= 10;

  /// Indica se almeno una metrica valida è stata calcolata.
  bool get hasValidMetrics => rhr != null || isHrvValid;
}

/// Servizio che legge i record memorizzati nel database locale e calcola le metriche fisiologiche.
class MetricsService {
  MetricsService({
    required this.repository,
    this.strapSerial = '5AG0558675',
    this.artifactFilter = const RrArtifactFilter(),
  });

  final WhoopRepository repository;
  final String strapSerial;
  final RrArtifactFilter artifactFilter;

  /// Calcola RHR ed HRV RMSSD per l'ultimo periodo notturno / sessione di dati disponibile.
  ///
  /// Risolve il problema del "database vuoto": anziché filtrare rigidamente per
  /// [DateTime.now - 24h], recupera gli ultimi [recordLimit] record disponibili
  /// (default 5000), permettendo di analizzare dati offloadati anche con orologi non allineati.
  ///
  /// Filtra per `sleep_state == 2` (deep sleep) quando disponibile,
  /// rimuove artefatti dagli intervalli R-R e applica gli algoritmi DSP.
  Future<DailyMetrics> calculateMetricsForLastNight({
    DateTime? referenceTime,
    int recordLimit = 5000,
  }) async {
    final now = referenceTime ?? DateTime.now().toUtc();

    final records = await repository.getLatestRecords(
      limit: recordLimit,
      strapSerial: strapSerial,
    );

    if (records.isEmpty) {
      return DailyMetrics(
        rhr: null,
        hrvRmssd: null,
        recordCount: 0,
        calculatedAt: now,
      );
    }

    // Seleziona i record notturni / sonno profondo (sleepState == 2) se presenti in quantità sufficiente
    final deepSleepRecords =
        records.where((r) => r.sleepState == 2 && r.hrPrimary > 0).toList();
    final targetRecords = deepSleepRecords.length >= 300
        ? deepSleepRecords
        : records.where((r) => r.hrPrimary > 0).toList();

    if (targetRecords.isEmpty) {
      return DailyMetrics(
        rhr: null,
        hrvRmssd: null,
        recordCount: records.length,
        calculatedAt: now,
      );
    }

    // 1. Calcolo RHR tramite la finestra mobile da 5 minuti con media minima
    final rawRhr = calculateRhr(targetRecords);
    final rhr = rawRhr > 0 ? rawRhr : null;

    // 2. Raccoglie tutti gli intervalli R-R, applica il filtro artefatti e calcola RMSSD
    final allRawRrs = <int>[];
    for (final r in targetRecords) {
      allRawRrs.addAll(r.rrIntervalsMs);
    }

    final filteredRrs = artifactFilter.filter(allRawRrs);
    final rawRmssd = calculateRmssd(filteredRrs);
    final hrvRmssd =
        rawRmssd != null ? double.parse(rawRmssd.toStringAsFixed(1)) : null;

    return DailyMetrics(
      rhr: rhr,
      hrvRmssd: hrvRmssd,
      recordCount: records.length,
      calculatedAt: now,
    );
  }
}
