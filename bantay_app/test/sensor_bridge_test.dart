import 'dart:typed_data';

import 'package:bantay_app/sensor_payload.dart';
import 'package:bantay_app/sensors/sensor_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one native batch publishes only fresh samples, rejects malformed data, resets', () async {
    final bridge = SensorBridge();
    final batches = <AccelBatch>[];
    final subscription = bridge.batches.listen(batches.add);
    final wire = Float64List.fromList([10, 0, 0, ms2PerG, 30, 0, 0, ms2PerG]);
    final payload = {'samples': wire, 'count': 2, 'dropped': 0, 'seq': 2};
    await bridge.acceptNativeForTesting(MethodCall('batch', payload));
    await bridge.acceptNativeForTesting(MethodCall('batch', payload));
    await bridge.acceptNativeForTesting(
      const MethodCall('batch', {'bad': true}),
    );
    await Future<void>.delayed(Duration.zero);
    expect(batches, hasLength(1));
    expect(batches.single.samples, hasLength(2));
    expect(bridge.rejectedBatches, 1);
    await bridge.acceptNativeForTesting(
      const MethodCall('state', {'running': false}),
    );
    await bridge.acceptNativeForTesting(MethodCall('batch', payload));
    await Future<void>.delayed(Duration.zero);
    expect(batches, hasLength(2));
    await subscription.cancel();
  });
}
