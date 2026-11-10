/// Modello per il salvataggio dei risultati ufficiali forniti dall'app WHOOP A.
class WhoopAComparisonRecord {
  const WhoopAComparisonRecord({
    this.id,
    required this.sessionId,
    required this.createdAtUtc,
    required this.algorithmVersion,
    this.sleepOnsetUtc,
    this.sleepEndUtc,
    this.sleepDurationSeconds,
    this.awakeDurationSeconds,
    this.lightDurationSeconds,
    this.deepDurationSeconds,
    this.remDurationSeconds,
    this.hrvRmssd,
    this.rhrBpm,
    this.respiratoryRate,
    this.recoveryScore,
    this.sleepPerformanceScore,
    this.notes,
  });

  factory WhoopAComparisonRecord.fromMap(Map<String, dynamic> map) {
    return WhoopAComparisonRecord(
      id: map['id'] as int?,
      sessionId: map['session_id'] as String,
      createdAtUtc: DateTime.fromMillisecondsSinceEpoch(
        map['created_at_utc'] as int,
        isUtc: true,
      ),
      algorithmVersion: map['algorithm_version'] as String? ?? '1.0.0',
      sleepOnsetUtc: map['sleep_onset_utc'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['sleep_onset_utc'] as int, isUtc: true)
          : null,
      sleepEndUtc: map['sleep_end_utc'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['sleep_end_utc'] as int, isUtc: true)
          : null,
      sleepDurationSeconds: map['sleep_duration_seconds'] as int?,
      awakeDurationSeconds: map['awake_duration_seconds'] as int?,
      lightDurationSeconds: map['light_duration_seconds'] as int?,
      deepDurationSeconds: map['deep_duration_seconds'] as int?,
      remDurationSeconds: map['rem_duration_seconds'] as int?,
      hrvRmssd: (map['hrv_rmssd'] as num?)?.toDouble(),
      rhrBpm: map['rhr_bpm'] as int?,
      respiratoryRate: (map['respiratory_rate'] as num?)?.toDouble(),
      recoveryScore: map['recovery_score'] as int?,
      sleepPerformanceScore: map['sleep_performance_score'] as int?,
      notes: map['notes'] as String?,
    );
  }

  final int? id;
  final String sessionId;
  final DateTime createdAtUtc;
  final String algorithmVersion;

  final DateTime? sleepOnsetUtc;
  final DateTime? sleepEndUtc;
  final int? sleepDurationSeconds;
  final int? awakeDurationSeconds;
  final int? lightDurationSeconds;
  final int? deepDurationSeconds;
  final int? remDurationSeconds;
  final double? hrvRmssd;
  final int? rhrBpm;
  final double? respiratoryRate;
  final int? recoveryScore;
  final int? sleepPerformanceScore;
  final String? notes;

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'session_id': sessionId,
      'created_at_utc': createdAtUtc.millisecondsSinceEpoch,
      'algorithm_version': algorithmVersion,
      'sleep_onset_utc': sleepOnsetUtc?.millisecondsSinceEpoch,
      'sleep_end_utc': sleepEndUtc?.millisecondsSinceEpoch,
      'sleep_duration_seconds': sleepDurationSeconds,
      'awake_duration_seconds': awakeDurationSeconds,
      'light_duration_seconds': lightDurationSeconds,
      'deep_duration_seconds': deepDurationSeconds,
      'rem_duration_seconds': remDurationSeconds,
      'hrv_rmssd': hrvRmssd,
      'rhr_bpm': rhrBpm,
      'respiratory_rate': respiratoryRate,
      'recovery_score': recoveryScore,
      'sleep_performance_score': sleepPerformanceScore,
      'notes': notes,
    };
  }
}

/// Rappresenta il confronto delta per una specifica metrica tra Beveltry e WHOOP A.
class MetricDeltaItem {
  const MetricDeltaItem({
    required this.metricLabel,
    required this.whoopAValue,
    required this.beveltryValue,
    required this.difference,
    this.percentDifference,
    this.scientificNote,
  });

  final String metricLabel;
  final String whoopAValue;
  final String beveltryValue;
  final String difference;
  final String? percentDifference;
  final String? scientificNote;
}

/// Calcola le discrepanze numeriche esclusivamente tra metriche direttamente comparabili.
List<MetricDeltaItem> computeWhoopAComparisonDeltas({
  required WhoopAComparisonRecord whoopA,
  required DateTime? beveltryOnsetUtc,
  required DateTime? beveltryEndUtc,
  required int beveltryTstSeconds,
  required int beveltryWasoSeconds,
  required double? beveltryHrvWholeMs,
  required double? beveltryHrvRollingMedianMs,
  required int? beveltryRhrBpm,
  required double? beveltryRespRpm,
}) {
  final items = <MetricDeltaItem>[];

  // 1. Inizio Sonno
  if (whoopA.sleepOnsetUtc != null && beveltryOnsetUtc != null) {
    final diffMinutes = beveltryOnsetUtc.difference(whoopA.sleepOnsetUtc!).inMinutes;
    final sign = diffMinutes > 0 ? '+' : '';
    items.add(
      MetricDeltaItem(
        metricLabel: 'Inizio Sonno (Sleep Onset)',
        whoopAValue: _formatTimeUtc(whoopA.sleepOnsetUtc!),
        beveltryValue: _formatTimeUtc(beveltryOnsetUtc),
        difference: '$sign$diffMinutes min',
        scientificNote: diffMinutes.abs() <= 15
            ? 'Ottima concordanza entro 15 minuti.'
            : 'Scostamento dovuto all\'assenza di accelerometro in Beveltry.',
      ),
    );
  }

  // 2. Risveglio Finale
  if (whoopA.sleepEndUtc != null && beveltryEndUtc != null) {
    final diffMinutes = beveltryEndUtc.difference(whoopA.sleepEndUtc!).inMinutes;
    final sign = diffMinutes > 0 ? '+' : '';
    items.add(
      MetricDeltaItem(
        metricLabel: 'Risveglio Finale (Sleep Offset)',
        whoopAValue: _formatTimeUtc(whoopA.sleepEndUtc!),
        beveltryValue: _formatTimeUtc(beveltryEndUtc),
        difference: '$sign$diffMinutes min',
      ),
    );
  }

  // 3. Durata Sonno (TST)
  if (whoopA.sleepDurationSeconds != null) {
    final diffMinutes = ((beveltryTstSeconds - whoopA.sleepDurationSeconds!) / 60.0).round();
    final sign = diffMinutes > 0 ? '+' : '';
    items.add(
      MetricDeltaItem(
        metricLabel: 'Tempo Totale di Sonno (TST)',
        whoopAValue: _formatDurationSec(whoopA.sleepDurationSeconds!),
        beveltryValue: _formatDurationSec(beveltryTstSeconds),
        difference: '$sign$diffMinutes min',
      ),
    );
  }

  // 4. Veglia dopo addormentamento (WASO)
  if (whoopA.awakeDurationSeconds != null) {
    final diffMinutes = ((beveltryWasoSeconds - whoopA.awakeDurationSeconds!) / 60.0).round();
    final sign = diffMinutes > 0 ? '+' : '';
    items.add(
      MetricDeltaItem(
        metricLabel: 'Tempo Veglia (WASO)',
        whoopAValue: _formatDurationSec(whoopA.awakeDurationSeconds!),
        beveltryValue: _formatDurationSec(beveltryWasoSeconds),
        difference: '$sign$diffMinutes min',
        scientificNote: 'WHOOP A usa il movimento; Beveltry usa solo variazioni FC.',
      ),
    );
  }

  // 5. HRV RMSSD
  if (whoopA.hrvRmssd != null) {
    final hrvTarget = beveltryHrvRollingMedianMs ?? beveltryHrvWholeMs;
    if (hrvTarget != null) {
      final diff = hrvTarget - whoopA.hrvRmssd!;
      final pct = (diff / whoopA.hrvRmssd!) * 100.0;
      final sign = diff > 0 ? '+' : '';
      items.add(
        MetricDeltaItem(
          metricLabel: 'HRV RMSSD Notturna',
          whoopAValue: '${whoopA.hrvRmssd!.toStringAsFixed(1)} ms',
          beveltryValue: '${hrvTarget.toStringAsFixed(1)} ms',
          difference: '$sign${diff.toStringAsFixed(1)} ms',
          percentDifference: '$sign${pct.toStringAsFixed(1)}%',
          scientificNote:
              'WHOOP ancora l\'HRV all\'ultimo sonno profondo; Beveltry mostra l\'intera notte e mediana finestre.',
        ),
      );
    }
  }

  // 6. RHR
  if (whoopA.rhrBpm != null && beveltryRhrBpm != null) {
    final diff = beveltryRhrBpm - whoopA.rhrBpm!;
    final sign = diff > 0 ? '+' : '';
    items.add(
      MetricDeltaItem(
        metricLabel: 'Frequenza a Riposo (RHR)',
        whoopAValue: '${whoopA.rhrBpm} BPM',
        beveltryValue: '$beveltryRhrBpm BPM',
        difference: '$sign$diff BPM',
        scientificNote:
            'Beveltry calcola il minimo su rolling 5 min. WHOOP pesa verso l\'ultimo periodo SWS.',
      ),
    );
  }

  // 7. Frequenza Respiratoria
  if (whoopA.respiratoryRate != null && beveltryRespRpm != null) {
    final diff = beveltryRespRpm - whoopA.respiratoryRate!;
    final sign = diff > 0 ? '+' : '';
    items.add(
      MetricDeltaItem(
        metricLabel: 'Frequenza Respiratoria',
        whoopAValue: '${whoopA.respiratoryRate!.toStringAsFixed(1)} RPM',
        beveltryValue: '${beveltryRespRpm.toStringAsFixed(1)} RPM',
        difference: '$sign${diff.toStringAsFixed(1)} RPM',
        scientificNote:
            'Entrambi usano la modulazione RSA; Beveltry stima la mediana spettrale su finestre da 4 min.',
      ),
    );
  }

  return items;
}

String _formatTimeUtc(DateTime dt) {
  final local = dt.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

String _formatDurationSec(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h > 0) {
    return '${h}h ${m}m';
  }
  return '${m}m';
}
