/// Punto campionario per grafici di frequenza cardiaca.
class HrSamplePoint {
  const HrSamplePoint({
    required this.timestampUtc,
    required this.hrBpm,
  });

  final DateTime timestampUtc;
  final int hrBpm;
}

/// Modello e metriche complete per la sessione Night Recorder (Task 07).
class NightSessionSummary {
  const NightSessionSummary({
    required this.sessionId,
    required this.startTimeUtc,
    required this.endTimeUtc,
    required this.deviceAddress,
    required this.deviceName,
    required this.status,
    required this.totalSamples,
    required this.totalRr,
    required this.disconnectionsCount,
    required this.meanHr,
    required this.medianHr,
    required this.minHr,
    required this.maxHr,
    required this.rmssdMs,
    required this.estimatedRhr,
    required this.coveragePercent,
    required this.totalDurationSeconds,
    required this.disconnectionDurationSeconds,
    required this.hrTimeSeries,
    required this.missingMetrics,
    this.segmentedRmssdMs,
    this.segmentedRmssd1024Ms,
    this.legacyRmssd1024Ms,
    this.excludedPhysiologicalBeats = 0,
    this.excludedGapsCount = 0,
    this.segmentsCount = 0,
    this.validSuccessiveDiffsCount = 0,
  });

  final String sessionId;
  final DateTime startTimeUtc;
  final DateTime? endTimeUtc;
  final String deviceAddress;
  final String deviceName;
  final String status;
  final int totalSamples;
  final int totalRr;
  final int disconnectionsCount;
  final double? meanHr;
  final double? medianHr;
  final int? minHr;
  final int? maxHr;

  /// RMSSD storico precedente (v1, non segmentato, preservato).
  final double? rmssdMs;

  /// RMSSD scientifico segmentato (v2, gap-aware, senza unione artificiale delle lacune).
  final double? segmentedRmssdMs;

  /// RMSSD scientifico segmentato convertito secondo standard Bluetooth SIG (raw * 1000 / 1024).
  final double? segmentedRmssd1024Ms;

  /// RMSSD storico precedente convertito secondo standard Bluetooth SIG.
  final double? legacyRmssd1024Ms;

  /// Numero di battiti scartati dal filtro fisiologico [300, 2000]ms.
  final int excludedPhysiologicalBeats;

  /// Numero di lacune temporali (> 2.0s) isolate per evitare falsi gradienti ΔRR.
  final int excludedGapsCount;

  /// Numero di segmenti continui validi identificati (ciascuno con almeno 2 battiti consecutivi).
  final int segmentsCount;

  /// Numero totale di differenze successive valide (M) utilizzate per il calcolo RMSSD segmentato.
  final int validSuccessiveDiffsCount;

  final int? estimatedRhr;
  final double coveragePercent;
  final int totalDurationSeconds;
  final int disconnectionDurationSeconds;
  final List<HrSamplePoint> hrTimeSeries;
  final Map<String, String> missingMetrics;

  DateTime get startTimeLocal => startTimeUtc.toLocal();
  DateTime? get endTimeLocal => endTimeUtc?.toLocal();

  String get durationFormatted {
    final h = totalDurationSeconds ~/ 3600;
    final m = (totalDurationSeconds % 3600) ~/ 60;
    final s = totalDurationSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Genera il rapporto del mattino completo in formato Markdown (FASE 6 & FASE 9).
  String toMarkdownReport() {
    final buffer = StringBuffer();
    buffer.writeln('# BEVELTRY — RAPPORTO SESSIONE NOTTURNA (NIGHT RECORDER)');
    buffer.writeln('**Sessione:** `$sessionId`');
    buffer.writeln('**Dispositivo:** $deviceName (`$deviceAddress`)');
    buffer.writeln('**Stato sessione:** $status');
    buffer.writeln('');
    buffer.writeln('---');
    buffer.writeln('## 1. TEMPI E COPERTURA TEMPORALE');
    buffer.writeln('- **Inizio (UTC):** ${startTimeUtc.toIso8601String()}');
    buffer.writeln('- **Inizio (Locale):** ${startTimeLocal.toString()}');
    buffer.writeln('- **Fine (UTC):** ${endTimeUtc?.toIso8601String() ?? "In corso"}');
    buffer.writeln('- **Fine (Locale):** ${endTimeLocal?.toString() ?? "In corso"}');
    buffer.writeln('- **Durata totale:** $durationFormatted ($totalDurationSeconds secondi)');
    buffer.writeln('- **Campioni HR acquisiti:** $totalSamples');
    buffer.writeln('- **Copertura stimata:** ${coveragePercent.toStringAsFixed(1)}% (assunzione: campionamento a ~1Hz da notifica BLE 0x2A37)');
    buffer.writeln('- **Disconnessioni BLE:** $disconnectionsCount (durata stimata offline: ${disconnectionDurationSeconds}s)');
    buffer.writeln('');
    buffer.writeln('---');
    buffer.writeln('## 2. METRICHE CARDIACHE (0x2A37)');
    buffer.writeln('- **Frequenza Cardiaca Media:** ${meanHr != null ? "${meanHr!.toStringAsFixed(1)} BPM" : "N/D"}');
    buffer.writeln('- **Frequenza Cardiaca Mediana:** ${medianHr != null ? "${medianHr!.toStringAsFixed(1)} BPM" : "N/D"}');
    buffer.writeln('- **Frequenza Minima osservata:** ${minHr != null ? "$minHr BPM" : "N/D"}');
    buffer.writeln('- **Frequenza Massima osservata:** ${maxHr != null ? "$maxHr BPM" : "N/D"}');
    buffer.writeln('- **Stima FC a Riposo (RHR Notturno):** ${estimatedRhr != null ? "$estimatedRhr BPM" : "N/D"}');
    buffer.writeln('  *(Metodo esplicito: media minima su finestra mobile di 5 minuti / 300 campioni validi nel corso della notte. Non è la semplice FC minima).*');
    buffer.writeln('');
    buffer.writeln('---');
    buffer.writeln('## 3. VARIABILITÀ CARDIACA (HRV RMSSD)');
    buffer.writeln('- **Intervalli R-R grezzi disponibili:** $totalRr');
    if (segmentedRmssdMs != null) {
      buffer.writeln('- **HRV RMSSD Segmentato (Valore uint16 / interpretazione diretta ms):** ${segmentedRmssdMs!.toStringAsFixed(2)} ms');
      if (segmentedRmssd1024Ms != null) {
        buffer.writeln('- **HRV RMSSD Segmentato (Valore convertito Bluetooth SIG 1/1024s):** ${segmentedRmssd1024Ms!.toStringAsFixed(2)} ms');
      }
      buffer.writeln('  *(Calcolato rigorosamente su $validSuccessiveDiffsCount differenze successive valide all\'interno di $segmentsCount segmenti continui senza unire artificialmente battiti separati da lacune).*');
      buffer.writeln('- **HRV RMSSD Storico (Non-Segmentato, v1):** ${rmssdMs != null ? "${rmssdMs!.toStringAsFixed(2)} ms" : "N/D"}');
      if (legacyRmssd1024Ms != null) {
        buffer.writeln('- **HRV RMSSD Storico (Non-Segmentato Bluetooth SIG 1/1024s):** ${legacyRmssd1024Ms!.toStringAsFixed(2)} ms');
      }
      buffer.writeln('- **Audit di segmentazione:** $excludedGapsCount lacune (> 2.0s) escluse, $excludedPhysiologicalBeats battiti fuori range fisiologico [300, 2000]ms esclusi.');
    } else if (rmssdMs != null) {
      buffer.writeln('- **HRV RMSSD:** ${rmssdMs!.toStringAsFixed(2)} ms');
      buffer.writeln('  *(Calcolato con formula standard Task Force 1996 su intervalli R-R validi tra 300ms e 2000ms).*');
    } else {
      buffer.writeln('- **HRV RMSSD:** MISSING (Intervalli R-R insufficienti o non trasmessi dalla notifica 0x2A37)');
    }
    buffer.writeln('');
    buffer.writeln('---');
    buffer.writeln('## 4. METRICHE NON DISPONIBILI (TRASPARENZA TOTALE)');
    missingMetrics.forEach((metric, reason) {
      buffer.writeln('- **$metric:** MISSING — $reason');
    });
    buffer.writeln('');
    buffer.writeln('---');
    buffer.writeln('*Rapporto generato automaticamente da Beveltry Night Recorder senza dati inventati.*');
    return buffer.toString();
  }
}
