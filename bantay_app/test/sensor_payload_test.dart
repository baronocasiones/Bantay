import 'dart:typed_data';

import 'package:bantay_app/sensor_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('accel payload decode', () {
    /// Builds the map FallWatchService.emitBatch produces.
    Map<String, Object> batchPayload({
      required List<List<double>> quads,
      int dropped = 0,
      int? seq,
    }) {
      final Float64List samples = Float64List(quads.length * 4);
      for (int i = 0; i < quads.length; i++) {
        samples[i * 4] = quads[i][0];
        samples[i * 4 + 1] = quads[i][1];
        samples[i * 4 + 2] = quads[i][2];
        samples[i * 4 + 3] = quads[i][3];
      }
      return <String, Object>{
        'samples': samples,
        'count': quads.length,
        'dropped': dropped,
        'seq': seq ?? quads.length,
      };
    }

    test('decodes quads into samples with per-sample sequence', () {
      final AccelBatch? batch = parseAccelBatch(
        batchPayload(
          quads: const [
            [1000.5, 0.1, 0.2, 0.3],
            [1020.5, 0.4, 0.5, 0.6],
            [1040.5, 0.7, 0.8, 0.9],
          ],
        ),
      );
      expect(batch, isNotNull);
      expect(batch!.samples.length, 3);
      expect(batch.seq, 3);
      expect(batch.samples.first.seq, 1);
      expect(batch.samples.first.tMs, 1000.5);
      expect(batch.samples.last.seq, 3);
      // Wire values are m/s²; the decoded sample is in g.
      expect(batch.samples.last.z, closeTo(0.9 / ms2PerG, 1e-9));
      expect(batch.samples[1].magnitude, closeTo(0.877 / ms2PerG, 0.001));
    });

    test('converts wire m/s² to g', () {
      // 9.80665 m/s² is 1 g: a phone resting flat must not read 9.8.
      final AccelBatch? batch = parseAccelBatch(
        batchPayload(
          quads: const [
            [1000.0, 0, 0, ms2PerG],
          ],
        ),
      );
      expect(batch!.samples.single.z, closeTo(1.0, 1e-12));
      expect(batch.samples.single.magnitude, closeTo(1.0, 1e-12));
    });

    test('recomputes per-sample seq from the batch seq and count', () {
      // Consumer re-attaches mid-stream: the batch reports seq 500 for
      // 3 samples, so samples are 498, 499, 500.
      final AccelBatch? batch = parseAccelBatch(
        batchPayload(
          seq: 500,
          quads: const [
            [900.0, 0, 0, 1],
            [920.0, 0, 0, 1],
            [940.0, 0, 0, 1],
          ],
        ),
      );
      expect(batch!.samples.map((AccelSample s) => s.seq).toList(), [
        498,
        499,
        500,
      ]);
      expect(batch.seq, 500);
    });

    test('count shorter than the payload is honoured', () {
      final Float64List samples = Float64List.fromList(<double>[
        1,
        0,
        0,
        1,
        2,
        0,
        0,
        1,
        3,
        0,
        0,
        1,
        4,
        0,
        0,
        1,
      ]);
      final AccelBatch? batch = parseAccelBatch(<String, Object>{
        'samples': samples,
        'count': 2,
        'dropped': 0,
        'seq': 2,
      });
      expect(batch!.samples.length, 2);
      expect(batch.samples.last.tMs, 2);
    });

    test('rejects malformed shapes instead of half-applying', () {
      final Float64List good = Float64List.fromList(<double>[1, 0, 0, 1]);
      for (final Object? bad in <Object?>[
        null,
        'not a map',
        <String, Object>{},
        <String, Object>{'samples': good, 'count': 'x', 'dropped': 0, 'seq': 1},
        <String, Object>{'samples': good, 'count': 1, 'dropped': -1, 'seq': 1},
        // payload shorter than declared count
        <String, Object>{
          'samples': Float64List.fromList(<double>[1, 0, 0]),
          'count': 1,
          'dropped': 0,
          'seq': 1,
        },
        // NaN and infinity are rejected: they would poison magnitude math
        <String, Object>{
          'samples': Float64List.fromList(<double>[1, 0, 0, double.nan]),
          'count': 1,
          'dropped': 0,
          'seq': 1,
        },
        <String, Object>{
          'samples': Float64List.fromList(<double>[1, 0, 0, double.infinity]),
          'count': 1,
          'dropped': 0,
          'seq': 1,
        },
      ]) {
        expect(parseAccelBatch(bad), isNull, reason: 'payload: $bad');
      }
    });
  });

  group('status decode', () {
    test('reads the pushState map', () {
      final SensorStatus? parsed = SensorStatus.parse(<String, Object?>{
        'running': true,
        'error': null,
        'sensorName': 'LSM6DSO Accelerometer',
        'requestedHz': 50,
      });
      expect(parsed!.running, true);
      expect(parsed.error, isNull);
      expect(parsed.sensorName, 'LSM6DSO Accelerometer');
      expect(parsed.requestedHz, 50);
    });

    test('stops running with a reason', () {
      final SensorStatus? parsed = SensorStatus.parse(<String, Object?>{
        'running': false,
        'error': 'accelerometer unavailable',
      });
      expect(parsed!.running, false);
      expect(parsed.error, 'accelerometer unavailable');
    });

    test('rejects junk', () {
      expect(SensorStatus.parse(null), isNull);
      expect(SensorStatus.parse(<String, Object?>{'error': 'orphan'}), isNull);
    });
  });

  group('RateTracker', () {
    test('50 Hz timestamps measure 50 Hz', () {
      final RateTracker tracker = RateTracker();
      for (int i = 0; i < 100; i++) {
        tracker.record(i * 20.0); // 20 ms period
      }
      expect(tracker.hz, closeTo(50, 0.001));
    });

    test('window drops old entries: stall then resume reports live rate', () {
      final RateTracker tracker = RateTracker(windowMs: 2000);
      for (int i = 0; i < 50; i++) {
        tracker.record(i * 20.0);
      }
      // Stall 3 s: next record evicts everything older than last-2000 ms.
      for (int i = 0; i < 20; i++) {
        tracker.record(3000.0 + i * 50.0); // 20 Hz afterwards
      }
      expect(tracker.hz, closeTo(20, 0.001));
      expect(tracker.sampleCount, 20);
    });

    test('not enough samples measures zero, not NaN', () {
      final RateTracker tracker = RateTracker();
      expect(tracker.hz, 0);
      tracker.record(100);
      expect(tracker.hz, 0);
    });

    test('backwards clock motion is ignored', () {
      final RateTracker tracker = RateTracker();
      tracker.record(500);
      tracker.record(100);
      expect(tracker.sampleCount, 1);
    });

    test('reset clears history', () {
      final RateTracker tracker = RateTracker();
      tracker.record(100);
      tracker.record(120);
      tracker.reset();
      expect(tracker.hz, 0);
    });
  });

  test('channel method names match SensorChannel.kt', () {
    // Mirrored literally in Kotlin; a rename must happen on both sides or
    // the panel silently stops receiving batches.
    expect(sensorChannelName, 'ph.appbuilders.bantay_app/sensors');
    expect(sensorMethodStart, 'start');
    expect(sensorMethodStop, 'stop');
    expect(sensorMethodAttach, 'attach');
    expect(sensorMethodDetach, 'detach');
    expect(sensorMethodBatch, 'batch');
    expect(sensorMethodState, 'state');
  });
}
