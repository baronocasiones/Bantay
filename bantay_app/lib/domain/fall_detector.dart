import 'dart:math' as math;

import 'package:bantay_app/sensor_payload.dart';
import 'package:bantay_llm/bantay_llm.dart';

/// A completed threshold-cascade event. Sensor time is monotonic milliseconds.
class ImpactEvent {
  const ImpactEvent({
    required this.impactTMs,
    required this.detectedTMs,
    required this.peakG,
    required this.beforeImpact,
    required this.stillnessSeconds,
  });

  final double impactTMs;
  final double detectedTMs;
  final double peakG;
  final BeforeImpact beforeImpact;
  final int stillnessSeconds;
}

/// The safety path. Each sample is already converted to g by the wire decoder.
class FallDetector {
  static const double impactThresholdG = 3.5;
  static const double rotationThresholdDegrees = 60;
  static const double rotationWindowMs = 500;
  static const double stillnessWindowMs = 2000;
  static const double stillnessToleranceG = 0.15;

  _Vec3? _gravity;
  _Candidate? _candidate;
  double _suppressedUntilMs = double.negativeInfinity;
  double _cooldownUntilMs = double.negativeInfinity;
  double? _lastTMs;
  final List<double> _recentMagnitudes = [];

  void suppressFor(Duration duration, {required double nowMs}) {
    _suppressedUntilMs = math.max(
      _suppressedUntilMs,
      nowMs + duration.inMicroseconds / 1000,
    );
    _candidate = null;
  }

  void reset() {
    _gravity = null;
    _candidate = null;
    _lastTMs = null;
    _cooldownUntilMs = double.negativeInfinity;
    _recentMagnitudes.clear();
  }

  ImpactEvent? addSample(AccelSample sample) {
    if (!sample.tMs.isFinite || !sample.magnitude.isFinite) return null;
    if (_lastTMs != null &&
        (sample.tMs <= _lastTMs! || sample.tMs - _lastTMs! > 500)) {
      reset();
    }
    _lastTMs = sample.tMs;
    final vector = _Vec3(sample.x, sample.y, sample.z);
    final magnitude = sample.magnitude;
    final priorGravity = _gravity;

    if (_candidate == null &&
        magnitude > impactThresholdG &&
        sample.tMs >= _suppressedUntilMs &&
        sample.tMs >= _cooldownUntilMs &&
        priorGravity != null &&
        priorGravity.norm > 0.5) {
      _candidate = _Candidate(
        impactTMs: sample.tMs,
        peakG: magnitude,
        priorGravity: priorGravity,
        beforeImpact: _classifyBeforeImpact(),
      );
      return null;
    }

    // The impact impulse must never pull the low-pass orientation toward itself.
    if (magnitude < 2.0) {
      _gravity = priorGravity == null ? vector : priorGravity.lerp(vector, 0.2);
    }

    final candidate = _candidate;
    if (candidate != null) {
      if (sample.tMs < _suppressedUntilMs) {
        _candidate = null;
        return null;
      }
      if (magnitude > candidate.peakG) candidate.peakG = magnitude;
      if (!candidate.rotated) {
        if (sample.tMs - candidate.impactTMs > rotationWindowMs) {
          _candidate = null;
          return null;
        }
        final gravity = _gravity;
        if (gravity != null &&
            candidate.priorGravity.angleDegrees(gravity) >
                rotationThresholdDegrees) {
          candidate.rotated = true;
          candidate.stillStartTMs = sample.tMs;
          candidate.stillReference = vector;
        }
      } else {
        final reference = candidate.stillReference!;
        if ((vector - reference).norm > stillnessToleranceG ||
            (magnitude - 1).abs() > stillnessToleranceG) {
          candidate.stillStartTMs = sample.tMs;
          candidate.stillReference = vector;
        }
        if (sample.tMs - candidate.stillStartTMs! >= stillnessWindowMs) {
          _candidate = null;
          _cooldownUntilMs = sample.tMs + 10000;
          return ImpactEvent(
            impactTMs: candidate.impactTMs,
            detectedTMs: sample.tMs,
            peakG: candidate.peakG,
            beforeImpact: candidate.beforeImpact,
            stillnessSeconds: ((sample.tMs - candidate.stillStartTMs!) / 1000)
                .floor(),
          );
        }
      }
    }

    if (_candidate == null) {
      _recentMagnitudes.add(magnitude);
      if (_recentMagnitudes.length > 100) _recentMagnitudes.removeAt(0);
    }
    return null;
  }

  BeforeImpact _classifyBeforeImpact() {
    if (_recentMagnitudes.length < 25) return BeforeImpact.unknown;
    final mean =
        _recentMagnitudes.reduce((a, b) => a + b) / _recentMagnitudes.length;
    final variance =
        _recentMagnitudes
            .map((v) => (v - mean) * (v - mean))
            .reduce((a, b) => a + b) /
        _recentMagnitudes.length;
    if (variance < 0.01) return BeforeImpact.still;
    if (variance > 0.25) return BeforeImpact.running;
    return BeforeImpact.walking;
  }
}

class _Candidate {
  _Candidate({
    required this.impactTMs,
    required this.peakG,
    required this.priorGravity,
    required this.beforeImpact,
  });

  final double impactTMs;
  double peakG;
  final _Vec3 priorGravity;
  final BeforeImpact beforeImpact;
  bool rotated = false;
  double? stillStartTMs;
  _Vec3? stillReference;
}

class _Vec3 {
  const _Vec3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  double get norm => math.sqrt(x * x + y * y + z * z);

  _Vec3 operator -(_Vec3 other) => _Vec3(x - other.x, y - other.y, z - other.z);

  _Vec3 lerp(_Vec3 other, double alpha) => _Vec3(
    x + (other.x - x) * alpha,
    y + (other.y - y) * alpha,
    z + (other.z - z) * alpha,
  );

  double angleDegrees(_Vec3 other) {
    final denominator = norm * other.norm;
    if (denominator < 0.01) return 0;
    final cosine = ((x * other.x + y * other.y + z * other.z) / denominator)
        .clamp(-1.0, 1.0);
    return math.acos(cosine) * 180 / math.pi;
  }
}
