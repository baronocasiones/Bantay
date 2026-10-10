import 'package:bantay_app/domain/fall_detector.dart';
import 'package:bantay_app/sensor_payload.dart';
import 'package:flutter_test/flutter_test.dart';

class _Trace {
  int seq = 0;
  double tMs = 0;

  AccelSample sample(double x, double y, double z) {
    seq += 1;
    final current = tMs;
    tMs += 20;
    return AccelSample(seq: seq, tMs: current, x: x, y: y, z: z);
  }

  void feed(
    FallDetector detector,
    int count,
    double x,
    double y,
    double z, {
    void Function(ImpactEvent)? onImpact,
  }) {
    for (var i = 0; i < count; i++) {
      final event = detector.addSample(sample(x, y, z));
      if (event != null) onImpact?.call(event);
    }
  }
}

void main() {
  test('impact rotation then two seconds stillness emits one event', () {
    final detector = FallDetector();
    final trace = _Trace();
    final events = <ImpactEvent>[];

    trace.feed(detector, 50, 0, 0, 1, onImpact: events.add);
    trace.feed(detector, 1, 0, 0, 5, onImpact: events.add);
    trace.feed(detector, 160, 1, 0, 0, onImpact: events.add);

    expect(events, hasLength(1));
    expect(events.single.peakG, closeTo(5, 0.01));
    expect(events.single.stillnessSeconds, greaterThanOrEqualTo(2));
  });

  test('impact without orientation change is rejected', () {
    final detector = FallDetector();
    final trace = _Trace();
    final events = <ImpactEvent>[];

    trace.feed(detector, 50, 0, 0, 1, onImpact: events.add);
    trace.feed(detector, 1, 0, 0, 5, onImpact: events.add);
    trace.feed(detector, 160, 0, 0, 1, onImpact: events.add);

    expect(events, isEmpty);
  });

  test('continued movement after rotation is rejected', () {
    final detector = FallDetector();
    final trace = _Trace();
    final events = <ImpactEvent>[];

    trace.feed(detector, 50, 0, 0, 1, onImpact: events.add);
    trace.feed(detector, 1, 0, 0, 5, onImpact: events.add);
    for (var i = 0; i < 160; i++) {
      final x = i.isEven ? 1.45 : 0.55;
      final event = detector.addSample(trace.sample(x, 0, 0));
      if (event != null) events.add(event);
    }

    expect(events, isEmpty);
  });

  test('test window suppresses otherwise valid impact', () {
    final detector = FallDetector();
    final trace = _Trace();
    final events = <ImpactEvent>[];
    detector.suppressFor(const Duration(seconds: 8), nowMs: 0);

    trace.feed(detector, 50, 0, 0, 1, onImpact: events.add);
    trace.feed(detector, 1, 0, 0, 5, onImpact: events.add);
    trace.feed(detector, 160, 1, 0, 0, onImpact: events.add);

    expect(events, isEmpty);
  });
}
