import 'package:flutter/material.dart';
import '../biometrics/dsp_engine.dart';
import 'theme.dart';

class StressTab extends StatelessWidget {
  final StressResult stress;
  final RecoveryResult recovery;

  const StressTab({
    super.key,
    required this.stress,
    required this.recovery,
  });

  Color _getStressColor(double score) {
    if (score < 1.0) return WhoopColors.green;
    if (score < 2.0) return WhoopColors.yellow;
    return WhoopColors.red;
  }

  @override
  Widget build(BuildContext context) {
    Color stressColor = _getStressColor(stress.stressScore);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Real-Time Stress Card
          _buildStressHeaderCard(stressColor),
          const SizedBox(height: 16),

          // Autonomic Balance Card (HRV & RHR)
          _buildAutonomicBalanceCard(),
          const SizedBox(height: 16),

          // Stress Distribution Breakdown
          _buildStressDistributionCard(),
          const SizedBox(height: 16),

          // Motion Decoupling Explanation
          _buildMotionDecouplingCard(),
        ],
      ),
    );
  }

  Widget _buildStressHeaderCard(Color stressColor) {
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
                'REAL-TIME STRESS MONITOR',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  letterSpacing: 1.0,
                  color: WhoopColors.textSecondary,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: stressColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  stress.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: stressColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                stress.stressScore.toStringAsFixed(2),
                style: TextStyle(
                  fontSize: 54,
                  fontWeight: FontWeight.w900,
                  color: stressColor,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                '/ 3.00',
                style: TextStyle(fontSize: 18, color: WhoopColors.textMuted, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'AUTONOMIC SYMPATHETIC TONE',
            style: TextStyle(fontSize: 10, letterSpacing: 0.8, color: WhoopColors.textMuted, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 18),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (stress.stressScore / 3.0).clamp(0.0, 1.0),
              backgroundColor: WhoopColors.surfaceHighlight,
              valueColor: AlwaysStoppedAnimation<Color>(stressColor),
              minHeight: 10,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text('0.0 LOW (CALM)', style: TextStyle(fontSize: 10, color: WhoopColors.green, fontWeight: FontWeight.bold)),
              Text('1.5 MEDIUM', style: TextStyle(fontSize: 10, color: WhoopColors.yellow, fontWeight: FontWeight.bold)),
              Text('3.0 HIGH (STRESS)', style: TextStyle(fontSize: 10, color: WhoopColors.red, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAutonomicBalanceCard() {
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
            'AUTONOMIC NERVOUS SYSTEM (ANS)',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.0, color: WhoopColors.textSecondary),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildAnsTile(
                  title: 'PARASYMPATHETIC (HRV)',
                  value: '${recovery.rmssd} ms',
                  subtitle: 'Rest & Digest (Vagal Tone)',
                  color: WhoopColors.green,
                  icon: Icons.shield,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildAnsTile(
                  title: 'SYMPATHETIC (RHR)',
                  value: '${recovery.rhr.toStringAsFixed(1)} BPM',
                  subtitle: 'Fight or Flight (Cardio Load)',
                  color: WhoopColors.stressPurple,
                  icon: Icons.bolt,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAnsTile({
    required String title,
    required String value,
    required String subtitle,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WhoopColors.surfaceHighlight,
        borderRadius: BorderRadius.circular(12),
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
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: color),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 10, color: WhoopColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildStressDistributionCard() {
    double lowPct = stress.stressScore < 1.0 ? 0.65 : (stress.stressScore < 2.0 ? 0.35 : 0.15);
    double medPct = stress.stressScore < 1.0 ? 0.25 : (stress.stressScore < 2.0 ? 0.50 : 0.35);
    double highPct = 1.0 - (lowPct + medPct);

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
            children: const [
              Text(
                'TEMPORAL STRESS DISTRIBUTION',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                  color: WhoopColors.textSecondary,
                ),
              ),
              Icon(Icons.pie_chart, size: 16, color: WhoopColors.textMuted),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Row(
              children: [
                Expanded(
                  flex: (lowPct * 100).toInt(),
                  child: Container(height: 10, color: WhoopColors.green),
                ),
                const SizedBox(width: 2),
                Expanded(
                  flex: (medPct * 100).toInt(),
                  child: Container(height: 10, color: WhoopColors.yellow),
                ),
                const SizedBox(width: 2),
                Expanded(
                  flex: (highPct * 100).toInt(),
                  child: Container(height: 10, color: WhoopColors.red),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildDistributionZoneTile('LOW (0.0-1.0)', '${(lowPct * 100).toInt()}%', WhoopColors.green, stress.stressScore < 1.0),
              _buildDistributionZoneTile('MED (1.0-2.0)', '${(medPct * 100).toInt()}%', WhoopColors.yellow, stress.stressScore >= 1.0 && stress.stressScore < 2.0),
              _buildDistributionZoneTile('HIGH (2.0-3.0)', '${(highPct * 100).toInt()}%', WhoopColors.red, stress.stressScore >= 2.0),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDistributionZoneTile(String label, String pct, Color color, bool isActive) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isActive ? color.withValues(alpha: 0.15) : WhoopColors.surfaceHighlight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isActive ? color : Colors.transparent),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isActive ? color : WhoopColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            pct,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: isActive ? Colors.white : WhoopColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMotionDecouplingCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: WhoopColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: WhoopColors.surfaceBorder),
      ),
      child: Row(
        children: [
          Icon(
            stress.motionDecoupled ? Icons.directions_run : Icons.self_improvement,
            color: stress.motionDecoupled ? WhoopColors.yellow : WhoopColors.green,
            size: 28,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'MOTION DECOUPLING: ',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: WhoopColors.textSecondary),
                    ),
                    Text(
                      stress.motionDecoupled ? 'ACTIVE' : 'IDLE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: stress.motionDecoupled ? WhoopColors.yellow : WhoopColors.green,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  stress.motionDecoupled
                      ? 'Physical movement detected (>0.15g). Heart rate surges are decoupled from mental stress.'
                      : 'Subject is stationary. Stress score accurately reflects autonomic nervous system state.',
                  style: const TextStyle(fontSize: 11, color: WhoopColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
