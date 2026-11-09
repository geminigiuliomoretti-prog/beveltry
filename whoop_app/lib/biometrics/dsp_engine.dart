import 'dart:math';

enum RecoveryCategory {
  green,
  yellow,
  red,
}

class RecoveryResult {
  final int score; // 1 - 99%
  final RecoveryCategory category;
  final double rmssd;
  final double rhr;
  final double sleepEfficiency;
  final double skinTempDelta;

  RecoveryResult({
    required this.score,
    required this.category,
    required this.rmssd,
    required this.rhr,
    required this.sleepEfficiency,
    required this.skinTempDelta,
  });
}

class StrainResult {
  final double score; // 0.0 - 21.0
  final int maxHr;
  final double avgHr;
  final Map<String, int> zoneSeconds;

  StrainResult({
    required this.score,
    required this.maxHr,
    required this.avgHr,
    required this.zoneSeconds,
  });
}

class SleepResult {
  final double totalSleepHours;
  final double sleepPerformance; // 0.0 - 100.0%
  final double sleepEfficiency;
  final double deepPercent;
  final double remPercent;
  final double lightPercent;
  final double awakePercent;
  final double respiratoryRate; // breaths / min

  SleepResult({
    required this.totalSleepHours,
    required this.sleepPerformance,
    required this.sleepEfficiency,
    required this.deepPercent,
    required this.remPercent,
    required this.lightPercent,
    required this.awakePercent,
    required this.respiratoryRate,
  });
}

class StressResult {
  final double stressScore; // 0.0 - 3.0
  final String label; // LOW, MEDIUM, HIGH
  final bool motionDecoupled;

  StressResult({
    required this.stressScore,
    required this.label,
    required this.motionDecoupled,
  });
}

/// Pure Dart On-Device Biometric DSP Engine.
class BiometricsDspEngine {
  /// Computes RMSSD (Root Mean Square of Successive Differences) on physiologically valid RR intervals.
  /// Task Force of the European Society of Cardiology and NASPE (1996) standard.
  static double computeRmssd(List<int> validRrMs) {
    if (validRrMs.length < 2) return 0.0;

    double sumSqDiff = 0.0;
    int count = 0;
    for (int i = 0; i < validRrMs.length - 1; i++) {
      double diff = (validRrMs[i + 1] - validRrMs[i]).toDouble();
      sumSqDiff += diff * diff;
      count++;
    }

    if (count == 0) return 0.0;
    return sqrt(sumSqDiff / count);
  }

  /// Computes Resting Heart Rate (RHR) using sustained 5th-10th percentile during inactive or sleep periods.
  static double computeRhr(List<int> hrSamples) {
    List<int> valid = hrSamples.where((hr) => hr >= 35 && hr <= 220).toList();
    if (valid.isEmpty) return 60.0;

    valid.sort();
    int idxStart = (valid.length * 0.05).toInt();
    int idxEnd = max(idxStart + 1, (valid.length * 0.10).toInt());
    idxEnd = min(idxEnd, valid.length);

    var slice = valid.sublist(idxStart, idxEnd);
    double sum = slice.fold(0.0, (acc, v) => acc + v);
    return sum / slice.length;
  }

  /// Computes WHOOP Day Strain (0.0 to 21.0) using logarithmic cardiovascular accumulation across 5 HR zones.
  static StrainResult computeStrain(
    List<int> hrSamples, {
    int maxUserHr = 190,
    int restHr = 55,
  }) {
    List<int> valid = hrSamples.where((h) => h >= 40 && h <= 240).toList();
    if (valid.isEmpty) {
      return StrainResult(
        score: 0.0,
        maxHr: 0,
        avgHr: 0.0,
        zoneSeconds: {'zone1': 0, 'zone2': 0, 'zone3': 0, 'zone4': 0, 'zone5': 0},
      );
    }

    int maxObservedHr = valid.reduce(max);
    double avgHr = valid.fold(0.0, (sum, h) => sum + h) / valid.length;

    // Heart Rate Reserve (Karvonen) Zones
    int hrr = maxUserHr - restHr;
    double z1Threshold = restHr + 0.50 * hrr;
    double z2Threshold = restHr + 0.60 * hrr;
    double z3Threshold = restHr + 0.70 * hrr;
    double z4Threshold = restHr + 0.80 * hrr;
    double z5Threshold = restHr + 0.90 * hrr;

    int z1Sec = 0, z2Sec = 0, z3Sec = 0, z4Sec = 0, z5Sec = 0;
    for (int hr in valid) {
      if (hr >= z5Threshold) {
        z5Sec++;
      } else if (hr >= z4Threshold) {
        z4Sec++;
      } else if (hr >= z3Threshold) {
        z3Sec++;
      } else if (hr >= z2Threshold) {
        z2Sec++;
      } else if (hr >= z1Threshold) {
        z1Sec++;
      }
    }

    // Weighted cardiovascular load
    double weightedMinutes = (z1Sec * 1.0 + z2Sec * 2.0 + z3Sec * 4.0 + z4Sec * 8.0 + z5Sec * 16.0) / 60.0;

    // Logarithmic WHOOP strain formula: Strain = 21 * (1 - e^(-k * W))
    const double k = 0.015;
    double strain = 21.0 * (1.0 - exp(-k * weightedMinutes));
    strain = max(0.0, min(21.0, strain));

    return StrainResult(
      score: (strain * 10).round() / 10.0,
      maxHr: maxObservedHr,
      avgHr: (avgHr * 10).round() / 10.0,
      zoneSeconds: {
        'zone1': z1Sec,
        'zone2': z2Sec,
        'zone3': z3Sec,
        'zone4': z4Sec,
        'zone5': z5Sec,
      },
    );
  }

  /// Computes Autonomic Recovery Score (1 - 99%) and traffic light category.
  static RecoveryResult computeRecovery({
    required double rmssd,
    required double rhr,
    required double sleepEfficiency,
    double skinTempDelta = 0.0,
    double baselineRmssd = 65.0,
    double baselineRhr = 54.0,
  }) {
    // Autonomic Z-scores
    double zRmssd = baselineRmssd > 0 ? (rmssd - baselineRmssd) / (baselineRmssd * 0.25) : 0.0;
    double zRhr = baselineRhr > 0 ? -(rhr - baselineRhr) / (baselineRhr * 0.15) : 0.0;

    // Autonomic synthesis: 50% HRV, 30% RHR, 20% Sleep & Temp
    double composite = 50.0 + (zRmssd * 22.0) + (zRhr * 16.0) + ((sleepEfficiency - 0.70) * 20.0) - (skinTempDelta.abs() * 3.0);
    int score = max(1, min(99, composite.round()));

    RecoveryCategory category;
    if (score >= 67) {
      category = RecoveryCategory.green;
    } else if (score >= 34) {
      category = RecoveryCategory.yellow;
    } else {
      category = RecoveryCategory.red;
    }

    return RecoveryResult(
      score: score,
      category: category,
      rmssd: (rmssd * 10).round() / 10.0,
      rhr: (rhr * 10).round() / 10.0,
      sleepEfficiency: (sleepEfficiency * 100).round() / 100.0,
      skinTempDelta: (skinTempDelta * 100).round() / 100.0,
    );
  }

  /// Computes Sleep stages, performance, and RSA Respiratory Rate.
  static SleepResult computeSleep(
    List<Map<String, dynamic>> records,
    List<int> rrIntervals, {
    double targetSleepHours = 8.0,
  }) {
    if (records.isEmpty) {
      return SleepResult(
        totalSleepHours: 0.0,
        sleepPerformance: 0.0,
        sleepEfficiency: 0.0,
        deepPercent: 0.0,
        remPercent: 0.0,
        lightPercent: 0.0,
        awakePercent: 0.0,
        respiratoryRate: 14.0,
      );
    }

    int awakeSec = 0, lightSec = 0, deepSec = 0, remSec = 0;
    for (var r in records) {
      int state = (r['sleep_state'] as int?) ?? 0;
      double deltaG = ((r['movement_delta_g'] as num?) ?? 0.0).toDouble();

      if (state == 0 || deltaG > 0.15) {
        awakeSec++;
      } else if (state == 1) {
        lightSec++;
      } else if (state == 2) {
        deepSec++;
      } else if (state == 3) {
        remSec++;
      } else {
        // Fallback by movement
        if (deltaG < 0.03) {
          deepSec++;
        } else if (deltaG < 0.08) {
          lightSec++;
        } else {
          awakeSec++;
        }
      }
    }

    int totalSec = records.length;
    int sleepSec = lightSec + deepSec + remSec;
    double totalSleepHours = sleepSec / 3600.0;
    double sleepPerformance = min(100.0, (totalSleepHours / targetSleepHours) * 100.0);
    double sleepEfficiency = totalSec > 0 ? (sleepSec / totalSec) : 0.0;

    double deepPct = sleepSec > 0 ? (deepSec / sleepSec) * 100.0 : 0.0;
    double remPct = sleepSec > 0 ? (remSec / sleepSec) * 100.0 : 0.0;
    double lightPct = sleepSec > 0 ? (lightSec / sleepSec) * 100.0 : 0.0;
    double awakePct = totalSec > 0 ? (awakeSec / totalSec) * 100.0 : 0.0;

    // Respiratory Rate via RSA (Respiratory Sinus Arrhythmia) autocorrelation
    double respRate = _estimateRespiratoryRateRsa(rrIntervals);

    return SleepResult(
      totalSleepHours: (totalSleepHours * 100).round() / 100.0,
      sleepPerformance: (sleepPerformance * 10).round() / 10.0,
      sleepEfficiency: (sleepEfficiency * 100).round() / 100.0,
      deepPercent: (deepPct * 10).round() / 10.0,
      remPercent: (remPct * 10).round() / 10.0,
      lightPercent: (lightPct * 10).round() / 10.0,
      awakePercent: (awakePct * 10).round() / 10.0,
      respiratoryRate: (respRate * 10).round() / 10.0,
    );
  }

  /// Autocorrelation lag analysis in the RSA respiratory band (0.15 - 0.40 Hz = 9 - 24 breaths/min).
  static double _estimateRespiratoryRateRsa(List<int> rrIntervals) {
    if (rrIntervals.length < 30) return 14.5;

    // Detrend and normalize
    double mean = rrIntervals.fold(0.0, (acc, r) => acc + r) / rrIntervals.length;
    List<double> norm = rrIntervals.map((r) => r - mean).toList();

    // Lags corresponding to 9-24 breaths/min assuming ~1 beat/sec (lag 2.5s to 6.6s)
    int minLag = 2;
    int maxLag = min(10, norm.length ~/ 3);

    double maxCorr = -1.0;
    int bestLag = 4;

    for (int lag = minLag; lag <= maxLag; lag++) {
      double dot = 0.0;
      for (int i = 0; i < norm.length - lag; i++) {
        dot += norm[i] * norm[i + lag];
      }
      if (dot > maxCorr) {
        maxCorr = dot;
        bestLag = lag;
      }
    }

    // Convert lag (in beats) to breaths/min: assuming average HR ~ 60 BPM
    double breathsPerMin = (60.0 / bestLag);
    return max(10.0, min(22.0, breathsPerMin));
  }

  /// Computes Real-Time Autonomic Stress Monitor (0.0 to 3.0) with Motion Decoupling.
  static StressResult computeRealTimeStress({
    required int currentHr,
    required double currentRmssd,
    required double motionDeltaG,
    double restingHr = 55.0,
    double baselineRmssd = 65.0,
  }) {
    // If movement delta > 0.15g, HR increase is muscular/kinetic rather than psychological/sympathetic
    bool isDecoupled = motionDeltaG > 0.15;

    double hrFactor = max(0.0, (currentHr - restingHr) / 40.0);
    double hrvFactor = baselineRmssd > 0 ? max(0.0, (baselineRmssd - currentRmssd) / baselineRmssd) : 0.5;

    double rawStress = (hrFactor * 1.5) + (hrvFactor * 1.5);
    if (isDecoupled) {
      // Attenuate stress score when physical motion is detected
      rawStress *= 0.35;
    }

    double score = max(0.0, min(3.0, rawStress));
    score = (score * 100).round() / 100.0;

    String label;
    if (score < 1.0) {
      label = 'LOW';
    } else if (score < 2.0) {
      label = 'MEDIUM';
    } else {
      label = 'HIGH';
    }

    return StressResult(
      stressScore: score,
      label: label,
      motionDecoupled: isDecoupled,
    );
  }
}
