import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../biometrics/dsp_engine.dart';
import '../transport/ble_manager.dart';
import '../database/whoop_database.dart';
import 'theme.dart';

class StrainTab extends StatefulWidget {
  final StrainResult strain;

  const StrainTab({super.key, required this.strain});

  @override
  State<StrainTab> createState() => _StrainTabState();
}

class _StrainTabState extends State<StrainTab> {
  String _selectedSport = 'Tennis';
  final List<String> _sports = ['Tennis', 'Athletic Prep', 'Running', 'Free Workout'];

  bool _isWorkoutActive = false;
  int _workoutElapsedSeconds = 0;
  Timer? _workoutTimer;
  final List<int> _workoutHrs = [];
  List<Map<String, dynamic>> _savedWorkouts = [];

  @override
  void initState() {
    super.initState();
    _loadSavedWorkouts();
  }

  @override
  void dispose() {
    _workoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSavedWorkouts() async {
    try {
      var workouts = await WhoopDatabase.instance.getWorkoutSessions(limit: 10);
      if (mounted) {
        setState(() {
          _savedWorkouts = workouts;
        });
      }
    } catch (e) {
      debugPrint('[WORKOUT] Error loading workouts: $e');
    }
  }

  void _startWorkout() {
    setState(() {
      _isWorkoutActive = true;
      _workoutElapsedSeconds = 0;
      _workoutHrs.clear();
    });

    _workoutTimer?.cancel();
    _workoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final ble = WhoopBleManager.instance;
      int currentHr = ble.liveHr > 0 ? ble.liveHr : 75;
      setState(() {
        _workoutElapsedSeconds++;
        _workoutHrs.add(currentHr);
      });
    });
  }

  void _stopAndSaveWorkout() async {
    _workoutTimer?.cancel();
    if (_workoutHrs.isEmpty) _workoutHrs.add(75);

    int nowTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    int startTs = nowTs - _workoutElapsedSeconds;
    int maxHr = _workoutHrs.reduce((a, b) => a > b ? a : b);
    int avgHr = (_workoutHrs.fold(0, (a, b) => a + b) / _workoutHrs.length).round();

    var workoutStrainRes = BiometricsDspEngine.computeStrain(_workoutHrs);
    double sessionStrain = workoutStrainRes.score;

    await WhoopDatabase.instance.saveWorkoutSession(
      startTimeUnix: startTs,
      endTimeUnix: nowTs,
      durationSeconds: _workoutElapsedSeconds,
      avgHr: avgHr,
      maxHr: maxHr,
      strain: sessionStrain,
      sportName: _selectedSport,
    );

    setState(() {
      _isWorkoutActive = false;
    });

    await _loadSavedWorkouts();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Workout saved! Strain: $sessionStrain, Avg HR: $avgHr BPM'),
          backgroundColor: WhoopColors.green,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  String _formatDuration(int seconds) {
    int m = seconds ~/ 60;
    int s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<WhoopBleManager>();

    // Compute live workout strain if active
    double liveWorkoutStrain = 0.0;
    if (_workoutHrs.isNotEmpty) {
      liveWorkoutStrain = BiometricsDspEngine.computeStrain(_workoutHrs).score;
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Big Strain Gauge Card
          _buildStrainHeaderCard(),
          const SizedBox(height: 16),

          // Live Workout Tracking Card
          _buildLiveWorkoutCard(ble, liveWorkoutStrain),
          const SizedBox(height: 16),

          // HR Stats (Max / Avg)
          _buildHrStatsRow(),
          const SizedBox(height: 16),

          // Heart Rate Zones Card
          _buildHrZonesCard(),
          const SizedBox(height: 16),

          // Recorded Workouts List
          _buildWorkoutsSection(),
        ],
      ),
    );
  }

  Widget _buildStrainHeaderCard() {
    double progress = (widget.strain.score / 21.0).clamp(0.0, 1.0);

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
            children: const [
              Text(
                'CARDIOVASCULAR DAY STRAIN',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  letterSpacing: 1.0,
                  color: WhoopColors.textSecondary,
                ),
              ),
              Icon(Icons.flash_on, color: WhoopColors.strainBlue, size: 20),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.strain.score.toStringAsFixed(1),
                style: const TextStyle(
                  fontSize: 54,
                  fontWeight: FontWeight.w900,
                  color: WhoopColors.strainBlue,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                '/ 21.0',
                style: TextStyle(fontSize: 18, color: WhoopColors.textMuted, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'WHOOP LOGARITHMIC ACCUMULATION SCALE',
            style: TextStyle(fontSize: 10, letterSpacing: 0.8, color: WhoopColors.textMuted, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: WhoopColors.surfaceHighlight,
              valueColor: const AlwaysStoppedAnimation<Color>(WhoopColors.strainBlue),
              minHeight: 10,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveWorkoutCard(WhoopBleManager ble, double liveWorkoutStrain) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: WhoopColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _isWorkoutActive ? WhoopColors.green : WhoopColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    _isWorkoutActive ? Icons.play_circle_fill : Icons.fitness_center,
                    color: _isWorkoutActive ? WhoopColors.green : WhoopColors.strainBlue,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'LIVE WORKOUT TRACKER',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.8, color: WhoopColors.textPrimary),
                  ),
                ],
              ),
              if (_isWorkoutActive)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: WhoopColors.green.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('RECORDING', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: WhoopColors.green)),
                ),
            ],
          ),
          const SizedBox(height: 14),

          // Sport Selector Dropdown
          Row(
            children: [
              const Text('Sport Activity: ', style: TextStyle(fontSize: 12, color: WhoopColors.textSecondary, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: WhoopColors.surfaceHighlight,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: WhoopColors.surfaceBorder),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedSport,
                      isExpanded: true,
                      dropdownColor: WhoopColors.surfaceHighlight,
                      style: const TextStyle(fontSize: 13, color: WhoopColors.textPrimary, fontWeight: FontWeight.bold),
                      items: _sports.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                      onChanged: _isWorkoutActive ? null : (val) {
                        if (val != null) setState(() => _selectedSport = val);
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Stopwatch & Real-Time HR Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Column(
                children: [
                  const Text('DURATION', style: TextStyle(fontSize: 10, color: WhoopColors.textMuted, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(
                    _formatDuration(_workoutElapsedSeconds),
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: WhoopColors.textPrimary),
                  ),
                ],
              ),
              Column(
                children: [
                  const Text('LIVE HR', style: TextStyle(fontSize: 10, color: WhoopColors.textMuted, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(
                    ble.liveHr > 0 ? '${ble.liveHr} BPM' : '--',
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: WhoopColors.hrRed),
                  ),
                ],
              ),
              Column(
                children: [
                  const Text('WORKOUT STRAIN', style: TextStyle(fontSize: 10, color: WhoopColors.textMuted, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(
                    liveWorkoutStrain.toStringAsFixed(1),
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: WhoopColors.strainBlue),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Start / Stop Workout Buttons
          Row(
            children: [
              if (!_isWorkoutActive)
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _startWorkout,
                    icon: const Icon(Icons.play_arrow, color: Colors.black),
                    label: const Text('START WORKOUT', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: WhoopColors.green,
                      minimumSize: const Size.fromHeight(44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                )
              else ...[
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _stopAndSaveWorkout,
                    icon: const Icon(Icons.stop, color: Colors.white),
                    label: const Text('STOP & SAVE SESSION', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: WhoopColors.red,
                      minimumSize: const Size.fromHeight(44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHrStatsRow() {
    return Row(
      children: [
        Expanded(
          child: _buildHrStatCard('MAX HEART RATE', '${widget.strain.maxHr}', 'BPM', WhoopColors.hrRed),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildHrStatCard('AVG HEART RATE', widget.strain.avgHr.toStringAsFixed(1), 'BPM', WhoopColors.textPrimary),
        ),
      ],
    );
  }

  Widget _buildHrStatCard(String title, String value, String unit, Color color) {
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
          Text(
            title,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: WhoopColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: color),
              ),
              const SizedBox(width: 4),
              Text(unit, style: const TextStyle(fontSize: 11, color: WhoopColors.textMuted)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHrZonesCard() {
    int totalSec = widget.strain.zoneSeconds.values.fold(0, (a, b) => a + b);
    if (totalSec == 0) totalSec = 1;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: WhoopColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: WhoopColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'HEART RATE ZONE DISTRIBUTION',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.0, color: WhoopColors.textSecondary),
          ),
          const SizedBox(height: 14),
          _buildZoneRow('Zone 5 (90-100% Anaerobic)', widget.strain.zoneSeconds['zone5'] ?? 0, totalSec, const Color(0xFFFF1744)),
          _buildZoneRow('Zone 4 (80-90% Threshold)', widget.strain.zoneSeconds['zone4'] ?? 0, totalSec, const Color(0xFFFF5252)),
          _buildZoneRow('Zone 3 (70-80% Endurance)', widget.strain.zoneSeconds['zone3'] ?? 0, totalSec, const Color(0xFFFF9100)),
          _buildZoneRow('Zone 2 (60-70% Base)', widget.strain.zoneSeconds['zone2'] ?? 0, totalSec, const Color(0xFF00E5FF)),
          _buildZoneRow('Zone 1 (50-60% Recovery)', widget.strain.zoneSeconds['zone1'] ?? 0, totalSec, const Color(0xFF00E676)),
        ],
      ),
    );
  }

  Widget _buildZoneRow(String name, int seconds, int totalSeconds, Color color) {
    double pct = (seconds / totalSeconds);
    double minutes = seconds / 60.0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                name,
                style: const TextStyle(fontSize: 12, color: WhoopColors.textPrimary, fontWeight: FontWeight.w600),
              ),
              Text(
                '${minutes.toStringAsFixed(1)} min (${(pct * 100).toStringAsFixed(0)}%)',
                style: const TextStyle(fontSize: 11, color: WhoopColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct.clamp(0.0, 1.0),
              backgroundColor: WhoopColors.surfaceHighlight,
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWorkoutsSection() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: WhoopColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: WhoopColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'RECORDED WORKOUT SESSIONS',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.0, color: WhoopColors.textSecondary),
              ),
              Text('${_savedWorkouts.length} SESSIONS', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: WhoopColors.green)),
            ],
          ),
          const SizedBox(height: 12),
          if (_savedWorkouts.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No workout sessions recorded yet. Start a live workout above!',
                  style: TextStyle(fontSize: 12, color: WhoopColors.textMuted),
                ),
              ),
            )
          else
            ..._savedWorkouts.map((w) {
              String sport = w['sport_name'] ?? 'Workout';
              int duration = w['duration_seconds'] ?? 0;
              double sStrain = (w['strain'] as num?)?.toDouble() ?? 0.0;
              int sAvgHr = w['avg_hr'] ?? 0;
              int sMaxHr = w['max_hr'] ?? 0;

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: WhoopColors.surfaceHighlight,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: WhoopColors.surfaceBorder),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(sport, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: WhoopColors.textPrimary)),
                        const SizedBox(height: 2),
                        Text('Duration: ${_formatDuration(duration)} • Avg: $sAvgHr BPM (Max: $sMaxHr)', style: const TextStyle(fontSize: 11, color: WhoopColors.textMuted)),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('STRAIN ${sStrain.toStringAsFixed(1)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: WhoopColors.strainBlue)),
                      ],
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}
