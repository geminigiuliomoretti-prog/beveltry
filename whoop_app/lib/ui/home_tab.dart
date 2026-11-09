import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:universal_ble/universal_ble.dart';
import '../transport/ble_manager.dart';
import '../biometrics/dsp_engine.dart';
import 'theme.dart';

class HomeTab extends StatelessWidget {
  final RecoveryResult recovery;
  final StrainResult strain;
  final SleepResult sleep;
  final StressResult stress;
  final VoidCallback onSyncPressed;

  const HomeTab({
    super.key,
    required this.recovery,
    required this.strain,
    required this.sleep,
    required this.stress,
    required this.onSyncPressed,
  });

  Color _getRecoveryColor(RecoveryCategory cat) {
    switch (cat) {
      case RecoveryCategory.green:
        return WhoopColors.green;
      case RecoveryCategory.yellow:
        return WhoopColors.yellow;
      case RecoveryCategory.red:
        return WhoopColors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<WhoopBleManager>();
    final recoveryColor = _getRecoveryColor(recovery.category);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Device Status & Interactive Discovery Card
          _buildDeviceStatusCard(context, ble),
          const SizedBox(height: 16),

          // Recovery Circular Dial
          _buildRecoveryDialCard(recoveryColor),
          const SizedBox(height: 16),

          // Core Metric Tiles (Strain, Sleep, Stress)
          _buildCoreMetricsRow(),
          const SizedBox(height: 16),

          // Live WHOOP 5.0 Hardware State Card (BPM, RR, Baseline, Temp)
          _buildLiveTelemetryCard(ble),
          const SizedBox(height: 16),

          // Interactive Actions Card (Sync Flash & Vibrate Strap)
          _buildActionsCard(context, ble),
        ],
      ),
    );
  }

  Widget _buildDeviceStatusCard(BuildContext context, WhoopBleManager ble) {
    String stateText;
    Color stateColor;
    String badgeText;
    Color badgeColor;
    String subtitleText;

    switch (ble.connectionState) {
      case StrapConnectionState.connected:
        stateText = 'CONNECTED 24/7';
        stateColor = WhoopColors.green;
        badgeText = ble.isOnWrist ? 'ON-WRIST' : 'OFF-WRIST';
        badgeColor = ble.isOnWrist ? WhoopColors.green : WhoopColors.red;
        subtitleText = 'SN: ${ble.serialNumber} • FW: ${ble.firmwareVersion}';
        break;
      case StrapConnectionState.connecting:
        stateText = 'CONNECTING...';
        stateColor = WhoopColors.yellow;
        badgeText = 'PAIRING';
        badgeColor = WhoopColors.yellow;
        subtitleText = 'Unlocking session handshake...';
        break;
      case StrapConnectionState.scanning:
        stateText = 'SCANNING BLE...';
        stateColor = WhoopColors.strainBlue;
        badgeText = 'SEARCHING';
        badgeColor = WhoopColors.strainBlue;
        subtitleText = 'Scanning for WHOOP straps over BLE...';
        break;
      case StrapConnectionState.disconnected:
        stateText = 'DISCONNECTED';
        stateColor = WhoopColors.textMuted;
        badgeText = 'OFFLINE';
        badgeColor = WhoopColors.textMuted;
        subtitleText = 'No strap connected';
        break;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: WhoopColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: WhoopColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  ble.connectionState == StrapConnectionState.connected
                      ? Icons.watch
                      : (ble.connectionState == StrapConnectionState.disconnected
                          ? Icons.watch_off_outlined
                          : Icons.bluetooth_searching),
                  color: stateColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            ble.deviceName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: WhoopColors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: badgeColor.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            badgeText,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: badgeColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitleText,
                      style: const TextStyle(fontSize: 11, color: WhoopColors.textSecondary),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    stateText,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: stateColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(
                        ble.connectionState == StrapConnectionState.connected && ble.batteryLevel > 0
                            ? Icons.battery_charging_full
                            : Icons.battery_unknown,
                        size: 14,
                        color: ble.connectionState == StrapConnectionState.connected && ble.batteryLevel > 0
                            ? WhoopColors.green
                            : WhoopColors.textMuted,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        ble.connectionState == StrapConnectionState.connected && ble.batteryLevel > 0
                            ? '${ble.batteryLevel}%'
                            : '--%',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: ble.connectionState == StrapConnectionState.connected && ble.batteryLevel > 0
                              ? WhoopColors.textPrimary
                              : WhoopColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: WhoopColors.surfaceBorder, height: 1),
          const SizedBox(height: 10),

          // 1. DISCONNECTED: Prominent button to start scanning
          if (ble.connectionState == StrapConnectionState.disconnected)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => ble.startScan(),
                icon: const Icon(Icons.bluetooth_searching, size: 18, color: Colors.black),
                label: const Text(
                  'CONNECT STRAP',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                    fontSize: 13,
                    color: Colors.black,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: WhoopColors.green,
                  minimumSize: const Size.fromHeight(40),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            )

          // 2. SCANNING: Show real-time device discovery list with explicit CONNECT buttons
          else if (ble.connectionState == StrapConnectionState.scanning) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: const [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: WhoopColors.strainBlue),
                    ),
                    SizedBox(width: 8),
                    Text(
                      'AVAILABLE WHOOP STRAPS',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        color: WhoopColors.strainBlue,
                      ),
                    ),
                  ],
                ),
                TextButton(
                  onPressed: () => ble.stopScan(),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: WhoopColors.textMuted,
                  ),
                  child: const Text('CANCEL SCAN', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (ble.discoveredDevices.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: WhoopColors.surfaceHighlight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Searching for nearby WHOOP devices...\nMake sure your strap is awake and in pairing range.',
                  style: TextStyle(fontSize: 12, color: WhoopColors.textSecondary),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: ble.discoveredDevices.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, idx) {
                  final BleDevice device = ble.discoveredDevices[idx];
                  final String name = (device.name ?? '').isNotEmpty ? device.name! : 'Unknown Device';
                  final bool isWhoop = name.toUpperCase().contains('WHOOP');

                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: WhoopColors.surfaceHighlight,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isWhoop ? WhoopColors.green.withValues(alpha: 0.4) : WhoopColors.surfaceBorder,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.watch,
                          color: isWhoop ? WhoopColors.green : WhoopColors.textMuted,
                          size: 22,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                        color: WhoopColors.textPrimary,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (isWhoop) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: WhoopColors.green.withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                      child: const Text(
                                        'WHOOP',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.bold,
                                          color: WhoopColors.green,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${device.deviceId}${device.rssi != null ? " • RSSI: ${device.rssi} dBm" : ""}',
                                style: const TextStyle(fontSize: 11, color: WhoopColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton(
                          onPressed: () => ble.connectToDevice(device),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: WhoopColors.green,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            minimumSize: const Size(72, 32),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          ),
                          child: const Text('CONNECT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ]

          // 3. CONNECTING: Connecting to chosen strap
          else if (ble.connectionState == StrapConnectionState.connecting)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => ble.disconnect(),
                icon: const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: WhoopColors.yellow),
                ),
                label: Text(
                  'CONNECTING TO ${ble.deviceName}... (CANCEL)',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                    fontSize: 12,
                    color: WhoopColors.textPrimary,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: WhoopColors.surfaceBorder),
                  minimumSize: const Size.fromHeight(40),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            )

          // 4. CONNECTED: Connected options (Disconnect or Switch strap)
          else ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => ble.disconnect(),
                    icon: const Icon(Icons.bluetooth_disabled, size: 16, color: WhoopColors.red),
                    label: const Text(
                      'DISCONNECT',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        fontSize: 12,
                        color: WhoopColors.red,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: WhoopColors.red.withValues(alpha: 0.4)),
                      minimumSize: const Size.fromHeight(40),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await ble.disconnect();
                      await ble.startScan();
                    },
                    icon: const Icon(Icons.swap_horiz, size: 16, color: WhoopColors.strainBlue),
                    label: const Text(
                      'SWITCH STRAP',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        fontSize: 12,
                        color: WhoopColors.strainBlue,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: WhoopColors.strainBlue.withValues(alpha: 0.4)),
                      minimumSize: const Size.fromHeight(40),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRecoveryDialCard(Color recoveryColor) {
    final bool hasData = recovery.score > 0;
    final displayColor = hasData ? recoveryColor : WhoopColors.textMuted;
    final catName = hasData ? recovery.category.name.toUpperCase() : 'NO DATA';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: WhoopColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: WhoopColors.surfaceBorder),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'RECOVERY',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  letterSpacing: 1.2,
                  color: WhoopColors.textSecondary,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: displayColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  catName,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: displayColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 170,
                height: 170,
                child: CircularProgressIndicator(
                  value: hasData ? recovery.score / 100.0 : 0.0,
                  strokeWidth: 14,
                  backgroundColor: WhoopColors.surfaceHighlight,
                  valueColor: AlwaysStoppedAnimation<Color>(displayColor),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    hasData ? '${recovery.score}%' : '--',
                    style: TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w900,
                      color: displayColor,
                    ),
                  ),
                  Text(
                    hasData ? 'AUTONOMIC READINESS' : 'AWAITING DATA',
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      color: WhoopColors.textMuted,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildRecoverySubStat('HRV (RMSSD)', recovery.rmssd > 0 ? '${recovery.rmssd} ms' : '--'),
              _buildRecoverySubStat('RESTING HR', recovery.rhr > 0 ? '${recovery.rhr.toStringAsFixed(1)} BPM' : '--'),
              _buildRecoverySubStat('SKIN TEMP', recovery.skinTempDelta != 0.0 ? '${recovery.skinTempDelta >= 0 ? '+' : ''}${recovery.skinTempDelta}°C' : '--'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecoverySubStat(String title, String val) {
    return Column(
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 10, color: WhoopColors.textMuted, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 2),
        Text(
          val,
          style: const TextStyle(fontSize: 13, color: WhoopColors.textPrimary, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildCoreMetricsRow() {
    return Row(
      children: [
        Expanded(
          child: _buildMetricTile(
            title: 'DAY STRAIN',
            value: strain.score > 0 ? strain.score.toStringAsFixed(1) : '--',
            unit: '/ 21.0',
            color: WhoopColors.strainBlue,
            icon: Icons.flash_on,
            progress: (strain.score / 21.0).clamp(0.0, 1.0),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildMetricTile(
            title: 'SLEEP PERF',
            value: sleep.totalSleepHours > 0 ? '${sleep.sleepPerformance.toStringAsFixed(0)}%' : '--',
            unit: sleep.totalSleepHours > 0 ? '${sleep.totalSleepHours}h' : '',
            color: WhoopColors.sleepTeal,
            icon: Icons.nightlight_round,
            progress: (sleep.sleepPerformance / 100.0).clamp(0.0, 1.0),
          ),
        ),
      ],
    );
  }

  Widget _buildMetricTile({
    required String title,
    required String value,
    required String unit,
    required Color color,
    required IconData icon,
    required double progress,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WhoopColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: WhoopColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: WhoopColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: color),
              ),
              const SizedBox(width: 4),
              Text(
                unit,
                style: const TextStyle(fontSize: 11, color: WhoopColors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: WhoopColors.surfaceHighlight,
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveTelemetryCard(WhoopBleManager ble) {
    bool isConnected = ble.connectionState == StrapConnectionState.connected;
    String hrText = isConnected && ble.liveHr > 0 ? '${ble.liveHr}' : '--';
    String rrText = isConnected && ble.liveRrMs.isNotEmpty ? '${ble.liveRrMs.join(', ')} ms' : '--';
    String tempText = isConnected && ble.skinTempC > 0 ? '${ble.skinTempC.toStringAsFixed(1)}°C' : '--';
    String baselineText = isConnected && ble.opticalBaseline > 0
        ? 'Optical Baseline: ${ble.opticalBaseline} (${ble.opticalBaseline > 30000 ? "On-Wrist Valid" : "Off-Wrist"})'
        : 'Optical Baseline: --';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: WhoopColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: WhoopColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: WhoopColors.hrRed.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.favorite, color: WhoopColors.hrRed, size: 20),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'LIVE BIOMETRICS & SENSOR STATE',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.8, color: WhoopColors.textSecondary),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: WhoopColors.stressPurple.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'STRESS: ${stress.label}',
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: WhoopColors.stressPurple),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('LIVE HEART RATE', style: TextStyle(fontSize: 10, color: WhoopColors.textMuted, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        hrText,
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: WhoopColors.textPrimary),
                      ),
                      const SizedBox(width: 4),
                      const Text('BPM', style: TextStyle(fontSize: 11, color: WhoopColors.textMuted)),
                    ],
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('BEAT-TO-BEAT R-R', style: TextStyle(fontSize: 10, color: WhoopColors.textMuted, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    rrText,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: isConnected && ble.liveRrMs.isNotEmpty ? WhoopColors.green : WhoopColors.textMuted,
                    ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('SKIN TEMP', style: TextStyle(fontSize: 10, color: WhoopColors.textMuted, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(
                    tempText,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isConnected && ble.skinTempC > 0 ? WhoopColors.yellow : WhoopColors.textMuted,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: WhoopColors.surfaceBorder, height: 1),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                baselineText,
                style: const TextStyle(fontSize: 11, color: WhoopColors.textSecondary),
              ),
              Text(
                'Stress: ${stress.stressScore} / 3.0',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: WhoopColors.textPrimary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionsCard(BuildContext context, WhoopBleManager ble) {
    bool isConnected = ble.connectionState == StrapConnectionState.connected;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: WhoopColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: WhoopColors.surfaceBorder),
      ),
      child: Column(
        children: [
          if (ble.isSyncing) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'TURBO-SYNCING FLASH BACKLOG...',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: WhoopColors.strainBlue),
                ),
                Text(
                  '${(ble.syncProgress * 100).toInt()}%',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: WhoopColors.textPrimary),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: ble.syncProgress,
                backgroundColor: WhoopColors.surfaceHighlight,
                valueColor: const AlwaysStoppedAnimation<Color>(WhoopColors.strainBlue),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Saved: ${ble.syncUniqueSaved} unique | Speed: ${ble.syncSpeed} rec/s',
                  style: const TextStyle(fontSize: 11, color: WhoopColors.textSecondary),
                ),
                Text(
                  'Rcvd: ${ble.syncTotalPackets}',
                  style: const TextStyle(fontSize: 11, color: WhoopColors.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 14),
          ],
          Row(
            children: [
              Expanded(
                flex: 3,
                child: ElevatedButton.icon(
                  onPressed: ble.isSyncing
                      ? null
                      : () {
                          if (!isConnected) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Strap not connected. Tap CONNECT STRAP above to choose your device.'),
                                duration: Duration(seconds: 2),
                                backgroundColor: WhoopColors.red,
                              ),
                            );
                            return;
                          }
                          onSyncPressed();
                        },
                  icon: ble.isSyncing
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.sync, color: Colors.black, size: 20),
                  label: Text(
                    ble.isSyncing ? 'SYNCING...' : 'SYNC FLASH DATA',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      fontSize: 13,
                      color: Colors.black,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isConnected ? WhoopColors.green : WhoopColors.surfaceHighlight,
                    disabledBackgroundColor: WhoopColors.surfaceHighlight,
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    if (!isConnected) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Strap not connected'),
                          duration: Duration(seconds: 2),
                          backgroundColor: WhoopColors.red,
                        ),
                      );
                      return;
                    }
                    bool ok = await ble.sendAlarmVibration(pattern: 1, durationMs: 1200);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(ok ? 'Vibration signal sent to WHOOP (0x42)!' : 'Strap not connected'),
                          duration: const Duration(seconds: 2),
                          backgroundColor: ok ? WhoopColors.surfaceHighlight : WhoopColors.red,
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.vibration, color: WhoopColors.textPrimary, size: 18),
                  label: const Text(
                    'VIBRATE',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: WhoopColors.textPrimary,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: WhoopColors.surfaceBorder),
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
