// Path 1, slice 1: the Kotlin <-> Dart sensor stream contract.
//
// Pure Dart on purpose: the payload decode, the sequence bookkeeping, and the
// rate math are exercised by `flutter test` without a device. What is *not*
// testable here is the stream itself -- that is the device verification the
// user runs on the actual phone (see docs/path1-module.md).
//
// Wire format, mirrored from SensorChannel.kt:
//   Kotlin --batch--> Dart: { samples: Float64List [t_ms,x,y,z]*n,
//                             count: int, dropped: int, seq: int }
//   Kotlin --state--> Dart: { running: bool, error: String?,
//                             sensorName: String?, requestedHz: int? }

import 'dart:math' as math;
import 'dart:typed_data';

/// Method channel name; mirrors `SensorChannel.NAME` in Kotlin.
const String sensorChannelName = 'ph.appbuilders.bantay_app/sensors';

/// Dart -> Kotlin method names; mirror `SensorChannel.METHOD_*`.
const String sensorMethodStart = 'start';
const String sensorMethodStop = 'stop';
const String sensorMethodAttach = 'attach';
const String sensorMethodDetach = 'detach';

/// Kotlin -> Dart method names; mirror `SensorChannel.METHOD_*`.
const String sensorMethodBatch = 'batch';
const String sensorMethodState = 'state';

/// Standard gravity. SensorEvent.values for TYPE_ACCELEROMETER arrive in
/// m/s², but the cascade thresholds (SPEC §6: peak > 3.5 g) and the strip
/// baseline are in g. Without this conversion a resting phone reads ~9.8 and
/// every threshold downstream misfires. The conversion happens exactly once,
/// at this wire boundary, and every consumer sees g. Public so tests can
/// compute expected values without duplicating the constant.
const double ms2PerG = 9.80665;

/// One accelerometer sample. [tMs] is elapsedRealtime millis as a double,
/// monotonic and full precision: restamping through float32 here would have
/// blurred a 20 ms period at power-on uptime, so the channel sends a
/// DoubleArray (Float64List on this side) rather than a FloatArray.
class AccelSample {
  const AccelSample({
    required this.seq,
    required this.tMs,
    required this.x,
    required this.y,
    required this.z,
  });

  /// 1-based position in the whole stream, assigned by the ring buffer.
  final int seq;

  /// Milliseconds on the monotonic clock.
  final double tMs;

  /// Accelerometer components in g, converted from the m/s² wire values.
  final double x;
  final double y;
  final double z;

  double get magnitude => math.sqrt(x * x + y * y + z * z);
}

/// A decoded batch. [seq] is the stream sequence number now reached and
/// equals the last sample's [AccelSample.seq]; [dropped] counts samples the
/// consumer missed because the ring overwrote them (stall or cold attach).
class AccelBatch {
  const AccelBatch({
    required this.samples,
    required this.dropped,
    required this.seq,
  });

  final List<AccelSample> samples;
  final int dropped;
  final int seq;

  AccelSample get last => samples.last;
}

/// Decodes the `batch` map from Kotlin. Returns null on any shape violation:
/// a malformed batch must never be half-applied into detector state, and
/// dropping one batch is cheaper than admitting phantom samples.
AccelBatch? parseAccelBatch(Object? raw) {
  if (raw is! Map) return null;
  final Object? rawSamples = raw['samples'];
  final Object? count = raw['count'];
  final Object? dropped = raw['dropped'];
  final Object? seq = raw['seq'];
  if (rawSamples is! Float64List) return null;
  if (count is! int || dropped is! int || seq is! int) return null;
  if (count < 0 || dropped < 0) return null;
  // Promoted to a concrete local: closures never see the outer promotion.
  final Float64List samples = rawSamples;
  if (samples.lengthInBytes < count * 4 * 8) return null;

  final List<AccelSample> parsed = List<AccelSample>.generate(count, (i) {
    final int base = i * 4;
    final int sampleSeq = seq - count + i + 1;
    return AccelSample(
      seq: sampleSeq,
      tMs: samples[base],
      x: samples[base + 1] / ms2PerG,
      y: samples[base + 2] / ms2PerG,
      z: samples[base + 3] / ms2PerG,
    );
  });

  for (final sample in parsed) {
    if (!sample.tMs.isFinite ||
        !sample.x.isFinite ||
        !sample.y.isFinite ||
        !sample.z.isFinite) {
      return null;
    }
  }
  return AccelBatch(samples: parsed, dropped: dropped, seq: seq);
}

/// Session stream status reported by the service; mirrors `pushState`.
class SensorStatus {
  const SensorStatus({
    required this.running,
    this.error,
    this.sensorName,
    this.requestedHz,
  });

  final bool running;
  final String? error;
  final String? sensorName;
  final int? requestedHz;

  static SensorStatus? parse(Object? raw) {
    if (raw is! Map) return null;
    final Object? running = raw['running'];
    if (running is! bool) return null;
    return SensorStatus(
      running: running,
      error: raw['error'] as String?,
      sensorName: raw['sensorName'] as String?,
      requestedHz: raw['requestedHz'] as int?,
    );
  }
}

/// Rolling rate in Hz over a window of timestamps. Works on any clock that
/// increases: sample timestamps for the sample rate, arrival times for the
/// batch rate. Entries older than [windowMs] fall out, so the reported number
/// is what is happening now, not the session average.
class RateTracker {
  RateTracker({this.windowMs = 2000});

  final int windowMs;
  final List<double> _times = <double>[];

  double get hz {
    if (_times.length < 2) return 0;
    return (_times.length - 1) * 1000 / (_times.last - _times.first);
  }

  int get sampleCount => _times.length;

  void record(double tMs) {
    if (_times.isNotEmpty && tMs < _times.last) return; // clock went backwards
    _times.add(tMs);
    final double cutoff = tMs - windowMs;
    while (_times.isNotEmpty && _times.first < cutoff) {
      _times.removeAt(0);
    }
  }

  void reset() => _times.clear();
}
