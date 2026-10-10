import 'dart:async';

import 'package:bantay_app/sensor_payload.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Sole product subscriber to native sensor messages.
class SensorBridge {
  SensorBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(sensorChannelName);

  final MethodChannel _channel;
  final _batches = StreamController<AccelBatch>.broadcast();
  final _states = StreamController<SensorStatus>.broadcast();
  int _lastSeq = 0;
  bool _attached = false;
  SensorStatus currentStatus = const SensorStatus(running: false);
  AccelSample? latest;
  int rejectedBatches = 0;

  Stream<AccelBatch> get batches => _batches.stream;
  Stream<SensorStatus> get states => _states.stream;

  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    _channel.setMethodCallHandler(_onNative);
    await _channel.invokeMethod<void>(sensorMethodAttach);
  }

  Future<void> start() => _channel.invokeMethod<void>(sensorMethodStart);
  Future<void> stop() => _channel.invokeMethod<void>(sensorMethodStop);

  @visibleForTesting
  Future<void> acceptNativeForTesting(MethodCall call) => _onNative(call);

  Future<void> _onNative(MethodCall call) async {
    if (call.method == sensorMethodState) {
      final status = SensorStatus.parse(call.arguments);
      if (status == null) return;
      currentStatus = status;
      if (!status.running) {
        _lastSeq = 0;
        latest = null;
      }
      _states.add(status);
    } else if (call.method == sensorMethodBatch) {
      final batch = parseAccelBatch(call.arguments);
      if (batch == null) {
        rejectedBatches++;
        return;
      }
      final fresh = batch.samples.where((s) => s.seq > _lastSeq).toList();
      if (fresh.isEmpty) return;
      _lastSeq = fresh.last.seq;
      latest = fresh.last;
      _batches.add(
        AccelBatch(samples: fresh, dropped: batch.dropped, seq: fresh.last.seq),
      );
    }
  }

  Future<void> dispose() async {
    if (_attached) {
      await _channel.invokeMethod<void>(sensorMethodDetach);
      _channel.setMethodCallHandler(null);
    }
    await _batches.close();
    await _states.close();
  }
}
