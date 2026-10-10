import 'package:bantay_app/domain/detector_worker.dart';
import 'package:bantay_app/sensor_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'background isolate turns a full sensor batch into one impact event',
    () async {
      final worker = DetectorWorker();
      await worker.start();
      final samples = <AccelSample>[];
      var seq = 0;
      void add(int count, double x, double y, double z) {
        for (var i = 0; i < count; i++) {
          seq++;
          samples.add(
            AccelSample(seq: seq, tMs: (seq - 1) * 20.0, x: x, y: y, z: z),
          );
        }
      }

      add(50, 0, 0, 1);
      add(1, 0, 0, 5);
      add(160, 1, 0, 0);
      final next = worker.events.first.timeout(const Duration(seconds: 3));
      worker.feed(AccelBatch(samples: samples, dropped: 0, seq: seq));
      final event = await next;
      expect(event.peakG, closeTo(5, 0.01));
      await worker.dispose();
    },
  );
}
