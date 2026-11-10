import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../src/repository/whoop_repository.dart';
import '../src/sleep_lab/cardiac_sleep_wake_estimator.dart';
import '../src/sleep_lab/epoch_engine.dart';
import '../src/sleep_lab/hrv_window_lab.dart';
import '../src/sleep_lab/sleep_lab_models.dart';
import '../src/sleep_lab/sleep_lab_service.dart';
import '../src/sleep_lab/whoop_a_comparison.dart';

/// Schermata principale per Beveltry Sleep Lab (Task 08A).
class SleepLabScreen extends StatefulWidget {
  const SleepLabScreen({
    super.key,
    required this.repository,
    this.initialSessionId,
    this.initialAnalysis,
  });

  final WhoopRepository repository;
  final String? initialSessionId;
  final SleepLabAnalysis? initialAnalysis;

  @override
  State<SleepLabScreen> createState() => _SleepLabScreenState();
}

class _SleepLabScreenState extends State<SleepLabScreen> {
  late final SleepLabService _sleepLabService;
  List<Map<String, dynamic>> _availableSessions = [];
  String? _selectedSessionId;
  SleepLabAnalysis? _analysis;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _sleepLabService = SleepLabService(repository: widget.repository);
    if (widget.initialAnalysis != null) {
      _analysis = widget.initialAnalysis;
      _isLoading = false;
    } else {
      _loadInitialData();
    }
  }

  Future<void> _loadInitialData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final sessions = await _sleepLabService.getAvailableSessions();
      if (!mounted) return;

      if (sessions.isEmpty) {
        setState(() {
          _availableSessions = [];
          _isLoading = false;
        });
        return;
      }

      setState(() {
        _availableSessions = sessions;
        if (widget.initialSessionId != null) {
          _selectedSessionId = widget.initialSessionId;
        } else {
          _selectedSessionId = sessions.first['session_id'] as String;
        }
      });

      if (_selectedSessionId != null) {
        await _runAnalysis(_selectedSessionId!);
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Errore nel caricamento delle sessioni: $e';
      });
    }
  }

  Future<void> _runAnalysis(String sessionId, {DateTime? manualOnset, DateTime? manualEnd}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final analysis = await _sleepLabService.analyzeSession(
        sessionId,
        manualOnsetUtc: manualOnset,
        manualEndUtc: manualEnd,
      );

      if (!mounted) return;
      setState(() {
        _analysis = analysis;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Errore durante l\'analisi Sleep Lab: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Beveltry Sleep Lab'),
        backgroundColor: const Color(0xFF0D1B2A),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rianalizza',
            onPressed: _selectedSessionId != null
                ? () => _runAnalysis(_selectedSessionId!)
                : null,
          ),
        ],
      ),
      backgroundColor: const Color(0xFF080C14),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.tealAccent),
            SizedBox(height: 16),
            Text(
              'Calcolo deterministico Sleep Lab in corso...',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadInitialData,
                child: const Text('Riprova'),
              ),
            ],
          ),
        ),
      );
    }

    if (_analysis == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.nightlight_round, color: Colors.blueGrey, size: 56),
              const SizedBox(height: 16),
              const Text(
                'Nessuna sessione notturna registrata.',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Avvia prima una registrazione con il Night Recorder per visualizzare l\'analisi.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    final a = _analysis!;

    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        // 1. SELETTORE SESSIONE
        _buildSessionSelector(),
        const SizedBox(height: 16),

        // 2. CARD CONFINI & SONNO
        _buildSleepSummaryCard(a),
        const SizedBox(height: 16),

        // 3. GRAFICO HR E SLEEP/WAKE
        _buildChartCard(a),
        const SizedBox(height: 16),

        // 4. IPNOGRAMMA FASI (CON UNAVAILABLE PER LIGHT/DEEP/REM)
        _buildStagingCard(a),
        const SizedBox(height: 16),

        // 5. HRV WINDOW LAB
        _buildHrvLabCard(a),
        const SizedBox(height: 16),

        // 6. RHR E RESPIRAZIONE (RSA)
        _buildRhrAndRespirationCard(a),
        const SizedBox(height: 16),

        // 7. QUALITÀ SEGNALE & COPERTURA
        _buildQualityCard(a),
        const SizedBox(height: 16),

        // 8. CONFRONTO WHOOP A
        _buildWhoopAComparisonCard(a),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildSessionSelector() {
    if (_availableSessions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF131D2E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.teal.withValues(alpha: 0.3)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedSessionId,
          isExpanded: true,
          dropdownColor: const Color(0xFF131D2E),
          style: const TextStyle(color: Colors.white, fontSize: 14),
          icon: const Icon(Icons.arrow_drop_down, color: Colors.tealAccent),
          items: _availableSessions.map((s) {
            final id = s['session_id'] as String;
            final startMs = s['start_time_utc'] as int;
            final dt = DateTime.fromMillisecondsSinceEpoch(startMs, isUtc: true).toLocal();
            final samples = s['total_samples'] as int? ?? 0;
            final dateStr = '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
            return DropdownMenuItem<String>(
              value: id,
              child: Text(
                'Notte $dateStr ($samples campioni)',
                overflow: TextOverflow.ellipsis,
              ),
            );
          }).toList(),
          onChanged: (newId) {
            if (newId != null && newId != _selectedSessionId) {
              setState(() => _selectedSessionId = newId);
              _runAnalysis(newId);
            }
          },
        ),
      ),
    );
  }

  Widget _buildSleepSummaryCard(SleepLabAnalysis a) {
    final sw = a.sleepWake;
    final onsetStr = sw.effectiveOnsetUtc != null ? _formatTime(sw.effectiveOnsetUtc!) : '--:--';
    final offsetStr = sw.effectiveEndUtc != null ? _formatTime(sw.effectiveEndUtc!) : '--:--';

    return Card(
      color: const Color(0xFF131D2E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.teal.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.bedtime, color: Colors.tealAccent, size: 22),
                    SizedBox(width: 8),
                    Text(
                      'Sonno & Confini',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                _buildStatusBadge(sw.provenance),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildMetricTile(
                    'Inizio Sonno',
                    onsetStr,
                    subtitle: sw.isManualOverride && sw.manualOnsetUtc != null ? 'Corretto a mano' : 'Stimato da FC',
                    icon: Icons.login,
                  ),
                ),
                Expanded(
                  child: _buildMetricTile(
                    'Risveglio Finale',
                    offsetStr,
                    subtitle: sw.isManualOverride && sw.manualEndUtc != null ? 'Corretto a mano' : 'Stimato da FC',
                    icon: Icons.logout,
                  ),
                ),
              ],
            ),
            const Divider(color: Colors.white10, height: 24),
            Row(
              children: [
                Expanded(
                  child: _buildMetricTile(
                    'Tempo di Sonno (TST)',
                    _formatDuration(sw.totalSleepDurationSeconds),
                    subtitle: 'Epoche classificate sonno',
                    icon: Icons.hotel,
                  ),
                ),
                Expanded(
                  child: _buildMetricTile(
                    'Veglia (WASO)',
                    _formatDuration(sw.wasoDurationSeconds),
                    subtitle: '${sw.awakeningsCount} risvegli intermedi',
                    icon: Icons.airline_seat_flat,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildMetricTile(
                    'Efficienza Sonno',
                    '${sw.sleepEfficiencyPercent.toStringAsFixed(1)}%',
                    subtitle: 'TST / (TST + WASO)',
                    icon: Icons.pie_chart,
                    highlightColor: Colors.tealAccent,
                  ),
                ),
                Expanded(
                  child: _buildMetricTile(
                    'Latenza Iniziale',
                    '${sw.sleepOnsetLatencySeconds ~/ 60} min',
                    subtitle: 'Tempo prima del sonno',
                    icon: Icons.timer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () => _showManualCorrectionDialog(a),
              icon: const Icon(Icons.edit, size: 16, color: Colors.tealAccent),
              label: Text(
                sw.isManualOverride ? 'Modifica Confini Manuali' : 'Correggi Inizio/Fine Sonno a Mano',
                style: const TextStyle(fontSize: 13, color: Colors.tealAccent),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.teal.withValues(alpha: 0.5)),
                minimumSize: const Size.fromHeight(36),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChartCard(SleepLabAnalysis a) {
    return Card(
      color: const Color(0xFF131D2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Frequenza Cardiaca & Classificazione Sonno/Veglia',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'Curva HR notturna con sovrimpressione sperimentale delle epoche di sonno (verde) e risveglio/WASO (arancione).',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 180,
              width: double.infinity,
              child: CustomPaint(
                painter: SleepLabHrChartPainter(
                  epochs: a.epochs,
                  sleepClassifications: a.sleepWake.epochs,
                  effectiveOnset: a.sleepWake.effectiveOnsetUtc,
                  effectiveEnd: a.sleepWake.effectiveEndUtc,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildLegendItem(Colors.greenAccent, 'Sonno'),
                const SizedBox(width: 16),
                _buildLegendItem(Colors.orangeAccent, 'Veglia / WASO'),
                const SizedBox(width: 16),
                _buildLegendItem(Colors.grey, 'Pre/Post Notte'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStagingCard(SleepLabAnalysis a) {
    return Card(
      color: const Color(0xFF131D2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Stadiazione Fasi del Sonno',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                _buildStatusBadge(MetricProvenanceStatus.unavailable),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.science, color: Colors.amberAccent, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'FASI LIGHT / DEEP / REM: NON DISPONIBILI\n'
                      'La suddivisione in 4 stadi richiede un classificatore combinato di accelerometria multiasse e fotopletismografia PPG (previsto per TASK 08B).\n'
                      'In conformità ai requisiti scientifici, Beveltry NON simula percentuali arbitrarie né inventa stadi senza sensori comprovati.',
                      style: TextStyle(fontSize: 11, color: Colors.white70, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHrvLabCard(SleepLabAnalysis a) {
    final lab = a.hrvLab;
    final wholeDirect = lab.wholeSleepRmssd.valueDirectMs != null
        ? '${lab.wholeSleepRmssd.valueDirectMs!.toStringAsFixed(1)} ms'
        : '-- ms';
    final whole1024 = lab.wholeSleepRmssd.value1024Ms != null
        ? '${lab.wholeSleepRmssd.value1024Ms!.toStringAsFixed(1)} ms'
        : '-- ms';

    return Card(
      color: const Color(0xFF131D2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.favorite_border, color: Colors.redAccent, size: 22),
                    SizedBox(width: 8),
                    Text(
                      'HRV Window Lab',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                _buildStatusBadge(MetricProvenanceStatus.measured),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Calcolo RMSSD segmentato Task Force 1996 su serie continue. Nessun accorpamento di segmenti discontinui.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  _buildHrvRow('Intero Sonno (ms diretti WHOOP):', wholeDirect, isBold: true),
                  const SizedBox(height: 6),
                  _buildHrvRow('Intero Sonno (standard SIG 1/1024s):', whole1024),
                  const SizedBox(height: 6),
                  _buildHrvRow('Coppie R-R valide consecutive:', '${lab.wholeSleepRmssd.validPairsCount}'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Finestre Mobili 5 Minuti (Rolling Window):',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.tealAccent),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _buildMetricTile('Mediana Finestre', lab.rolling5MinMedianMs != null ? '${lab.rolling5MinMedianMs!.toStringAsFixed(1)} ms' : '--')),
                Expanded(child: _buildMetricTile('Media Finestre', lab.rolling5MinMeanMs != null ? '${lab.rolling5MinMeanMs!.toStringAsFixed(1)} ms' : '--')),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _buildMetricTile('Minimo Finestre', lab.rolling5MinMinMs != null ? '${lab.rolling5MinMinMs!.toStringAsFixed(1)} ms' : '--')),
                Expanded(child: _buildMetricTile('Massimo Finestre', lab.rolling5MinMaxMs != null ? '${lab.rolling5MinMaxMs!.toStringAsFixed(1)} ms' : '--')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Finestre 5-min valide: ${lab.rolling5MinValidWindows} su ${lab.rolling5MinTotalWindows} valutate',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const Divider(color: Colors.white10, height: 24),
            const Text(
              'Candidati WHOOP Slow-Wave Sleep (Deep):',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.amberAccent),
            ),
            const SizedBox(height: 6),
            _buildDeepCandidateTile('B2: rmssd_all_deep', lab.rmssdAllDeep),
            _buildDeepCandidateTile('B3: rmssd_last_deep_episode', lab.rmssdLastDeepEpisode),
            _buildDeepCandidateTile('B4: rmssd_last5_deep (candidato pubblico WHOOP)', lab.rmssdLast5MinDeep),
            _buildDeepCandidateTile('B5: rmssd_best5_last_deep (candidato brevetto)', lab.rmssdBest5MinDeep),
            _buildDeepCandidateTile('B6: rmssd_weighted_late_deep (media pesata finale)', lab.rmssdWeightedLateDeep),
          ],
        ),
      ),
    );
  }

  Widget _buildRhrAndRespirationCard(SleepLabAnalysis a) {
    final r = a.rhr;
    final resp = a.respiration;

    return Card(
      color: const Color(0xFF131D2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.air, color: Colors.lightBlueAccent, size: 22),
                    SizedBox(width: 8),
                    Text(
                      'RHR & Frequenza Respiratoria',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                _buildStatusBadge(resp.status),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildMetricTile(
                    'RHR Minimo 5-Min',
                    r.min5MinBpm != null ? '${r.min5MinBpm} BPM' : '-- BPM',
                    subtitle: 'Metrica misurata indipendente',
                    icon: Icons.monitor_heart,
                    highlightColor: Colors.greenAccent,
                  ),
                ),
                Expanded(
                  child: _buildMetricTile(
                    'Media Notturna FC',
                    r.wholeSleepMeanBpm != null ? '${r.wholeSleepMeanBpm!.toStringAsFixed(1)} BPM' : '-- BPM',
                    subtitle: 'Media su tutto il sonno',
                    icon: Icons.timeline,
                  ),
                ),
              ],
            ),
            const Divider(color: Colors.white10, height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Frequenza Respiratoria (RSA)',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                _buildStatusBadge(resp.status),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Stima derivata dall\'Aritmia Sinusale Respiratoria (modulazione spettrale R-R in banda 9-27 RPM). Nessuna formula da FC.',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 10),
            if (resp.status != MetricProvenanceStatus.unavailable && resp.medianBreathsPerMinute != null) ...[
              Row(
                children: [
                  Expanded(
                    child: _buildMetricTile(
                      'Mediana Notturna',
                      '${resp.medianBreathsPerMinute} RPM',
                      subtitle: 'Respiri al minuto',
                      highlightColor: Colors.lightBlueAccent,
                      icon: Icons.waves,
                    ),
                  ),
                  Expanded(
                    child: _buildMetricTile(
                      'Finestre Valide',
                      '${resp.validWindowsCount} / ${resp.totalWindowsEvaluated}',
                      subtitle: 'SNR spettrale >= 2.0',
                      icon: Icons.check_circle_outline,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Range osservato: ${resp.minBreathsPerMinute} – ${resp.maxBreathsPerMinute} RPM (Media: ${resp.meanBreathsPerMinute})',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ] else ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  resp.unavailabilityReason ?? 'Frequenza respiratoria non disponibile.',
                  style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildQualityCard(SleepLabAnalysis a) {
    final q = a.quality;

    return Card(
      color: const Color(0xFF131D2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.verified, color: Colors.tealAccent, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Qualità Segnale & Audit Sensori',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Text(
                  '${q.sampleCoveragePercent.toStringAsFixed(1)}% Copertura',
                  style: const TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildQualityRow('Campioni HR 0x2A37 ricevuti:', '${q.totalSamplesCount}'),
            _buildQualityRow('Intervalli R-R totali:', '${q.totalBeatsCount}'),
            _buildQualityRow('Epoche 30s utilizzabili:', '${q.usableEpochsCount} / ${q.totalEpochsCount} (${q.epochUsabilityPercent.toStringAsFixed(1)}%)'),
            _buildQualityRow('Lacune > 2 secondi:', '${q.gapsCount}'),
            _buildQualityRow('Lacuna massima osservata:', '${q.maxGapSeconds.toStringAsFixed(1)} s'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Sensori fisici WHOOP B: Accelerometro, Giroscopio, PPG ottico e Temperatura risiedono nel protocollo Puffin 0x2F non autenticato durante la sessione notturna. Solo la caratteristica standard GATT 0x2A37 (HR/RR) era attiva.',
                style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWhoopAComparisonCard(SleepLabAnalysis a) {
    final whoopA = a.whoopAComparison;
    final deltas = a.comparisonDeltas;

    return Card(
      color: const Color(0xFF131D2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.compare_arrows, color: Colors.amberAccent, size: 22),
                    SizedBox(width: 8),
                    Text(
                      'Confronto WHOOP A',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                TextButton.icon(
                  onPressed: () => _showWhoopAInputDialog(a),
                  icon: const Icon(Icons.add_circle_outline, size: 16, color: Colors.amberAccent),
                  label: Text(
                    whoopA == null ? 'Inserisci Dati' : 'Modifica',
                    style: const TextStyle(color: Colors.amberAccent),
                  ),
                ),
              ],
            ),
            const Text(
              'Inserisci i risultati ufficiali registrati in parallelo dal cinturino WHOOP A per verificare le differenze numeriche.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            if (whoopA == null) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white10),
                ),
                child: const Center(
                  child: Text(
                    'Nessun dato WHOOP A inserito per questa notte.\nTocca "Inserisci Dati" per eseguire il confronto incrociato.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ),
            ] else ...[
              // TABELLA DELTAS
              Table(
                columnWidths: const {
                  0: FlexColumnWidth(2.2),
                  1: FlexColumnWidth(1.4),
                  2: FlexColumnWidth(1.4),
                  3: FlexColumnWidth(1.3),
                },
                border: TableBorder.all(color: Colors.white10),
                children: [
                  TableRow(
                    decoration: const BoxDecoration(color: Colors.black45),
                    children: [
                      _buildTableHeaderCell('Metrica'),
                      _buildTableHeaderCell('WHOOP A'),
                      _buildTableHeaderCell('Beveltry'),
                      _buildTableHeaderCell('Delta'),
                    ],
                  ),
                  ...deltas.map((d) {
                    return TableRow(
                      children: [
                        _buildTableCell(d.metricLabel, isHeader: false),
                        _buildTableCell(d.whoopAValue, isHeader: false),
                        _buildTableCell(d.beveltryValue, isHeader: false),
                        _buildTableCell(d.difference, isHighlight: true),
                      ],
                    );
                  }),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Nota metodologica: WHOOP A è impiegato come referenza comportamentale per il reverse engineering, non come verità clinica assoluta (polisonnografia PSG).',
                style: TextStyle(fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // DIALOGS & SHEET
  void _showManualCorrectionDialog(SleepLabAnalysis a) {
    final sw = a.sleepWake;
    var onset = sw.effectiveOnsetUtc ?? a.sessionSummary.startTimeUtc;
    var offset = sw.effectiveEndUtc ?? a.sessionSummary.endTimeUtc ?? DateTime.now().toUtc();

    showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF131D2E),
              title: const Text('Correggi Confini Sonno'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Modifica manualmente l\'orario di addormentamento e risveglio per verificare l\'impatto sulle metriche.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    title: const Text('Inizio Sonno (Locale):', style: TextStyle(fontSize: 14)),
                    subtitle: Text(_formatDateTimeLocal(onset)),
                    trailing: const Icon(Icons.access_time, color: Colors.tealAccent),
                    onTap: () async {
                      final time = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.fromDateTime(onset.toLocal()),
                      );
                      if (time != null) {
                        final local = onset.toLocal();
                        final newLocal = DateTime(local.year, local.month, local.day, time.hour, time.minute);
                        setDialogState(() => onset = newLocal.toUtc());
                      }
                    },
                  ),
                  ListTile(
                    title: const Text('Risveglio Finale (Locale):', style: TextStyle(fontSize: 14)),
                    subtitle: Text(_formatDateTimeLocal(offset)),
                    trailing: const Icon(Icons.access_time, color: Colors.tealAccent),
                    onTap: () async {
                      final time = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.fromDateTime(offset.toLocal()),
                      );
                      if (time != null) {
                        final local = offset.toLocal();
                        final newLocal = DateTime(local.year, local.month, local.day, time.hour, time.minute);
                        setDialogState(() => offset = newLocal.toUtc());
                      }
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await _sleepLabService.saveManualBoundaries(
                      sessionId: a.sessionSummary.sessionId,
                      manualOnsetUtc: null,
                      manualEndUtc: null,
                    );
                    _runAnalysis(a.sessionSummary.sessionId);
                  },
                  child: const Text('Ripristina Stima FC', style: TextStyle(color: Colors.redAccent)),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Annulla', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await _sleepLabService.saveManualBoundaries(
                      sessionId: a.sessionSummary.sessionId,
                      manualOnsetUtc: onset,
                      manualEndUtc: offset,
                    );
                    _runAnalysis(a.sessionSummary.sessionId, manualOnset: onset, manualEnd: offset);
                  },
                  child: const Text('Salva Confini'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showWhoopAInputDialog(SleepLabAnalysis a) {
    final existing = a.whoopAComparison;
    final tstMinutesController = TextEditingController(text: existing?.sleepDurationSeconds != null ? '${existing!.sleepDurationSeconds! ~/ 60}' : '');
    final wasoMinutesController = TextEditingController(text: existing?.awakeDurationSeconds != null ? '${existing!.awakeDurationSeconds! ~/ 60}' : '');
    final hrvController = TextEditingController(text: existing?.hrvRmssd != null ? '${existing!.hrvRmssd}' : '');
    final rhrController = TextEditingController(text: existing?.rhrBpm != null ? '${existing!.rhrBpm}' : '');
    final respController = TextEditingController(text: existing?.respiratoryRate != null ? '${existing!.respiratoryRate}' : '');
    final notesController = TextEditingController(text: existing?.notes ?? '');

    var onset = existing?.sleepOnsetUtc ?? a.sleepWake.effectiveOnsetUtc ?? a.sessionSummary.startTimeUtc;
    var offset = existing?.sleepEndUtc ?? a.sleepWake.effectiveEndUtc ?? a.sessionSummary.endTimeUtc ?? DateTime.now().toUtc();

    showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF131D2E),
              title: const Text('Inserisci Dati WHOOP A'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Inizio Sonno WHOOP A:', style: TextStyle(fontSize: 13)),
                      subtitle: Text(_formatDateTimeLocal(onset)),
                      trailing: const Icon(Icons.access_time, color: Colors.amberAccent),
                      onTap: () async {
                        final time = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(onset.toLocal()),
                        );
                        if (time != null) {
                          final local = onset.toLocal();
                          final newLocal = DateTime(local.year, local.month, local.day, time.hour, time.minute);
                          setDialogState(() => onset = newLocal.toUtc());
                        }
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Risveglio Finale WHOOP A:', style: TextStyle(fontSize: 13)),
                      subtitle: Text(_formatDateTimeLocal(offset)),
                      trailing: const Icon(Icons.access_time, color: Colors.amberAccent),
                      onTap: () async {
                        final time = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(offset.toLocal()),
                        );
                        if (time != null) {
                          final local = offset.toLocal();
                          final newLocal = DateTime(local.year, local.month, local.day, time.hour, time.minute);
                          setDialogState(() => offset = newLocal.toUtc());
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    _buildInputField('Tempo di Sonno TST (minuti):', tstMinutesController, keyboardType: TextInputType.number),
                    _buildInputField('Tempo Sveglio WASO (minuti):', wasoMinutesController, keyboardType: TextInputType.number),
                    _buildInputField('HRV rMSSD ufficiale (ms):', hrvController, keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                    _buildInputField('RHR Frequenza a Riposo (BPM):', rhrController, keyboardType: TextInputType.number),
                    _buildInputField('Frequenza Respiratoria (RPM):', respController, keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                    _buildInputField('Note / Commenti:', notesController),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Annulla', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.amber.shade800),
                  onPressed: () async {
                    final tstMin = int.tryParse(tstMinutesController.text.trim());
                    final wasoMin = int.tryParse(wasoMinutesController.text.trim());
                    final hrv = double.tryParse(hrvController.text.trim());
                    final rhr = int.tryParse(rhrController.text.trim());
                    final resp = double.tryParse(respController.text.trim());

                    final record = WhoopAComparisonRecord(
                      sessionId: a.sessionSummary.sessionId,
                      createdAtUtc: DateTime.now().toUtc(),
                      algorithmVersion: '1.0.0',
                      sleepOnsetUtc: onset,
                      sleepEndUtc: offset,
                      sleepDurationSeconds: tstMin != null ? tstMin * 60 : null,
                      awakeDurationSeconds: wasoMin != null ? wasoMin * 60 : null,
                      hrvRmssd: hrv,
                      rhrBpm: rhr,
                      respiratoryRate: resp,
                      notes: notesController.text.trim().isNotEmpty ? notesController.text.trim() : null,
                    );

                    Navigator.of(context).pop();
                    await _sleepLabService.saveWhoopAComparison(record);
                    _runAnalysis(a.sessionSummary.sessionId);
                  },
                  child: const Text('Salva Confronto'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildInputField(String label, TextEditingController controller, {TextInputType? keyboardType}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(fontSize: 12, color: Colors.grey),
          isDense: true,
          filled: true,
          fillColor: Colors.black26,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  // WIDGET HELPERS
  Widget _buildStatusBadge(MetricProvenanceStatus status) {
    Color bg;
    Color fg;
    String text;

    switch (status) {
      case MetricProvenanceStatus.measured:
        bg = Colors.green.shade900;
        fg = Colors.greenAccent;
        text = 'MEASURED';
      case MetricProvenanceStatus.estimated:
        bg = Colors.blue.shade900;
        fg = Colors.lightBlueAccent;
        text = 'ESTIMATED';
      case MetricProvenanceStatus.experimentalCardiacOnly:
        bg = Colors.purple.shade900;
        fg = Colors.purpleAccent;
        text = 'EXPERIMENTAL_CARDIAC_ONLY';
      case MetricProvenanceStatus.experimental:
        bg = Colors.orange.shade900;
        fg = Colors.amberAccent;
        text = 'EXPERIMENTAL';
      case MetricProvenanceStatus.unavailable:
        bg = Colors.grey.shade800;
        fg = Colors.grey.shade400;
        text = 'UNAVAILABLE';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildMetricTile(String label, String value, {String? subtitle, IconData? icon, Color? highlightColor}) {
    return Container(
      padding: const EdgeInsets.all(10),
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: Colors.grey),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: highlightColor ?? Colors.white,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 10, color: Colors.grey),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHrvRow(String label, String value, {bool isBold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade300),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            color: isBold ? Colors.tealAccent : Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildDeepCandidateTile(String label, MetricCandidateResult candidate) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          candidate.isAvailable
              ? Text('${candidate.valueDirectMs!.toStringAsFixed(1)} ms')
              : _buildStatusBadge(MetricProvenanceStatus.unavailable),
        ],
      ),
    );
  }

  Widget _buildQualityRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildTableHeaderCell(String text) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildTableCell(String text, {bool isHeader = false, bool isHighlight = false}) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: isHighlight ? Colors.amberAccent : Colors.white70,
          fontWeight: isHighlight ? FontWeight.bold : FontWeight.normal,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildLegendItem(Color color, String text) {
    return Row(
      children: [
        Container(width: 10, height: 10, color: color),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }

  String _formatTime(DateTime dt) {
    final l = dt.toLocal();
    final h = l.hour.toString().padLeft(2, '0');
    final m = l.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String _formatDateTimeLocal(DateTime dt) {
    final l = dt.toLocal();
    final h = l.hour.toString().padLeft(2, '0');
    final m = l.minute.toString().padLeft(2, '0');
    return '${l.day.toString().padLeft(2, '0')}/${l.month.toString().padLeft(2, '0')} ore $h:$m';
  }

  String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }
}

/// CustomPainter per il grafico combinato HR e classificazione sonno/veglia.
class SleepLabHrChartPainter extends CustomPainter {
  SleepLabHrChartPainter({
    required this.epochs,
    required this.sleepClassifications,
    this.effectiveOnset,
    this.effectiveEnd,
  });

  final List<Epoch30s> epochs;
  final List<EpochSleepWakeClassification> sleepClassifications;
  final DateTime? effectiveOnset;
  final DateTime? effectiveEnd;

  @override
  void paint(Canvas canvas, Size size) {
    if (epochs.isEmpty) return;

    // Background
    final bgPaint = Paint()..color = const Color(0xFF0A0F1A);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    final n = epochs.length;
    final dx = size.width / math.max(1, n);

    // 1. Shading per Sleep / Wake
    final sleepPaint = Paint()..color = Colors.green.withValues(alpha: 0.15);
    final wakePaint = Paint()..color = Colors.orange.withValues(alpha: 0.25);
    final outsidePaint = Paint()..color = Colors.black45;

    for (var i = 0; i < n; i++) {
      final ep = epochs[i];
      final isInside = (effectiveOnset == null || ep.startUtc.isAfter(effectiveOnset!) || ep.startUtc.isAtSameMomentAs(effectiveOnset!)) &&
          (effectiveEnd == null || ep.endUtc.isBefore(effectiveEnd!) || ep.endUtc.isAtSameMomentAs(effectiveEnd!));

      final x = i * dx;
      final rect = Rect.fromLTWH(x, 0, dx + 0.5, size.height);

      if (!isInside) {
        canvas.drawRect(rect, outsidePaint);
      } else {
        final isAsleep = i < sleepClassifications.length && sleepClassifications[i].isAsleep;
        canvas.drawRect(rect, isAsleep ? sleepPaint : wakePaint);
      }
    }

    // 2. Griglia orizzontale e curva HR
    final validHrs = <double>[];
    for (final ep in epochs) {
      final m = ep.hrMean;
      if (m != null) {
        validHrs.add(m);
      }
    }
    if (validHrs.isEmpty) return;

    final minHr = validHrs.reduce(math.min) - 5;
    final maxHr = validHrs.reduce(math.max) + 5;
    final hrRange = math.max(10.0, maxHr - minHr);

    final linePaint = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final path = Path();
    var hasStarted = false;

    for (var i = 0; i < n; i++) {
      final hr = epochs[i].hrMean;
      if (hr == null) continue;

      final x = (i + 0.5) * dx;
      final normY = (hr - minHr) / hrRange;
      final y = size.height - (normY * size.height).clamp(0.0, size.height);

      if (!hasStarted) {
        path.moveTo(x, y);
        hasStarted = true;
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant SleepLabHrChartPainter oldDelegate) => true;
}
