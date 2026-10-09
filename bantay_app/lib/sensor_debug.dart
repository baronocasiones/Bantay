// Path 1 sensor debug panel. This exists to watch the stream slice 1 produces
// -- measured sample rate, batch cadence, drop accounting, live magnitude --
// not to be the product UI. It is labelled as test-only everywhere it renders,
// the same convention the Path 2 diagnostics use.

import 'dart:async';
import 'dart:math' as math;

import 'package:bantay_app/sensor_payload.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Recent samples kept for the live strip; 100 samples is 2 s at 50 Hz.
const int _stripSamples = 100;

class SensorDebugPanel extends StatefulWidget {
  const SensorDebugPanel({super.key});

  @override
  State<SensorDebugPanel> createState() => SensorDebugPanelState();
}

@visibleForTesting
class SensorDebugPanelState extends State<SensorDebugPanel> {
  // Not const: the MethodChannel constructor registers with the platform.
  static final MethodChannel channel = MethodChannel(sensorChannelName);

  SensorStatus _status = const SensorStatus(running: false);
  final RateTracker _sampleRate = RateTracker();
  final RateTracker _batchRate = RateTracker();
  final List<AccelSample> _recent = <AccelSample>[];
  int _droppedTotal = 0;
  int _lastSeq = 0;
  double _peakMagnitude = 0;
  int _rejectedBatches = 0;

  /// Fails tests loudly if the test-only banner disappears from the panel.
  @visibleForTesting
  static const String testOnlyBanner =
      'Test only; never use for an emergency alert.';

  @override
  void initState() {
    super.initState();
    channel.setMethodCallHandler(_onNativeCall);
    _invoke(sensorMethodAttach);
  }

  @override
  void dispose() {
    _invoke(sensorMethodDetach);
    channel.setMethodCallHandler(null);
    super.dispose();
  }

  /// Fire-and-forget: a detached or restarting activity must not throw, and
  /// widget tests run without the platform channel anyway.
  void _invoke(String method) {
    unawaited(channel.invokeMethod<void>(method).catchError((_) {}));
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (!mounted) return;
    switch (call.method) {
      case sensorMethodBatch:
        final AccelBatch? batch = parseAccelBatch(call.arguments);
        if (batch == null) {
          setState(() => _rejectedBatches++);
          return;
        }
        setState(() => _applyBatch(batch));
        return;
      case sensorMethodState:
        final SensorStatus? status = SensorStatus.parse(call.arguments);
        if (status != null) {
          setState(() {
            if (!status.running) {
              // The stream ended, so every live measurement is now stale.
              // The restarted service also begins its sequence at 1 again,
              // which the de-dup in _applyBatch would otherwise drop until
              // the app restarts. Clear the live indicators; the cumulative
              // counters (dropped, rejected) stay by design.
              _recent.clear();
              _sampleRate.reset();
              _batchRate.reset();
              _peakMagnitude = 0;
            }
            _status = status;
          });
        }
        return;
    }
  }

  void _applyBatch(AccelBatch batch) {
    _droppedTotal += batch.dropped;
    _lastSeq = batch.seq;
    _batchRate.record(DateTime.now().millisecondsSinceEpoch.toDouble());
    for (final AccelSample sample in batch.samples) {
      // A re-attach re-drains up to 4 s of history; ignore anything already
      // seen so the measured rate reflects live samples only.
      if (_recent.isNotEmpty && sample.seq <= _recent.last.seq) continue;
      _sampleRate.record(sample.tMs);
      _peakMagnitude = math.max(_peakMagnitude, sample.magnitude);
      _recent.add(sample);
    }
    while (_recent.length > _stripSamples) {
      _recent.removeAt(0);
    }
  }

  /// Feeds a decoded batch without the platform channel. The channel wiring
  /// itself (Kotlin invokeMethod -> this handler) is exercised on the device.
  @visibleForTesting
  void applyBatchForTesting(AccelBatch batch) =>
      setState(() => _applyBatch(batch));

  Future<void> _toggleSampling() async {
    if (_status.running) {
      _invoke(sensorMethodStop);
    } else {
      _invoke(sensorMethodStart);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AccelSample? latest = _recent.isEmpty ? null : _recent.last;
    return Scaffold(
      appBar: AppBar(title: const Text('Bantay - Sensors (debug)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _status.running ? Icons.sensors : Icons.sensors_off,
                        color: _status.running
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _status.running
                              ? 'Watcher running: sampling and streaming'
                              : 'Watcher stopped',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  if (_status.error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _status.error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed: _toggleSampling,
                    child: Text(
                      _status.running ? 'Stop sampling' : 'Start sampling',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Stream measurements',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  _kv(theme, 'Sensor', _status.sensorName ?? 'not registered'),
                  _kv(
                    theme,
                    'Requested rate',
                    '${_status.requestedHz ?? '-'} Hz',
                  ),
                  _kv(
                    theme,
                    'Measured sample rate',
                    '${_sampleRate.hz.toStringAsFixed(1)} Hz',
                  ),
                  _kv(
                    theme,
                    'Batch cadence',
                    '${_batchRate.hz.toStringAsFixed(1)} Hz',
                  ),
                  _kv(theme, 'Last sample seq', '$_lastSeq'),
                  _kv(theme, 'Dropped (ring overwrote)', '$_droppedTotal'),
                  _kv(theme, 'Rejected batches', '$_rejectedBatches'),
                  _kv(
                    theme,
                    'Peak magnitude',
                    '${_peakMagnitude.toStringAsFixed(2)} g',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Live magnitude (last ${math.min(_recent.length, _stripSamples)} samples)',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 120,
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _MagnitudeStripPainter(
                        magnitudes: _recent
                            .map((AccelSample s) => s.magnitude)
                            .toList(),
                        baseline: 1.0,
                      ),
                    ),
                  ),
                  if (latest != null) ...[
                    const SizedBox(height: 12),
                    _kv(
                      theme,
                      'Latest',
                      'x ${latest.x.toStringAsFixed(2)}  '
                          'y ${latest.y.toStringAsFixed(2)}  '
                          'z ${latest.z.toStringAsFixed(2)}',
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            testOnlyBanner,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(ThemeData theme, String key, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text('$key: $value', style: theme.textTheme.bodySmall),
  );
}

/// Historical magnitudes around a 1 g baseline; auto-scales to the peak when
/// the stream is lively so an impact is visible when it happens.
class _MagnitudeStripPainter extends CustomPainter {
  _MagnitudeStripPainter({required this.magnitudes, required this.baseline});

  final List<double> magnitudes;
  final double baseline;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint line = Paint()
      ..color = const Color(0xFF00695C)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final Paint grid = Paint()
      ..color = const Color(0x1F000000)
      ..strokeWidth = 1;
    final Paint zero = Paint()
      ..color = const Color(0x3300695C)
      ..strokeWidth = 1;

    for (int i = 1; i < 4; i++) {
      final double y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (size.width <= 0 || size.height <= 0) return;

    if (magnitudes.isEmpty) {
      canvas.drawLine(
        Offset(0, size.height),
        Offset(size.width, size.height),
        grid,
      );
      return;
    }

    final double peak = magnitudes.reduce(math.max);
    final double scaleReference = math.max(peak, baseline * 2);
    // Baseline (1 g) sits around 1/3 up: quiet phone stays under it, an
    // impact (multi-g) pushes to the top.
    final double baselineY =
        size.height - (baseline / scaleReference) * size.height;
    canvas.drawLine(Offset(0, baselineY), Offset(size.width, baselineY), zero);

    final Path path = Path();
    for (int i = 0; i < magnitudes.length; i++) {
      final double x = size.width * i / math.max(1, magnitudes.length - 1);
      final double y =
          size.height - (magnitudes[i] / scaleReference) * size.height;
      final double dx = math.min(math.max(x, 0), size.width);
      final double dy = math.min(math.max(y, 0), size.height);
      final Offset point = Offset(dx, dy);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(_MagnitudeStripPainter old) =>
      old.magnitudes.length != magnitudes.length ||
      magnitudes.isEmpty ||
      magnitudes.last != old.magnitudes.last;
}
