import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/ble/ble.dart';
import '../src/records/night_session_summary.dart';
import '../src/records/standard_hr_record.dart';
import '../src/repository/whoop_repository.dart';
import '../src/services/sync_service.dart';
import 'sleep_lab_screen.dart';

/// Schermata minimale dedicata alla modalità NIGHT RECORDER (Task 07).
///
/// Acquisisce e salva campioni HR e intervalli R-R reali su SQLite dal WHOOP 5.0
/// per tutta la notte, operando in modo autonomo e indipendente dal protocollo Puffin.
class NightRecorderScreen extends StatefulWidget {
  const NightRecorderScreen({
    super.key,
    required this.repository,
    required this.syncService,
  });

  final WhoopRepository repository;
  final SyncService syncService;

  @override
  State<NightRecorderScreen> createState() => _NightRecorderScreenState();
}

class _NightRecorderScreenState extends State<NightRecorderScreen> {
  bool _isRecording = false;
  String? _sessionId;
  DateTime? _sessionStartTime;
  int _samplesCount = 0;
  int _rrCount = 0;
  int? _lastHr;
  DateTime? _lastHrTimestamp;
  int _disconnectionsCount = 0;
  String _connState = 'CONNECTED';
  bool _isAnalyzing = false;
  NightSessionSummary? _latestSummary;

  Timer? _tickTimer;
  StreamSubscription? _recorderSub;
  StreamSubscription? _standardHrSub;
  StreamSubscription? _alwaysOnSub;

  @override
  void initState() {
    super.initState();
    _checkExistingRecording();
    _initListeners();
    _startTicker();
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _recorderSub?.cancel();
    _standardHrSub?.cancel();
    _alwaysOnSub?.cancel();
    widget.syncService.liveHrNotifier.removeListener(_onLiveHrChanged);
    widget.syncService.connectionStateNotifier.removeListener(_onConnChanged);
    super.dispose();
  }

  void _startTicker() {
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _checkExistingRecording() async {
    final transport = widget.syncService.transport;
    if (transport is MethodChannelPuffinTransport) {
      try {
        final status = await transport.getNightRecordingStatus();
        final isRec = status['isRecording'] as bool? ?? false;
        if (isRec && mounted) {
          setState(() {
            _isRecording = true;
            _sessionId = status['sessionId'] as String?;
            _samplesCount = status['totalSamples'] as int? ?? 0;
            _rrCount = status['totalRr'] as int? ?? 0;
            _disconnectionsCount = status['disconnectionsCount'] as int? ?? 0;
            _connState = status['connectionState'] as String? ?? 'CONNECTED';
            final lastTs = status['lastSampleTimestampUtc'] as int?;
            if (lastTs != null) {
              _lastHrTimestamp = DateTime.fromMillisecondsSinceEpoch(lastTs, isUtc: true);
            }
          });
          return;
        }
      } catch (_) {}
    }

    // Se non in registrazione attiva, verifica se esiste una sessione notturna registrata nel database
    try {
      final sessions = await widget.repository.getAllNightSessions();
      if (sessions.isNotEmpty && mounted) {
        final lastSessionId = sessions.first['session_id'] as String;
        final summary = await widget.repository.getNightSessionSummary(lastSessionId);
        if (mounted) {
          setState(() {
            _sessionId = lastSessionId;
            _latestSummary = summary;
          });
        }
      }
    } catch (_) {}
  }

  void _initListeners() {
    final transport = widget.syncService.transport;

    // Ascolto aggiornamenti nativi da WhoopConnectionService
    if (transport is MethodChannelPuffinTransport) {
      _recorderSub = transport.onNightRecorderUpdate.listen((map) {
        if (!mounted) return;
        setState(() {
          _samplesCount = map['totalSamples'] as int? ?? _samplesCount;
          _rrCount = map['totalRr'] as int? ?? _rrCount;
          _disconnectionsCount = map['disconnectionsCount'] as int? ?? _disconnectionsCount;
          _connState = map['connectionState'] as String? ?? _connState;
          final hr = map['lastHrBpm'] as int?;
          if (hr != null && hr > 0) {
            _lastHr = hr;
            _lastHrTimestamp = DateTime.now();
          }
        });
      });

      _alwaysOnSub = transport.onAlwaysOnUpdate.listen((map) {
        if (!mounted) return;
        final hr = map['lastHr'] as int?;
        final samples = map['totalSamples'] as int? ?? _samplesCount;
        final rrs = map['totalRr'] as int? ?? _rrCount;
        final disc = map['disconnectionsCount'] as int? ?? _disconnectionsCount;
        setState(() {
          if (hr != null && hr > 0) {
            _lastHr = hr;
            _lastHrTimestamp = DateTime.now();
          }
          if (_isRecording) {
            _samplesCount = samples;
            _rrCount = rrs;
            _disconnectionsCount = disc;
          }
        });
      });
    }

    // Ascolto battiti standard 0x2A37
    _standardHrSub = transport.standardHrStream.listen((bytes) {
      if (!_isRecording || !mounted) return;
      try {
        final rec = StandardHrRecord.decode(bytes);
        final now = DateTime.now();
        setState(() {
          _lastHr = rec.hr;
          _lastHrTimestamp = now;
          if (transport is! MethodChannelPuffinTransport) {
            _samplesCount++;
            _rrCount = _rrCount + rec.rrIntervalsMs.length;
          }
        });

        // Se non su MethodChannel (es. test o desktop), salva direttamente nel repository
        if (transport is! MethodChannelPuffinTransport && _sessionId != null) {
          widget.repository.saveNightSample(
            sessionId: _sessionId!,
            timestamp: now,
            monotonicMillis: DateTime.now().millisecondsSinceEpoch,
            hrBpm: rec.hr,
            flags: bytes.isNotEmpty ? bytes[0] : 0,
            sensorContact: 1,
            rrStatus: rec.rrIntervalsMs.isNotEmpty ? 'AVAILABLE' : 'RR_UNAVAILABLE',
            rawRrIntervals: rec.rrIntervalsMs,
          );
        }
      } catch (_) {}
    });

    widget.syncService.liveHrNotifier.addListener(_onLiveHrChanged);
    widget.syncService.connectionStateNotifier.addListener(_onConnChanged);
  }

  void _onConnChanged() {
    if (mounted) setState(() {});
  }

  void _onLiveHrChanged() {
    final hr = widget.syncService.liveHrNotifier.value;
    if (hr != null && hr > 0 && mounted) {
      setState(() {
        _lastHr = hr;
        _lastHrTimestamp = DateTime.now();
      });
    }
  }

  Future<void> _handleStartRecording() async {
    final connState = widget.syncService.connectionStateNotifier.value;
    if (!connState.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('WHOOP non connesso. Connetti il dispositivo dalla Dashboard prima di avviare.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final now = DateTime.now();
    final sessId = 'night_${now.toUtc().millisecondsSinceEpoch}';
    final dev = connState is BleStatusConnected
        ? connState.device
        : (connState is BleStatusStandardHrConnected ? connState.device : null);
    final devAddress = dev?.macAddress ?? 'FD:49:44:66:1D:92';
    final devName = dev?.name ?? 'WHOOP 5.0';

    final transport = widget.syncService.transport;
    if (transport is MethodChannelPuffinTransport) {
      final ok = await transport.startNightRecording(sessId);
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Errore durante l\'avvio del Foreground Service')),
          );
        }
        return;
      }
    } else {
      await widget.repository.startNightSession(
        sessionId: sessId,
        deviceAddress: devAddress,
        deviceName: devName,
        startTime: now,
      );
    }

    setState(() {
      _isRecording = true;
      _sessionId = sessId;
      _sessionStartTime = now;
      _samplesCount = 0;
      _rrCount = 0;
      _disconnectionsCount = 0;
      _connState = 'RECORDING';
      _latestSummary = null;
    });
  }

  Future<void> _handleStopAndAnalyze() async {
    if (_sessionId == null) return;

    setState(() {
      _isAnalyzing = true;
    });

    final sessId = _sessionId!;
    final transport = widget.syncService.transport;

    try {
      final alwaysOn = await widget.repository.isAlwaysOnEnabled();
      if (alwaysOn && mounted) {
        final shouldDisable = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Registrazione Always-On Attiva'),
            content: const Text(
              'La registrazione automatica Always-On è attualmente attiva in background.\n\n'
              'Vuoi generare il report mantenendo Always-On attivo (consigliato), '
              'oppure interrompere la sessione e disattivare anche Always-On?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Mantieni Always-On (Solo Report)'),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Disattiva Always-On'),
              ),
            ],
          ),
        );

        if (shouldDisable == null) {
          setState(() {
            _isAnalyzing = false;
          });
          return;
        }

        if (shouldDisable) {
          await widget.repository.setAlwaysOnEnabled(false);
          if (transport is MethodChannelPuffinTransport) {
            await transport.setAlwaysOnEnabled(false);
          }
        }
      }

      if (transport is MethodChannelPuffinTransport) {
        await transport.stopNightRecording();
      } else {
        await widget.repository.endNightSession(sessionId: sessId);
      }

      // Estrai il riepilogo dal database persistente
      final summary = await widget.repository.getNightSessionSummary(sessId);

      setState(() {
        _isRecording = false;
        _isAnalyzing = false;
        _latestSummary = summary;
      });

      if (mounted) {
        _showMorningReportDialog(summary);
      }
    } catch (e) {
      setState(() {
        _isAnalyzing = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore generazione report: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _handleExportNightData([String? sessionId]) async {
    try {
      final file = await widget.repository.exportNightDataToCsv(sessionId: sessionId);
      if (!mounted) return;
      final csvContent = await file.readAsString();
      if (!mounted) return;
      final lineCount = csvContent.trim().split('\n').length;
      final rowCount = math.max(0, lineCount - 1);

      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.tealAccent),
              SizedBox(width: 8),
              Text('Dati notturni esportati'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'File CSV generato con successo:',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white24),
                ),
                child: SelectableText(
                  file.path,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.greenAccent),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Righe acquisite: $rowCount\nColonne: timestamp, hr, rr_raw\n(Nessun identificativo Bluetooth incluso)',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: csvContent));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Contenuto CSV copiato negli appunti!')),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copia CSV negli appunti'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Chiudi'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Errore esportazione dati: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _showMorningReportDialog(NightSessionSummary summary) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.wb_sunny, color: Colors.amber),
              SizedBox(width: 8),
              Text('Rapporto del Mattino'),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSummaryHeader(summary),
                  const Divider(height: 24),
                  _buildMetricsGrid(summary),
                  const Divider(height: 24),
                  if (summary.hrTimeSeries.isNotEmpty) ...[
                    const Text('Grafico Frequenza Cardiaca Notturna:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 140,
                      child: CustomPaint(
                        painter: SimpleHrChartPainter(
                          samples: summary.hrTimeSeries,
                          minHr: summary.minHr ?? 40,
                          maxHr: summary.maxHr ?? 140,
                        ),
                      ),
                    ),
                    const Divider(height: 24),
                  ],
                  const Text('Metriche Non Disponibili (Trasparenza):', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
                  const SizedBox(height: 6),
                  ...summary.missingMetrics.entries.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2.0),
                    child: Text('• ${e.key}: MISSING (${e.value})', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  )),
                ],
              ),
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () => _handleExportNightData(summary.sessionId),
              icon: const Icon(Icons.file_download),
              label: const Text('Esporta dati notturni'),
            ),
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: summary.toMarkdownReport()));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Report Markdown copiato negli appunti!')),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copia Markdown'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Chiudi'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSummaryHeader(NightSessionSummary s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sessione: ${s.sessionId}', style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
        const SizedBox(height: 4),
        Text('Dispositivo: ${s.deviceName} (${s.deviceAddress})', style: const TextStyle(fontSize: 12, color: Colors.tealAccent)),
        const SizedBox(height: 4),
        Text('Inizio: ${s.startTimeLocal.hour.toString().padLeft(2, '0')}:${s.startTimeLocal.minute.toString().padLeft(2, '0')}:${s.startTimeLocal.second.toString().padLeft(2, '0')} | Fine: ${s.endTimeLocal != null ? "${s.endTimeLocal!.hour.toString().padLeft(2, '0')}:${s.endTimeLocal!.minute.toString().padLeft(2, '0')}:${s.endTimeLocal!.second.toString().padLeft(2, '0')}" : "In corso"}'),
        Text('Durata Totale: ${s.durationFormatted} | Copertura: ${s.coveragePercent.toStringAsFixed(1)}%'),
      ],
    );
  }

  Widget _buildMetricsGrid(NightSessionSummary s) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _buildStatTile('Campioni HR', '${s.totalSamples}'),
        _buildStatTile('FC Media', s.meanHr != null ? '${s.meanHr!.toStringAsFixed(1)} BPM' : 'N/D'),
        _buildStatTile('FC Mediana', s.medianHr != null ? '${s.medianHr!.toStringAsFixed(1)} BPM' : 'N/D'),
        _buildStatTile('Min / Max', s.minHr != null ? '${s.minHr} / ${s.maxHr} BPM' : 'N/D'),
        _buildStatTile('RHR Notturno', s.estimatedRhr != null ? '${s.estimatedRhr} BPM' : 'N/D', subtitle: 'Media mobile 5m'),
        _buildStatTile(
          'HRV RMSSD',
          s.segmentedRmssdMs != null
              ? '${s.segmentedRmssdMs!.toStringAsFixed(1)} ms'
              : (s.rmssdMs != null ? '${s.rmssdMs!.toStringAsFixed(1)} ms' : 'MISSING'),
          subtitle: s.segmentedRmssdMs != null
              ? '${s.segmentsCount} segm (leg. ${s.rmssdMs?.toStringAsFixed(1)})'
              : '${s.totalRr} RR grezzi',
        ),
        _buildStatTile('Disconnessioni', '${s.disconnectionsCount} (${s.disconnectionDurationSeconds}s offline)'),
      ],
    );
  }

  Widget _buildStatTile(String label, String value, {String? subtitle}) {
    return Container(
      width: 140,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle, style: const TextStyle(fontSize: 10, color: Colors.tealAccent)),
          ],
        ],
      ),
    );
  }

  String _formatElapsed() {
    if (_sessionStartTime == null) return '00:00:00';
    final elapsed = DateTime.now().difference(_sessionStartTime!);
    final h = elapsed.inHours;
    final m = elapsed.inMinutes % 60;
    final s = elapsed.inSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatTimeSinceLastData() {
    if (_lastHrTimestamp == null) return 'In attesa primo dato...';
    final diff = DateTime.now().difference(_lastHrTimestamp!).inSeconds;
    return '$diff s fa (${diff < 5 ? "ATTIVO" : "RITARDO"})';
  }

  @override
  Widget build(BuildContext context) {
    final connState = widget.syncService.connectionStateNotifier.value;
    final isBleConnected = connState.isConnected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Night Recorder'),
        backgroundColor: Colors.indigo.shade900,
        actions: [
          IconButton(
            key: const Key('night_recorder_sleep_lab_button'),
            tooltip: 'Sleep Lab',
            icon: const Icon(Icons.science_outlined, color: Colors.purpleAccent),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => SleepLabScreen(
                    repository: widget.repository,
                    initialSessionId: _latestSummary?.sessionId ?? _sessionId,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // BANNER STATO
              Card(
                color: _isRecording ? const Color(0xFF002820) : Colors.grey.shade900,
                child: Padding(
                  padding: const EdgeInsets.all(14.0),
                  child: Row(
                    children: [
                      Icon(
                        _isRecording ? Icons.fiber_manual_record : Icons.nightlight_round,
                        color: _isRecording ? Colors.redAccent : Colors.tealAccent,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _isRecording
                                  ? 'STATO: RECORDING'
                                  : (isBleConnected ? 'PRONTO PER LA NOTTE' : 'DISPOSITIVO NON CONNESSO'),
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: _isRecording ? Colors.greenAccent : (isBleConnected ? Colors.white : Colors.orangeAccent),
                              ),
                            ),
                            Text(
                              _isRecording
                                  ? 'Sessione attiva in Foreground Service. Puoi spegnere lo schermo.'
                                  : 'Acquisizione biometrica continua 0x2A37 su SQLite.',
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // DASHBOARD DATI TEMPO REALE DURANTE RECORDING
              if (_isRecording) ...[
                Expanded(
                  child: ListView(
                    children: [
                      _buildMetricRow('Ultimo HR ricevuto:', '${_lastHr ?? "--"} BPM', icon: Icons.favorite, color: Colors.redAccent),
                      const SizedBox(height: 8),
                      _buildMetricRow('Tempo dall\'ultimo dato:', _formatTimeSinceLastData(), icon: Icons.timer, color: Colors.blueAccent),
                      const SizedBox(height: 8),
                      _buildMetricRow('Campioni HR acquisiti:', '$_samplesCount', icon: Icons.analytics, color: Colors.tealAccent),
                      const SizedBox(height: 8),
                      _buildMetricRow('Intervalli RR acquisiti:', _rrCount > 0 ? '$_rrCount' : 'RR_UNAVAILABLE', icon: Icons.timeline, color: Colors.amberAccent),
                      const SizedBox(height: 8),
                      _buildMetricRow('Durata sessione:', _formatElapsed(), icon: Icons.access_time, color: Colors.purpleAccent),
                      const SizedBox(height: 8),
                      _buildMetricRow('Numero di disconnessioni:', '$_disconnectionsCount', icon: Icons.link_off, color: _disconnectionsCount > 0 ? Colors.orangeAccent : Colors.greenAccent),
                      const SizedBox(height: 16),
                      // CONFERMA SALVATAGGIO
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.teal.withValues(alpha: 0.3)),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.check_circle_outline, color: Colors.tealAccent, size: 20),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Dati salvati progressivamente su SQLite (whoop_local.db - WAL Mode)',
                                style: TextStyle(fontSize: 12, color: Colors.tealAccent),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                // ISTRUZIONI PRE-NOTTE
                Expanded(
                  child: ListView(
                    children: [
                      const Text(
                        'Istruzioni per la Notte (9–10 Novembre 2026):',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 12),
                      _buildInstructionItem('1', 'Verifica che WHOOP B sia indossato al polso e connesso.'),
                      _buildInstructionItem('2', 'Tocca "AVVIA REGISTRAZIONE NOTTURNA" prima di coricarti.'),
                      _buildInstructionItem('3', 'Puoi bloccare e spegnere lo schermo del telefono: il Foreground Service continuerà a salvare campioni ogni secondo su SQLite.'),
                      _buildInstructionItem('4', 'Al risveglio, tocca "TERMINA E ANALIZZA" per consultare il Rapporto del Mattino.'),
                      const SizedBox(height: 20),
                      if (_latestSummary != null) ...[
                        ElevatedButton.icon(
                          onPressed: () => _showMorningReportDialog(_latestSummary!),
                          icon: const Icon(Icons.description),
                          label: const Text('Visualizza Ultimo Report Generato'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo),
                        ),
                        const SizedBox(height: 10),
                        ElevatedButton.icon(
                          key: const Key('open_sleep_lab_button'),
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => SleepLabScreen(
                                  repository: widget.repository,
                                  initialSessionId: _latestSummary?.sessionId ?? _sessionId,
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.science, color: Colors.purpleAccent),
                          label: const Text('Apri in Beveltry Sleep Lab'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF26133B),
                            foregroundColor: Colors.purpleAccent,
                            side: const BorderSide(color: Colors.purpleAccent),
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      OutlinedButton.icon(
                        onPressed: () => _handleExportNightData(_latestSummary?.sessionId ?? _sessionId),
                        icon: const Icon(Icons.file_download, color: Colors.tealAccent),
                        label: const Text('Esporta dati notturni'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.tealAccent,
                          side: const BorderSide(color: Colors.tealAccent),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 16),

              // PULSANTI AZIONE
              if (!_isRecording) ...[
                ElevatedButton.icon(
                  onPressed: isBleConnected ? _handleStartRecording : null,
                  icon: const Icon(Icons.play_arrow, size: 28),
                  label: const Text('AVVIA REGISTRAZIONE NOTTURNA', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                ),
              ] else ...[
                ElevatedButton.icon(
                  onPressed: _isAnalyzing ? null : _handleStopAndAnalyze,
                  icon: _isAnalyzing
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.stop, size: 28),
                  label: Text(
                    _isAnalyzing ? 'ANALISI IN CORSO...' : 'TERMINA E ANALIZZA',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetricRow(String label, String value, {required IconData icon, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13, color: Colors.grey))),
          Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  Widget _buildInstructionItem(String number, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: Colors.teal,
            child: Text(number, style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13, color: Colors.white70))),
        ],
      ),
    );
  }
}

/// Disegna un semplice grafico lineare della frequenza cardiaca notturna.
class SimpleHrChartPainter extends CustomPainter {
  SimpleHrChartPainter({
    required this.samples,
    required this.minHr,
    required this.maxHr,
  });

  final List<HrSamplePoint> samples;
  final int minHr;
  final int maxHr;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;

    final bgPaint = Paint()..color = Colors.black26;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    final linePaint = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final hrRange = (maxHr - minHr).clamp(10, 200).toDouble();
    final dx = size.width / math.max(1, samples.length - 1);

    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = i * dx;
      final normY = (samples[i].hrBpm - minHr) / hrRange;
      final y = size.height - (normY * size.height).clamp(0.0, size.height);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant SimpleHrChartPainter oldDelegate) => true;
}
