import 'dart:typed_data';

import 'package:bantay_app/sensor_debug.dart';
import 'package:bantay_app/sensor_payload.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Not const: the MethodChannel constructor registers with the platform.
  final MethodChannel channel = MethodChannel(sensorChannelName);
  final List<String> sentMethods = <String>[];

  setUp(() {
    sentMethods.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          sentMethods.add(call.method);
          return null;
        });
  });

  /// Delivers an incoming call exactly as the Kotlin side would: the standard
  /// method-codec envelope over handlePlatformMessage.
  Future<void> pushFromKotlin(
    WidgetTester tester,
    String method,
    Object? arguments,
  ) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      sensorChannelName,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      ),
      (_) {},
    );
    await tester.pump();
  }

  Float64List batchMap() => Float64List.fromList(<double>[
    1000, 0.1, 0.2, 0.9, // |v| ~ 0.09 g
    1020, 0.3, 0.4, 0.5, // ~ 0.09 g
    1040, 4.0, 4.0, 4.0, // |v| ~ 0.71 g, the visible impact
  ]);

  testWidgets('panel attaches on init and detaches on dispose', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SensorDebugPanel()));
    expect(sentMethods, contains('attach'));

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(sentMethods, contains('detach'));
  });

  testWidgets('start button posts the start method to the service', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SensorDebugPanel()));
    await tester.tap(find.text('Start sampling'));
    await tester.pump();
    expect(sentMethods, contains('start'));
  });

  testWidgets('renders a decoded batch: rate, seq, peak, banner', (
    WidgetTester tester,
  ) async {
    // The panel is a lazy ListView and the banner sits past the cache extent
    // of the default 800x600 test surface, so it is never materialized there.
    // A tall viewport guarantees every child is built.
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: SensorDebugPanel()));

    await pushFromKotlin(tester, sensorMethodBatch, <String, Object>{
      'samples': batchMap(),
      'count': 3,
      'dropped': 0,
      'seq': 3,
    });

    // 20 ms period across 3 samples measures 50.0 Hz.
    expect(find.text('Measured sample rate: 50.0 Hz'), findsOneWidget);
    expect(find.text('Last sample seq: 3'), findsOneWidget);
    expect(find.text('Dropped (ring overwrote): 0'), findsOneWidget);
    expect(find.textContaining('Peak magnitude'), findsOneWidget);
    expect(
      find.text('Peak magnitude: 0.71 g'),
      findsOneWidget,
    ); // sqrt(4^2 * 3) / 9.80665
    expect(find.text(SensorDebugPanelState.testOnlyBanner), findsOneWidget);
  });

  testWidgets('drop accounting accumulates across batches', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SensorDebugPanel()));

    await pushFromKotlin(tester, sensorMethodBatch, <String, Object>{
      'samples': batchMap(),
      'count': 3,
      'dropped': 7,
      'seq': 10,
    });
    await pushFromKotlin(tester, sensorMethodBatch, <String, Object>{
      'samples': batchMap(),
      'count': 3,
      'dropped': 0,
      'seq': 20,
    });

    expect(find.text('Dropped (ring overwrote): 7'), findsOneWidget);
    expect(find.text('Last sample seq: 20'), findsOneWidget);
  });

  testWidgets('stopping the stream clears live measurements, not counters', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: SensorDebugPanel()));

    // Live stream first.
    await pushFromKotlin(tester, sensorMethodBatch, <String, Object>{
      'samples': batchMap(),
      'count': 3,
      'dropped': 2,
      'seq': 3,
    });
    expect(find.text('Peak magnitude: 0.71 g'), findsOneWidget);

    // The service stops: live indicators reset, cumulative dropped stays.
    await pushFromKotlin(tester, sensorMethodState, <String, Object?>{
      'running': false,
      'error': 'stopped by user',
    });
    expect(find.text('Measured sample rate: 0.0 Hz'), findsOneWidget);
    expect(find.text('Peak magnitude: 0.00 g'), findsOneWidget);
    expect(find.text('Live magnitude (last 0 samples)'), findsOneWidget);
    expect(find.text('Dropped (ring overwrote): 2'), findsOneWidget);

    // A restarted service begins its sequence at 1 again; the de-dup in
    // _applyBatch must not swallow the fresh stream.
    await pushFromKotlin(tester, sensorMethodBatch, <String, Object>{
      'samples': batchMap(),
      'count': 3,
      'dropped': 0,
      'seq': 3,
    });
    expect(find.text('Measured sample rate: 50.0 Hz'), findsOneWidget);
    expect(find.text('Last sample seq: 3'), findsOneWidget);
  });

  testWidgets('a malformed batch is counted, not half-applied', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SensorDebugPanel()));

    await pushFromKotlin(tester, sensorMethodBatch, <String, Object>{
      'samples': Float64List.fromList(<double>[1000, 0, 0, double.nan]),
      'count': 1,
      'dropped': 0,
      'seq': 1,
    });

    expect(find.text('Rejected batches: 1'), findsOneWidget);
    expect(find.text('Measured sample rate: 0.0 Hz'), findsOneWidget);
  });

  testWidgets('service state renders running and stop affordance', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SensorDebugPanel()));

    await pushFromKotlin(tester, sensorMethodState, <String, Object?>{
      'running': true,
      'error': null,
      'sensorName': 'LSM6DSO Accelerometer',
      'requestedHz': 50,
    });

    expect(
      find.text('Watcher running: sampling and streaming'),
      findsOneWidget,
    );
    expect(find.text('Sensor: LSM6DSO Accelerometer'), findsOneWidget);
    expect(find.text('Requested rate: 50 Hz'), findsOneWidget);
    expect(find.text('Stop sampling'), findsOneWidget);
  });

  testWidgets('service failure surfaces the reason', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SensorDebugPanel()));

    await pushFromKotlin(tester, sensorMethodState, <String, Object?>{
      'running': false,
      'error': 'accelerometer unavailable',
      'sensorName': null,
      'requestedHz': null,
    });

    expect(find.text('accelerometer unavailable'), findsOneWidget);
    expect(find.text('Sensor: not registered'), findsOneWidget);
  });
}
