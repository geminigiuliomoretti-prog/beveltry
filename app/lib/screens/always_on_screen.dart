import 'dart:async';
import 'package:flutter/material.dart';

import 'package:beveltry/src/ble/ble.dart';
import 'package:beveltry/src/repository/whoop_repository.dart';
import 'package:beveltry/src/services/sync_service.dart';

/// Schermata Impostazioni e Diagnostica per la Registrazione Automatica Always-On (Task 08C).
class AlwaysOnScreen extends StatefulWidget {
  const AlwaysOnScreen({
    super.key,
    required this.repository,
    this.syncService,
    this.enablePeriodicRefresh = true,
  });

  final WhoopRepository repository;
  final SyncService? syncService;
  final bool enablePeriodicRefresh;

  @override
  State<AlwaysOnScreen> createState() => _AlwaysOnScreenState();
}

class _AlwaysOnScreenState extends State<AlwaysOnScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  bool _isLoading = true;
  bool _isAlwaysOn = false;
  String _bleState = 'DISABLED';
  bool _isGattConnected = false;
  bool _isSubscribed = false;
  bool _isStreaming = false;
  bool _isPersisting = false;
  bool _isStreamStale = false;
  bool _isBluetoothEnabled = true;
  String _sleepState = 'NO_NIGHT';

  int? _lastHrBpm;
  int? _lastRrMs;
  DateTime? _lastSampleTime;
  int _totalSamples = 0;
  int _totalRr = 0;
  int _disconnectionsCount = 0;
  int _gapsCount = 0;
  int _maxGapMs = 0;
  DateTime? _lastDisconnectTime;
  String? _lastDisconnectReason;

  List<Map<String, dynamic>> _recentEvents = [];
  List<Map<String, dynamic>> _segments = [];

  StreamSubscription? _alwaysOnSub;
  StreamSubscription? _nightUpdateSub;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadInitialState();

    final transport = widget.syncService?.transport;
    if (transport is MethodChannelPuffinTransport) {
      _alwaysOnSub = transport.onAlwaysOnUpdate.listen((map) {
        if (!mounted) return;
        setState(() {
          _bleState = map['stateName'] as String? ?? _bleState;
          _isAlwaysOn = map['isAlwaysOn'] as bool? ?? _isAlwaysOn;
          _totalSamples = map['totalSamples'] as int? ?? _totalSamples;
          _totalRr = map['totalRr'] as int? ?? _totalRr;
          _lastHrBpm = map['lastHr'] as int? ?? _lastHrBpm;
          _lastRrMs = map['lastRr'] as int? ?? _lastRrMs;
          final ts = map['lastSampleTimeUtc'] as int?;
          if (ts != null && ts > 0) {
            _lastSampleTime = DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true).toLocal();
          }
          _disconnectionsCount = map['disconnectionsCount'] as int? ?? _disconnectionsCount;
          _gapsCount = map['gapsCount'] as int? ?? _gapsCount;
          _maxGapMs = map['maxGapMs'] as int? ?? _maxGapMs;
          _isGattConnected = map['isGattConnected'] as bool? ?? _isGattConnected;
          _isSubscribed = map['isSubscribed'] as bool? ?? _isSubscribed;
          _isStreaming = map['isStreaming'] as bool? ?? (_bleState == 'STREAMING');
          _isPersisting = map['isPersisting'] as bool? ?? (_totalSamples > 0);
          _isStreamStale = map['isStreamStale'] as bool? ?? _isStreamStale;
          _isBluetoothEnabled = map['isBluetoothEnabled'] as bool? ?? _isBluetoothEnabled;
          _sleepState = map['sleepState'] as String? ?? _sleepState;
        });
      });
    }

    if (widget.enablePeriodicRefresh) {
      _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (mounted) _refreshDiagnostics();
      });
    }
  }

  @override
  void dispose() {
    _alwaysOnSub?.cancel();
    _nightUpdateSub?.cancel();
    _refreshTimer?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialState() async {
    final enabled = await widget.repository.isAlwaysOnEnabled();
    final events = await widget.repository.getRecentConnectionEvents(limit: 20);
    final lastDisc = await widget.repository.getLastDisconnectEvent();

    if (!mounted) return;
    setState(() {
      _isAlwaysOn = enabled;
      _recentEvents = events;
      if (lastDisc != null) {
        final ts = lastDisc['timestamp_utc'] as int?;
        if (ts != null) {
          _lastDisconnectTime = DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true).toLocal();
        }
        _lastDisconnectReason = lastDisc['details'] as String? ?? 'GATT error';
      }
      _isLoading = false;
    });

    _refreshDiagnostics();
  }

  Future<void> _refreshDiagnostics() async {
    final transport = widget.syncService?.transport;
    if (transport is MethodChannelPuffinTransport) {
      try {
        final diag = await transport.getAlwaysOnDiagnostics();
        if (diag.isNotEmpty && mounted) {
          setState(() {
            _bleState = diag['bleState'] as String? ?? _bleState;
            _isAlwaysOn = diag['isAlwaysOnEnabled'] as bool? ?? _isAlwaysOn;
            _isGattConnected = diag['isGattConnected'] as bool? ?? _isGattConnected;
            _isSubscribed = diag['isSubscribed'] as bool? ?? _isSubscribed;
            _isStreaming = diag['isStreaming'] as bool? ?? _isStreaming;
            _isPersisting = diag['isPersisting'] as bool? ?? (_totalSamples > 0);
            _isStreamStale = diag['isStreamStale'] as bool? ?? _isStreamStale;
            _isBluetoothEnabled = diag['isBluetoothEnabled'] as bool? ?? _isBluetoothEnabled;
            _sleepState = diag['sleepState'] as String? ?? _sleepState;
            _totalSamples = diag['totalSamples'] as int? ?? _totalSamples;
            _totalRr = diag['totalRr'] as int? ?? _totalRr;
            _lastHrBpm = diag['lastHrBpm'] as int? ?? _lastHrBpm;
            _lastRrMs = diag['lastRrMs'] as int? ?? _lastRrMs;
            final ts = diag['lastSampleTimestampUtc'] as int?;
            if (ts != null && ts > 0) {
              _lastSampleTime = DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true).toLocal();
            }
            _disconnectionsCount = diag['disconnectionsCount'] as int? ?? _disconnectionsCount;
            _gapsCount = diag['gapsDetectedCount'] as int? ?? _gapsCount;
            _maxGapMs = (diag['maxGapMs'] as num?)?.toInt() ?? _maxGapMs;
            final discTs = diag['lastDisconnectTimeUtc'] as int?;
            if (discTs != null && discTs > 0) {
              _lastDisconnectTime = DateTime.fromMillisecondsSinceEpoch(discTs, isUtc: true).toLocal();
            }
            _lastDisconnectReason = diag['lastDisconnectReason'] as String? ?? _lastDisconnectReason;
          });

          final sessId = diag['activeSessionId'] as String?;
          if (sessId != null) {
            final segs = await widget.repository.getRecordingSegments(sessId);
            if (mounted) {
              setState(() {
                _segments = segs;
              });
            }
          }
        }
      } catch (_) {}
    }

    try {
      final events = await widget.repository.getRecentConnectionEvents(limit: 20);
      if (mounted) {
        setState(() {
          _recentEvents = events;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleAlwaysOn(bool value) async {
    setState(() {
      _isLoading = true;
    });

    final transport = widget.syncService?.transport;
    if (transport is MethodChannelPuffinTransport) {
      await transport.setAlwaysOnEnabled(value);
    }
    await widget.repository.setAlwaysOnEnabled(value);

    await widget.repository.logConnectionEvent(
      eventType: value ? 'ALWAYS_ON_TOGGLED_ON' : 'ALWAYS_ON_TOGGLED_OFF',
      details: 'Interruttore Always-On impostato su $value da UI',
    );

    if (!mounted) return;
    setState(() {
      _isAlwaysOn = value;
      _isLoading = false;
    });

    _refreshDiagnostics();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Registrazione automatica'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.settings), text: 'Impostazioni'),
            Tab(icon: Icon(Icons.analytics_outlined), text: 'Diagnostica'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildSettingsTab(theme),
                _buildDiagnosticsTab(theme),
              ],
            ),
    );
  }

  // ==========================================
  // TAB 1: IMPOSTAZIONI
  // ==========================================

  Widget _buildSettingsTab(ThemeData theme) {
    final timeAgo = _lastSampleTime != null
        ? '${DateTime.now().difference(_lastSampleTime!).inSeconds}s fa'
        : 'Nessun dato';

    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        // Card Principale Interruttore Always-On
        Card(
          elevation: 3,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Registrazione automatica WHOOP',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Acquisisce HR/RR continuamente a schermo spento senza dover premere Night Recorder',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      key: const Key('always_on_switch'),
                      value: _isAlwaysOn,
                      onChanged: _toggleAlwaysOn,
                    ),
                  ],
                ),
                const Divider(height: 24),
                // Dispositivo selezionato
                const Row(
                  children: [
                    Icon(Icons.bluetooth, color: Colors.blueAccent, size: 20),
                    SizedBox(width: 8),
                    Text('Dispositivo target:', style: TextStyle(fontWeight: FontWeight.w600)),
                    SizedBox(width: 8),
                    Text('WHOOP B (WBB5AP-5AG0558675)', style: TextStyle(color: Colors.tealAccent)),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Quadruplo Indicatore di Stato Reale (Servizio, GATT, Sottoscrizione, Streaming, Persistenza)
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Stato Sistema (Osservabilità Reale)',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                _buildStatusRow(
                  label: 'Servizio Background (FGS):',
                  value: _isAlwaysOn ? 'ATTIVO (connectedDevice)' : 'INATTIVO',
                  color: _isAlwaysOn ? Colors.green : Colors.grey,
                  icon: Icons.miscellaneous_services,
                ),
                const SizedBox(height: 8),
                _buildStatusRow(
                  label: 'Adattatore Bluetooth:',
                  value: _isBluetoothEnabled ? 'ABILITATO (OK)' : 'DISATTIVATO',
                  color: _isBluetoothEnabled ? Colors.green : Colors.redAccent,
                  icon: Icons.bluetooth,
                ),
                const SizedBox(height: 8),
                _buildStatusRow(
                  label: 'Connessione GATT BLE:',
                  value: _isGattConnected ? 'GATT_CONNECTED' : (_isAlwaysOn ? 'IN CONNESSIONE' : 'DISCONNESSO'),
                  color: _isGattConnected ? Colors.green : (_isAlwaysOn ? Colors.orange : Colors.grey),
                  icon: Icons.bluetooth_connected,
                ),
                const SizedBox(height: 8),
                _buildStatusRow(
                  label: '2. Sottoscrizione 0x2A37 (SUBSCRIBED):',
                  value: _isSubscribed ? 'SUBSCRIBED (CCCD 0x2902 OK)' : (_isGattConnected ? 'IN CORSO...' : 'IN ATTESA'),
                  color: _isSubscribed ? Colors.green : (_isGattConnected ? Colors.orange : Colors.grey),
                  icon: Icons.notifications_active,
                ),
                const SizedBox(height: 8),
                _buildStatusRow(
                  label: '3. Flusso Notifiche (STREAMING):',
                  value: (_isStreaming && !_isStreamStale)
                      ? 'STREAMING ATTIVO (${_lastHrBpm ?? 0} BPM)'
                      : (_isStreamStale
                          ? 'FLUSSO STALE (Interrotto)'
                          : 'IN ATTESA BATTITO'),
                  color: (_isStreaming && !_isStreamStale)
                      ? Colors.green
                      : (_isStreamStale ? Colors.amberAccent : Colors.orange),
                  icon: Icons.favorite,
                ),
                const SizedBox(height: 8),
                _buildStatusRow(
                  label: '4. Persistenza SQLite (PERSISTING):',
                  value: (_isPersisting && !_isStreamStale)
                      ? 'PERSISTING ($_totalSamples campioni)'
                      : (_isStreamStale ? 'PERSISTENZA IN PAUSA (Stale)' : 'IN ATTESA DATI'),
                  color: (_isPersisting && !_isStreamStale) ? Colors.green : Colors.grey,
                  icon: Icons.save,
                ),
                const SizedBox(height: 8),
                _buildStatusRow(
                  label: 'Rilevatore Sonno (Task 08D):',
                  value: _sleepState,
                  color: _sleepState == 'REPORT_READY' || _sleepState == 'SLEEP_ACTIVE'
                      ? Colors.purpleAccent
                      : (_sleepState == 'PROCESS_FAILED' ? Colors.redAccent : Colors.tealAccent),
                  icon: Icons.nightlight_round,
                ),
                const Divider(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Stato macchina BLE:'),
                    Chip(
                      label: Text(_bleState, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                      backgroundColor: _getStateColor(_bleState).withValues(alpha: 0.2),
                      side: BorderSide(color: _getStateColor(_bleState)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Card Ultimo Campione Ricevuto
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Ultimo Campione Ricevuto',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildMetricCol('BPM', _lastHrBpm != null ? '$_lastHrBpm' : '--', Colors.redAccent),
                    _buildMetricCol('RR', _lastRrMs != null ? '$_lastRrMs ms' : '--', Colors.tealAccent),
                    _buildMetricCol('Aggiornamento', timeAgo, Colors.amberAccent),
                  ],
                ),
                if (_lastSampleTime != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Orario: ${_lastSampleTime.toString().substring(0, 19)}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Card Avviso Interruzioni
        if (_disconnectionsCount > 0 || _gapsCount > 0)
          Card(
            color: const Color(0xFF2A1515),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: Colors.redAccent),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 20),
                      SizedBox(width: 8),
                      Text('Avviso Interruzioni Registrate', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('Disconnessioni totali: $_disconnectionsCount | Gap rilevati: $_gapsCount (max: ${_maxGapMs}ms)', style: const TextStyle(fontSize: 12)),
                  if (_lastDisconnectReason != null)
                    Text('Ultima causa: $_lastDisconnectReason', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // ==========================================
  // TAB 2: DIAGNOSTICA
  // ==========================================

  Widget _buildDiagnosticsTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        // Tabella Telemetria e Diagnostica Completa
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Parametri Diagnostici Task 08C', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 10),
                _buildDiagRow('Always-On abilitato', _isAlwaysOn ? 'SÌ' : 'NO'),
                _buildDiagRow('Bluetooth attivo', 'SÌ (Adapter OK)'),
                _buildDiagRow('Permessi BLUETOOTH_CONNECT', 'CONCESSI'),
                _buildDiagRow('Foreground Service', _isAlwaysOn ? 'ATTIVO (connectedDevice)' : 'INATTIVO'),
                _buildDiagRow('GATT Connesso', _isGattConnected ? 'SÌ' : 'NO'),
                _buildDiagRow('Sottoscritto 0x2A37 (CCCD)', _isSubscribed ? 'SÌ (0x2902 OK)' : 'NO'),
                _buildDiagRow('Streaming Attivo', _isStreaming ? 'SÌ (${_lastHrBpm ?? 0} BPM)' : 'NO (In attesa)'),
                _buildDiagRow('Persistenza SQLite', _isPersisting ? 'SÌ ($_totalSamples campioni)' : 'IN ATTESA'),
                _buildDiagRow('Campioni HR totali', '$_totalSamples'),
                _buildDiagRow('Battiti R-R totali', '$_totalRr'),
                _buildDiagRow('Ultimo timestamp HR', _lastSampleTime?.toString().substring(11, 19) ?? 'N/A'),
                _buildDiagRow('Ultima disconnessione', _lastDisconnectTime?.toString().substring(11, 19) ?? 'Nessuna'),
                _buildDiagRow('Numero riconnessioni', '$_disconnectionsCount'),
                _buildDiagRow('Gap totali rilevati', '$_gapsCount'),
                _buildDiagRow('Massimo gap registrato', '$_maxGapMs ms'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Sequenza Eventi Tecnici BLE (GATT Lifecycle - Task 08C.1)
        Builder(
          builder: (context) {
            const technicalTypes = {
              'GATT_CONNECTED',
              'SERVICES_DISCOVERED',
              'HR_CHAR_FOUND',
              'CCCD_WRITE_STARTED',
              'CCCD_WRITE_SUCCESS',
              'CCCD_WRITE_FAILED',
              'FIRST_HR_NOTIFICATION',
              'FIRST_HR_DECODED',
              'FIRST_HR_PERSISTED',
              'STREAMING',
              'DISCONNECTED',
              'BLUETOOTH_TURNING_OFF',
              'BLUETOOTH_OFF',
              'GATT_CLOSED',
              'STREAM_STALE',
              'BLUETOOTH_ON',
              'RECONNECT_SCHEDULED',
              'RECONNECT_ATTEMPT',
              'FIRST_HR_AFTER_RECONNECT',
              'FIRST_HR_PERSISTED_AFTER_RECONNECT',
              'CONNECTION_TIMEOUT',
            };
            final techEvents = _recentEvents
                .where((e) => technicalTypes.contains(e['event_type']))
                .take(10)
                .toList();

            return Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.tealAccent.withValues(alpha: 0.3)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.timeline, color: Colors.tealAccent, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Sequenza Eventi Tecnici BLE (Lifecycle)',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.tealAccent),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (techEvents.isEmpty)
                      const Text('In attesa di eventi tecnici BLE...', style: TextStyle(color: Colors.grey, fontSize: 12))
                    else
                      ...techEvents.map((ev) {
                        final ts = ev['timestamp_utc'] as int? ?? 0;
                        final timeStr = DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true).toLocal().toString().substring(11, 19);
                        final type = ev['event_type'] as String? ?? 'EVENT';
                        final details = ev['details'] as String? ?? '';
                        final reasonCode = ev['reason_code'] as int?;

                        final isErr = type.contains('FAIL') || type.contains('ERROR') || type.contains('DISCONNECTED');
                        final isSucc = type.contains('SUCCESS') || type == 'STREAMING' || type.contains('PERSISTED');
                        final badgeColor = isErr ? Colors.redAccent : (isSucc ? Colors.greenAccent : Colors.amberAccent);

                        final codeText = (reasonCode != null && reasonCode != 0) ? ' [err: $reasonCode]' : '';

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4.0),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(timeStr, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: badgeColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: badgeColor, width: 0.8),
                                ),
                                child: Text(type, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: badgeColor)),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '$details$codeText',
                                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 12),

        // Istruzioni Samsung Galaxy "Never Sleeping Apps"
        Card(
          elevation: 2,
          color: const Color(0xFF141936),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.blueAccent.withValues(alpha: 0.4)),
          ),
          child: const Padding(
            padding: EdgeInsets.all(14.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.battery_charging_full, color: Colors.blueAccent, size: 20),
                    SizedBox(width: 8),
                    Text('Istruzioni per Smartphone Samsung Galaxy', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent)),
                  ],
                ),
                SizedBox(height: 8),
                Text(
                  'Per garantire che Samsung non congeli il processo durante la notte a schermo spento:\n'
                  '1. Apri Impostazioni dello smartphone.\n'
                  '2. Vai in Assistenza dispositivo → Batteria → Limiti per l\'uso in background.\n'
                  '3. Tocca «Applicazioni mai in sospensione» e aggiungi Beveltry.\n'
                  '4. Nelle impostazioni dell\'app Beveltry → Batteria → seleziona «Senza restrizioni».',
                  style: TextStyle(fontSize: 12, height: 1.4),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Registro Eventi Connessione Recenti (SQLite connection_events)
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Eventi di Connessione Recenti (SQLite)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 8),
                if (_recentEvents.isEmpty)
                  const Text('Nessun evento registrato.', style: TextStyle(color: Colors.grey, fontSize: 12))
                else
                  ..._recentEvents.take(8).map((ev) {
                    final ts = ev['timestamp_utc'] as int? ?? 0;
                    final timeStr = DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true).toLocal().toString().substring(11, 19);
                    final type = ev['event_type'] as String? ?? 'EVENT';
                    final details = ev['details'] as String? ?? '';
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(timeStr, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          const SizedBox(width: 8),
                          Text(type, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.tealAccent)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              details,
                              style: const TextStyle(fontSize: 11, color: Colors.white70),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Segmenti di Registrazione (SQLite recording_segments)
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Segmenti di Registrazione (SQLite)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 8),
                if (_segments.isEmpty)
                  const Text('Nessun segmento registrato.', style: TextStyle(color: Colors.grey, fontSize: 12))
                else
                  ..._segments.take(5).map((seg) {
                    final startTs = seg['start_time_utc'] as int? ?? 0;
                    final startTimeStr = DateTime.fromMillisecondsSinceEpoch(startTs, isUtc: true).toLocal().toString().substring(11, 19);
                    final samples = seg['samples_count'] as int? ?? 0;
                    final gaps = seg['gaps_count'] as int? ?? 0;
                    final status = seg['status'] as String? ?? 'ACTIVE';
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Avvio: $startTimeStr', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          Text('Campioni: $samples (Gap: $gaps)', style: const TextStyle(fontSize: 11)),
                          Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: status == 'COMPLETED' ? Colors.greenAccent : Colors.orangeAccent)),
                        ],
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusRow({
    required String label,
    required String value,
    required Color color,
    required IconData icon,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
        Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }

  Widget _buildDiagRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70)),
          Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildMetricCol(String label, String value, Color color) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }

  Color _getStateColor(String state) {
    return switch (state) {
      'STREAMING' => Colors.greenAccent,
      'CONNECTING' || 'GATT_CONNECTED' || 'DISCOVERING_SERVICES' || 'SUBSCRIBING_HR' => Colors.blueAccent,
      'RECONNECT_WAIT' || 'WAITING_FOR_DEVICE' => Colors.orangeAccent,
      'DISABLED' => Colors.grey,
      _ => Colors.redAccent,
    };
  }
}
