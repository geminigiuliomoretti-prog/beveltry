import 'package:flutter/material.dart';
import '../biometrics/dsp_engine.dart';
import '../database/whoop_database.dart';
import 'theme.dart';

class SleepTab extends StatefulWidget {
  final SleepResult sleep;
  final RecoveryResult recovery;
  final StrainResult strain;

  const SleepTab({
    super.key,
    required this.sleep,
    required this.recovery,
    required this.strain,
  });

  @override
  State<SleepTab> createState() => _SleepTabState();
}

class _SleepTabState extends State<SleepTab> {
  final TextEditingController _hrvController = TextEditingController();
  final TextEditingController _rhrController = TextEditingController();
  final TextEditingController _strainController = TextEditingController();
  final TextEditingController _recoveryController = TextEditingController();

  Map<String, dynamic>? _lastCalibration;

  @override
  void initState() {
    super.initState();
    _loadCalibrations();
  }

  @override
  void dispose() {
    _hrvController.dispose();
    _rhrController.dispose();
    _strainController.dispose();
    _recoveryController.dispose();
    super.dispose();
  }

  Future<void> _loadCalibrations() async {
    try {
      var latest = await WhoopDatabase.instance.getLatestCalibration();
      if (mounted) {
        setState(() {
          _lastCalibration = latest;
        });
      }
    } catch (e) {
      debugPrint('[CALIBRATION] Error loading: $e');
    }
  }

  void _saveCalibration() async {
    double? whoopAHrv = double.tryParse(_hrvController.text.trim());
    double? whoopARhr = double.tryParse(_rhrController.text.trim());
    double? whoopAStrain = double.tryParse(_strainController.text.trim());
    int? whoopARecovery = int.tryParse(_recoveryController.text.trim());

    if (whoopAHrv == null || whoopARhr == null || whoopAStrain == null || whoopARecovery == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter valid numeric values for all WHOOP A metrics'),
          backgroundColor: WhoopColors.red,
        ),
      );
      return;
    }

    await WhoopDatabase.instance.saveCalibration(
      whoopAHrv: whoopAHrv,
      whoopBHrv: widget.recovery.rmssd,
      whoopARhr: whoopARhr,
      whoopBRhr: widget.recovery.rhr,
      whoopAStrain: whoopAStrain,
      whoopBStrain: widget.strain.score,
      whoopARecovery: whoopARecovery,
      whoopBRecovery: widget.recovery.score,
      notes: 'Wrist comparison WHOOP A (Official) vs WHOOP B (Local)',
    );

    await _loadCalibrations();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Calibration comparison saved to SQLite!'),
          backgroundColor: WhoopColors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Big Sleep Performance Card
          _buildSleepPerformanceCard(),
          const SizedBox(height: 16),

          // Respiratory Rate & Skin Temperature
          _buildPhysioMetricsRow(),
          const SizedBox(height: 16),

          // Sleep Staging Breakdown Card
          _buildSleepStagesCard(),
          const SizedBox(height: 16),

          // Ground Truth Calibration Section (WHOOP A vs WHOOP B)
          _buildCalibrationSection(),
        ],
      ),
    );
  }

  Widget _buildSleepPerformanceCard() {
    double progress = (widget.sleep.sleepPerformance / 100.0).clamp(0.0, 1.0);

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
                'SLEEP PERFORMANCE',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  letterSpacing: 1.0,
                  color: WhoopColors.textSecondary,
                ),
              ),
              Icon(Icons.bedtime, color: WhoopColors.sleepTeal, size: 20),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${widget.sleep.sleepPerformance.toStringAsFixed(0)}%',
                style: const TextStyle(
                  fontSize: 54,
                  fontWeight: FontWeight.w900,
                  color: WhoopColors.sleepTeal,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '(${widget.sleep.totalSleepHours}h / 8.0h)',
                style: const TextStyle(fontSize: 14, color: WhoopColors.textMuted, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'SLEEP EFFICIENCY: ${(widget.sleep.sleepEfficiency * 100).toStringAsFixed(1)}%',
            style: const TextStyle(fontSize: 11, letterSpacing: 0.8, color: WhoopColors.textSecondary, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: WhoopColors.surfaceHighlight,
              valueColor: const AlwaysStoppedAnimation<Color>(WhoopColors.sleepTeal),
              minHeight: 10,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhysioMetricsRow() {
    return Row(
      children: [
        Expanded(
          child: _buildPhysioTile(
            title: 'RESPIRATORY RATE',
            value: widget.sleep.respiratoryRate.toStringAsFixed(1),
            unit: 'rpm (RSA)',
            subtitle: 'Autocorrelation 0.15-0.40 Hz',
            color: WhoopColors.sleepTeal,
            icon: Icons.air,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildPhysioTile(
            title: 'SKIN TEMPERATURE',
            value: '${widget.recovery.skinTempDelta >= 0 ? '+' : ''}${widget.recovery.skinTempDelta.toStringAsFixed(1)}°C',
            unit: 'vs base',
            subtitle: 'Nightly thermal baseline',
            color: WhoopColors.yellow,
            icon: Icons.thermostat,
          ),
        ),
      ],
    );
  }

  Widget _buildPhysioTile({
    required String title,
    required String value,
    required String unit,
    required String subtitle,
    required Color color,
    required IconData icon,
  }) {
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
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: WhoopColors.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
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
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: color),
              ),
              const SizedBox(width: 4),
              Text(unit, style: const TextStyle(fontSize: 10, color: WhoopColors.textMuted)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 9, color: WhoopColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildSleepStagesCard() {
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
            'SLEEP ARCHITECTURE & STAGES',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.0, color: WhoopColors.textSecondary),
          ),
          const SizedBox(height: 16),
          _buildStageRow('Deep (Slow Wave Sleep)', widget.sleep.deepPercent, const Color(0xFF1E88E5)),
          _buildStageRow('REM Sleep (Dreaming)', widget.sleep.remPercent, const Color(0xFF8E24AA)),
          _buildStageRow('Light Sleep', widget.sleep.lightPercent, const Color(0xFF00ACC1)),
          _buildStageRow('Awake / Disturbances', widget.sleep.awakePercent, const Color(0xFFFFB300)),
        ],
      ),
    );
  }

  Widget _buildStageRow(String name, double pct, Color color) {
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
                '${pct.toStringAsFixed(1)}%',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (pct / 100.0).clamp(0.0, 1.0),
              backgroundColor: WhoopColors.surfaceHighlight,
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalibrationSection() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: WhoopColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: WhoopColors.green.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: const [
                  Icon(Icons.compare_arrows, color: WhoopColors.green, size: 22),
                  SizedBox(width: 8),
                  Text(
                    'CALIBRAZIONE WHOOP A vs WHOOP B',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.8, color: WhoopColors.green),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: WhoopColors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('GROUND TRUTH', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: WhoopColors.green)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Inserisci i valori ufficiali letti sull\'app WHOOP A per confrontarli con il nostro WHOOP B e calcolare la precisione (\u0394%).',
            style: TextStyle(fontSize: 11, color: WhoopColors.textSecondary),
          ),
          const SizedBox(height: 16),

          // Inputs Grid
          Row(
            children: [
              Expanded(
                child: _buildCalibInput('WHOOP A HRV (ms)', _hrvController, 'es. 75'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildCalibInput('WHOOP A RHR (BPM)', _rhrController, 'es. 52'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildCalibInput('WHOOP A Strain (0-21)', _strainController, 'es. 8.5'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildCalibInput('WHOOP A Recovery %', _recoveryController, 'es. 62'),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Submit Calibration Button
          ElevatedButton.icon(
            onPressed: _saveCalibration,
            icon: const Icon(Icons.check_circle, color: Colors.black, size: 18),
            label: const Text(
              'CALCOLA SCARTO & SALVA CALIBRAZIONE',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.black),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: WhoopColors.green,
              minimumSize: const Size.fromHeight(42),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),

          // Latest Calibration Results Display
          if (_lastCalibration != null) ...[
            const SizedBox(height: 16),
            const Divider(color: WhoopColors.surfaceBorder, height: 1),
            const SizedBox(height: 12),
            const Text(
              'ULTIMO CONFRONTO AL POLSO (GROUND TRUTH):',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: WhoopColors.textPrimary),
            ),
            const SizedBox(height: 8),
            _buildDeltaRow('HRV (RMSSD)', _lastCalibration!['whoop_a_hrv'], _lastCalibration!['whoop_b_hrv'], _lastCalibration!['delta_hrv_pct'], 'ms'),
            _buildDeltaRow('Resting HR (RHR)', _lastCalibration!['whoop_a_rhr'], _lastCalibration!['whoop_b_rhr'], _lastCalibration!['delta_rhr_pct'], 'BPM'),
            _buildDeltaRow('Day Strain', _lastCalibration!['whoop_a_strain'], _lastCalibration!['whoop_b_strain'], _lastCalibration!['delta_strain_pct'], ''),
            _buildDeltaRow('Recovery Score', _lastCalibration!['whoop_a_recovery'], _lastCalibration!['whoop_b_recovery'], _lastCalibration!['delta_recovery_pct'], '%'),
          ],
        ],
      ),
    );
  }

  Widget _buildCalibInput(String label, TextEditingController ctrl, String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: WhoopColors.textMuted)),
        const SizedBox(height: 4),
        Container(
          height: 40,
          decoration: BoxDecoration(
            color: WhoopColors.surfaceHighlight,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: WhoopColors.surfaceBorder),
          ),
          child: TextField(
            controller: ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(fontSize: 13, color: WhoopColors.textPrimary, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(fontSize: 12, color: WhoopColors.textMuted),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: InputBorder.none,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDeltaRow(String label, dynamic valA, dynamic valB, dynamic deltaPct, String unit) {
    double d = (deltaPct as num?)?.toDouble() ?? 0.0;
    Color dColor = d.abs() <= 5.0 ? WhoopColors.green : (d.abs() <= 15.0 ? WhoopColors.yellow : WhoopColors.red);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: WhoopColors.textSecondary)),
          Row(
            children: [
              Text('A: $valA$unit vs B: $valB$unit', style: const TextStyle(fontSize: 11, color: WhoopColors.textMuted)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: dColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${d >= 0 ? "+" : ""}$d%',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: dColor),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
