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
    _addLog('Invio comando vibrazione immediata 0x13 (pattern: 2, loops: 3)...');

    try {
      final success = await _syncService.sendVibration(
        pattern: 2,
        loops: 3,
      );
      final statusByte = _syncService.lastVibrationStatusNotifier.value;
      final statusHex = statusByte != null
          ? '0x${statusByte.toRadixString(16).padLeft(2, '0').toUpperCase()}'
          : 'N/A';
      if (success) {
        _addLog(
          'Vibrazione attivata con successo sul cinturino (0x13)! Status ACK: $statusHex.',
        );
      } else {
        _addLog(
          'Vibrazione non riuscita o rifiutata dal cinturino (Status: $statusHex).',
        );
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
              const SizedBox(height: 12),

              // 4. Riquadro Telemetria Live & Record v18 in tempo reale
              _buildLiveTelemetrySection(),

              // 5. Log delle Operazioni a schermo
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
              const Icon(Icons.verified, color: Colors.greenAccent, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            'Connesso a ${status.device.name}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: Colors.greenAccent,
                            ),
                          ),
                        ),
                        if (status.isHardwareVerified) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green.shade800,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'VERIFICATO HARDWARE',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      'MAC: ${status.device.macAddress} | Sessione sbloccata (Handshake OK)',
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
            const SizedBox(width: 8),
            IconButton.outlined(
              key: const Key('bluetooth_guide_button'),
              tooltip: 'Guida associazione e risoluzione Bluetooth',
              icon: const Icon(Icons.help_outline),
              onPressed: () => _showBluetoothGuideDialog(context),
            ),
          ],
        ),
        if (status is BleStatusError) ...[
          const SizedBox(height: 8),
          _buildBluetoothErrorCard(context, status.message),
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

  Widget _buildBluetoothErrorCard(BuildContext context, String errorMessage) {
    return Card(
      key: const Key('bluetooth_troubleshooting_guide'),
      margin: EdgeInsets.zero,
      color: Colors.red.shade900.withValues(alpha: 0.25),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Colors.redAccent.withValues(alpha: 0.8)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    errorMessage,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 10, thickness: 0.5, color: Colors.redAccent),
            const Text(
              'Risoluzione problemi Bluetooth & Associazione:',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 11,
                color: Colors.amberAccent,
              ),
            ),
            const SizedBox(height: 4),
            _buildTroubleshootStep(
              icon: Icons.close,
              text: 'Chiudere l\'app ufficiale WHOOP.',
            ),
            const SizedBox(height: 2),
            _buildTroubleshootStep(
              icon: Icons.bluetooth_disabled,
              text: 'Dimenticare il WHOOP dalle impostazioni Bluetooth del telefono.',
            ),
            const SizedBox(height: 2),
            _buildTroubleshootStep(
              icon: Icons.restart_alt,
              text: 'Riavviare il Bluetooth o il telefono.',
            ),
            const SizedBox(height: 2),
            _buildTroubleshootStep(
              icon: Icons.touch_app,
              text: 'Rimettere il WHOOP in pairing mode (LED blu fisso).',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTroubleshootStep({required IconData icon, required String text}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: Colors.amber.shade300),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }

  void _showBluetoothGuideDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.bluetooth, color: Colors.tealAccent),
            SizedBox(width: 8),
            Text('Guida Bluetooth & Pairing', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Per evitare conflitti, errori GATT 133 o fallimento del bonding:',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            _buildTroubleshootStep(
              icon: Icons.close,
              text: 'Disaccoppiare il WHOOP dall\'app ufficiale (Impostazioni Dispositivo -> Avanzate -> Disaccoppia) e chiuderla.',
            ),
            const SizedBox(height: 6),
            _buildTroubleshootStep(
              icon: Icons.bluetooth_disabled,
              text: 'Dimenticare il WHOOP dalle impostazioni Bluetooth dello smartphone.',
            ),
            const SizedBox(height: 6),
            _buildTroubleshootStep(
              icon: Icons.pan_tool,
              text: 'Togliere il WHOOP dal polso (LED verdi spenti, afferrare solo dai bordi).',
            ),
            const SizedBox(height: 6),
            _buildTroubleshootStep(
              icon: Icons.touch_app,
              text: 'Picchiettare 5-8 volte sul dorso fino al LED blu lampeggiante/fisso.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
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
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
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

  Widget _buildLiveTelemetrySection() {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _syncService.recordsSavedNotifier,
        _syncService.lastTimestampNotifier,
        _syncService.lastHrNotifier,
        _syncService.lastSkinTempNotifier,
        _syncService.lastRrNotifier,
        _syncService.liveHrNotifier,
        _syncService.lastVibrationStatusNotifier,
      ]),
      builder: (context, _) {
        final recordsSaved = _syncService.recordsSavedNotifier.value;
        final liveHr = _syncService.liveHrNotifier.value;
        final lastHr = _syncService.lastHrNotifier.value;
        final lastTs = _syncService.lastTimestampNotifier.value;
        final temp = _syncService.lastSkinTempNotifier.value;
        final rr = _syncService.lastRrNotifier.value;
        final vibStatus = _syncService.lastVibrationStatusNotifier.value;

        if (recordsSaved == 0 && liveHr == null && vibStatus == null) {
          return const SizedBox.shrink();
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.blueGrey.shade900.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.teal.shade700),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Telemetria WHOOP Hardware',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Colors.tealAccent,
                    ),
                  ),
                  if (liveHr != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.red.shade900,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.redAccent),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.favorite, size: 12, color: Colors.white),
                          const SizedBox(width: 4),
                          Text(
                            '$liveHr BPM (Live 0x28)',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  Text(
                    'Pacchetti 0x2F v18: $recordsSaved',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  if (lastHr != null)
                    Text(
                      'BPM Storico: $lastHr',
                      style: const TextStyle(fontSize: 12),
                    ),
                  if (temp != null)
                    Text(
                      'Temp Pelle: ${temp.toStringAsFixed(1)}°C',
                      style: const TextStyle(fontSize: 12),
                    ),
                  if (rr != null && rr.isNotEmpty)
                    Text(
                      'RR: ${rr.join(", ")} ms',
                      style: const TextStyle(fontSize: 12),
                    ),
                  if (lastTs != null)
                    Text(
                      'Ultimo TS: ${lastTs.toLocal().toString().split(".")[0]}',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                    ),
                  if (vibStatus != null)
                    Text(
                      'Status Haptics: 0x${vibStatus.toRadixString(16).padLeft(2, '0').toUpperCase()}',
                      style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
