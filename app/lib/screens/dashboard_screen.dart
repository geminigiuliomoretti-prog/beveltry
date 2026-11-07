import 'package:flutter/material.dart';

import 'package:beveltry/src/ble/ble.dart';
import 'package:beveltry/src/repository/whoop_repository.dart';
import 'package:beveltry/src/services/metrics_service.dart';
import 'package:beveltry/src/services/sync_service.dart';

/// Schermata principale della dashboard funzionale.
///
/// Espone il flusso BLE esplicito:
/// 1. "1. Cerca WHOOP" -> Scansione e visualizzazione ListView dispositivi (0xFD4B / WBB5AP*)
/// 2. Selezione dispositivo -> Connessione GATT e Bonding autenticato con popup nativo
/// 3. Pulsanti azione abilitati solo dopo lo stato `Connected`:
///    - "2. Sincronizza": handshake ed estrazione record storici
///    - "Test Vibrazione": comando 0x42
///    - "Disconnetti": chiusura sessione GATT
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    this.repository,
    this.syncService,
    this.metricsService,
  });

  final WhoopRepository? repository;
  final SyncService? syncService;
  final MetricsService? metricsService;

  @override
  State<DashboardScreen> createState() => DashboardScreenState();
}

class DashboardScreenState extends State<DashboardScreen> {
  late final WhoopRepository _repository;
  late final SyncService _syncService;
  late final MetricsService _metricsService;

  DailyMetrics? _latestMetrics;
  bool _isCalculating = false;
  bool _isVibrating = false;
  final List<String> _logs = [];
  final ScrollController _logScrollController = ScrollController();

  @visibleForTesting
  bool get isCalculating => _isCalculating;

  @visibleForTesting
  bool get isVibrating => _isVibrating;

  @visibleForTesting
  DailyMetrics? get latestMetrics => _latestMetrics;

  @visibleForTesting
  List<String> get logs => List.unmodifiable(_logs);

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? WhoopRepository();
    _syncService = widget.syncService ?? SyncService(repository: _repository);
    _metricsService =
        widget.metricsService ?? MetricsService(repository: _repository);

    _syncService.statusMessageNotifier.addListener(_onSyncStatusChanged);
    _syncService.connectionStateNotifier.addListener(_onConnectionStateChanged);
    _addLog('Sistema inizializzato. Pronto per la scansione.');
  }

  @override
  void dispose() {
    _syncService.statusMessageNotifier.removeListener(_onSyncStatusChanged);
    _syncService.connectionStateNotifier.removeListener(_onConnectionStateChanged);
    _logScrollController.dispose();
    if (widget.repository == null) {
      _repository.close();
    }
    super.dispose();
  }

  void _onSyncStatusChanged() {
    _addLog(_syncService.statusMessageNotifier.value);
  }

  void _onConnectionStateChanged() {
    final state = _syncService.connectionStateNotifier.value;
    switch (state) {
      case BleStatusIdle():
        break;
      case BleStatusScanning():
        _addLog('Stato BLE: Scansione in corso...');
      case BleStatusDiscovered(devices: final devs):
        _addLog('Stato BLE: Rilevati ${devs.length} dispositivi.');
      case BleStatusConnecting(device: final d):
        _addLog('Stato BLE: Connessione GATT a ${d?.macAddress ?? ""}...');
      case BleStatusBonding(device: final d):
        _addLog('Stato BLE: Bonding in corso con ${d?.name ?? ""} (attesa popup)...');
      case BleStatusConnected(device: final d):
        _addLog('Stato BLE: Connesso a ${d.name}. Pulsanti azione abilitati.');
      case BleStatusError(message: final msg):
        _addLog('Stato BLE: Errore - $msg');
    }
  }

  void _addLog(String message) {
    if (!mounted) return;
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    setState(() {
      _logs.add('[$timeStr] $message');
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _handleScan() async {
    _addLog('Avvio ricerca dispositivi WHOOP 5.0...');
    await _syncService.scanForDevices();
  }

  Future<void> _handleConnect(WhoopDiscoveredDevice device) async {
    _addLog('Avvio connessione e bonding a ${device.name} (${device.macAddress})...');
    final success = await _syncService.connectAndBond(device);
    if (!success) {
      _addLog('Bonding fallito o annullato.');
    }
  }

  Future<void> _handleDisconnect() async {
    _addLog('Disconnessione richiesta...');
    await _syncService.disconnect();
  }

  Future<void> _handleSync() async {
    if (_syncService.isSyncing) {
      _addLog('Attenzione: sincronizzazione già in corso.');
      return;
    }

    _addLog('Avvio sincronizzazione WHOOP (2. Sincronizza)...');
    final count = await _syncService.startSync();
    if (count == 0 && _syncService.statusNotifier.value == SyncStatus.error) {
      _addLog('Nessun dato scaricato.');
    }
  }

  Future<void> _handleCalculateMetrics() async {
    setState(() => _isCalculating = true);
    _addLog('Calcolo metriche fisiologiche in corso...');

    try {
      final metrics = await _metricsService.calculateMetricsForLastNight();
      setState(() {
        _latestMetrics = metrics;
      });

      if (metrics.recordCount == 0) {
        _addLog('Nessun dato scaricato: database vuoto per le ultime 24h.');
      } else {
        final rhrStr = metrics.rhr != null ? '${metrics.rhr} bpm' : 'Dati insufficienti';
        final hrvStr = (metrics.hrvRmssd == null ||
                metrics.hrvRmssd == 0.0 ||
                metrics.recordCount < 10)
            ? 'Dati insufficienti'
            : '${metrics.hrvRmssd} ms';
        _addLog(
          'Calcolo completato: ${metrics.recordCount} record analizzati. RHR: $rhrStr, HRV: $hrvStr.',
        );
      }
    } catch (e) {
      _addLog('Errore durante il calcolo: $e');
    } finally {
      if (mounted) {
        setState(() => _isCalculating = false);
      }
    }
  }

  Future<void> _handleTestVibration() async {
    setState(() => _isVibrating = true);
    _addLog('Invio comando vibrazione 0x42 (slot 1)...');

    try {
      final success = await _syncService.sendVibration(
        slot: 1,
        pattern: 1,
        durationMs: 1000,
      );
      if (success) {
        _addLog('Vibrazione attivata con successo sul cinturino (0x42).');
      } else {
        _addLog('Impossibile attivare la vibrazione: trasporto non connesso.');
      }
    } catch (e) {
      _addLog('Errore durante l\'invio della vibrazione: $e');
    } finally {
      if (mounted) {
        setState(() => _isVibrating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Beveltry'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Riquadri principali Metriche (RHR e HRV)
              Row(
                children: [
                  Expanded(
                    child: _buildMetricCard(
                      title: 'RHR',
                      subtitle: 'Frequenza a Riposo',
                      value: _latestMetrics?.rhr != null
                          ? '${_latestMetrics!.rhr} bpm'
                          : 'Dati insufficienti',
                      icon: Icons.favorite,
                      color: Colors.redAccent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildMetricCard(
                      title: 'HRV (RMSSD)',
                      subtitle: 'Variabilità Cardiaca',
                      value: (_latestMetrics == null ||
                              _latestMetrics!.hrvRmssd == null ||
                              _latestMetrics!.hrvRmssd == 0.0 ||
                              _latestMetrics!.recordCount < 10)
                          ? 'Dati insufficienti'
                          : '${_latestMetrics!.hrvRmssd} ms',
                      icon: Icons.timeline,
                      color: Colors.teal,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 2. Sezione Connessione BLE (Scan, Device List, Bonding)
              ValueListenableBuilder<BleConnectionStatus>(
                valueListenable: _syncService.connectionStateNotifier,
                builder: (context, connectionStatus, _) {
                  return _buildBleConnectionSection(connectionStatus);
                },
              ),
              const SizedBox(height: 12),

              // 3. Pulsanti di Azione (abilitati solo se Connected)
              ValueListenableBuilder<BleConnectionStatus>(
                valueListenable: _syncService.connectionStateNotifier,
                builder: (context, connectionStatus, _) {
                  final isConnected = connectionStatus.isConnected;

                  return ValueListenableBuilder<SyncStatus>(
                    valueListenable: _syncService.statusNotifier,
                    builder: (context, syncStatus, _) {
                      final isSyncing = _syncService.isSyncing;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  key: const Key('sync_button'),
                                  onPressed: isConnected && !isSyncing
                                      ? _handleSync
                                      : null,
                                  icon: isSyncing
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.sync),
                                  label: Text(
                                    isSyncing
                                        ? 'Sincronizzazione...'
                                        : '2. Sincronizza',
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: _isCalculating
                                      ? null
                                      : _handleCalculateMetrics,
                                  icon: _isCalculating
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.analytics_outlined),
                                  label: const Text('Calcola Metriche'),
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: ElevatedButton.icon(
                                  key: const Key('vibration_button'),
                                  onPressed: isConnected &&
                                          !isSyncing &&
                                          !_isCalculating &&
                                          !_isVibrating
                                      ? _handleTestVibration
                                      : null,
                                  icon: _isVibrating
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.vibration),
                                  label: Text(
                                    _isVibrating
                                        ? 'Vibrazione in corso...'
                                        : 'Test Vibrazione',
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                    backgroundColor: Theme.of(context)
                                        .colorScheme
                                        .secondaryContainer,
                                    foregroundColor: Theme.of(context)
                                        .colorScheme
                                        .onSecondaryContainer,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                flex: 1,
                                child: OutlinedButton.icon(
                                  key: const Key('disconnect_button'),
                                  onPressed: isConnected && !isSyncing
                                      ? _handleDisconnect
                                      : null,
                                  icon: const Icon(Icons.bluetooth_disabled),
                                  label: const Text('Disconnetti'),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
              const SizedBox(height: 16),

              // 4. Log delle Operazioni a schermo
              const Text(
                'Log Operazioni',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.grey.withValues(alpha: 0.3),
                    ),
                  ),
                  child: ListView.builder(
                    controller: _logScrollController,
                    padding: const EdgeInsets.all(8),
                    itemCount: _logs.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2.0),
                        child: Text(
                          _logs[index],
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBleConnectionSection(BleConnectionStatus status) {
    if (status is BleStatusConnected) {
      return Card(
        color: Colors.green.shade900.withValues(alpha: 0.3),
        shape: RoundedRectangleBorder(
          side: BorderSide(color: Colors.green.shade600),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
          child: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.greenAccent, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Connesso a ${status.device.name}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: Colors.greenAccent,
                      ),
                    ),
                    Text(
                      'MAC: ${status.device.macAddress} | Pronto per sincronizzazione e comandi',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade400,
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

    if (status.isConnectingOrBonding) {
      return Card(
        color: Colors.blueGrey.shade900.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(
          side: BorderSide(color: Colors.blueAccent.shade400),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Padding(
          padding: EdgeInsets.all(16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text(
                'Connessione e Bonding...',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                key: const Key('scan_button'),
                onPressed: status.isScanning ? null : _handleScan,
                icon: status.isScanning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bluetooth_searching),
                label: Text(
                  status.isScanning ? 'Ricerca in corso...' : '1. Cerca WHOOP',
                ),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ),
        if (status is BleStatusError) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.red.shade900.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.redAccent),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status.message,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (status is BleStatusDiscovered) ...[
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 160),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(8),
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
            ),
            child: status.devices.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Center(
                      child: Text(
                        'Nessun WHOOP 5.0 trovato. Tocca il cinturino 5-8 volte finché il LED è blu.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: status.devices.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final device = status.devices[index];
                      return Material(
                        color: Colors.transparent,
                        child: ListTile(
                          dense: true,
                          leading: const Icon(Icons.watch, color: Colors.tealAccent),
                          title: Text(
                            device.name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            '${device.macAddress}${device.rssi != null ? ' (${device.rssi} dBm)' : ''}',
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                          ),
                          trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                          onTap: () => _handleConnect(device),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ],
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String subtitle,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    final hasData = value != 'Dati insufficienti';
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: TextStyle(
                fontSize: hasData ? 22 : 14,
                fontWeight: hasData ? FontWeight.bold : FontWeight.w500,
                color: hasData ? color : Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
