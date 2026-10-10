import 'dart:async';
import 'dart:isolate';

import 'package:bantay_app/domain/fall_detector.dart';
import 'package:bantay_app/sensor_payload.dart';

/// Keeps cascade computation off Flutter's UI isolate.
class DetectorWorker {
  DetectorWorker();
  final _events = StreamController<ImpactEvent>.broadcast();
  final _incoming = ReceivePort();
  Isolate? _isolate;
  SendPort? _send;
  StreamSubscription<dynamic>? _subscription;
  final _ready = Completer<void>();

  Stream<ImpactEvent> get events => _events.stream;

  Future<void> start() async {
    _subscription = _incoming.listen((message) {
      if (message is SendPort) {
        _send = message;
        if (!_ready.isCompleted) _ready.complete();
      } else if (message is ImpactEvent) {
        _events.add(message);
      }
    });
    _isolate = await Isolate.spawn(_runDetector, _incoming.sendPort);
    await _ready.future;
  }

  void feed(AccelBatch batch) {
    final send = _send;
    if (send == null || batch.samples.isEmpty) return;
    send.send([
      'batch',
      for (final s in batch.samples) [s.seq, s.tMs, s.x, s.y, s.z],
    ]);
  }

  void suppressFor(Duration duration, double nowMs) =>
      _send?.send(['suppress', duration.inMilliseconds, nowMs]);

  void reset() => _send?.send(['reset']);

  Future<void> dispose() async {
    _isolate?.kill(priority: Isolate.immediate);
    await _subscription?.cancel();
    _incoming.close();
    await _events.close();
  }
}

void _runDetector(SendPort parent) {
  final receiver = ReceivePort();
  final detector = FallDetector();
  parent.send(receiver.sendPort);
  receiver.listen((dynamic raw) {
    if (raw is! List || raw.isEmpty) return;
    switch (raw.first) {
      case 'reset':
        detector.reset();
      case 'suppress':
        detector.suppressFor(
          Duration(milliseconds: raw[1] as int),
          nowMs: raw[2] as double,
        );
      case 'batch':
        for (final item in raw.skip(1)) {
          final row = item as List;
          final event = detector.addSample(
            AccelSample(
              seq: row[0] as int,
              tMs: row[1] as double,
              x: row[2] as double,
              y: row[3] as double,
              z: row[4] as double,
            ),
          );
          if (event != null) parent.send(event);
        }
    }
  });
}
