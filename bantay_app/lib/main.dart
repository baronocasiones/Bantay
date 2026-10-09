// Bantay host app shell.
//
// This shell exists to exercise Path 2 (bantay_llm) on a real arm64 Android
// phone and record the numbers the demo needs: cold model load time, whether
// Tagalog output survives the fact check, and how the 2-second timeout behaves.
//
// It does NOT implement Path 1 (sensor service, countdown, SMS). Those live in
// the Kotlin/Dart modules described in architecture.md. See
// ../architecture.md and ../bantay_llm/README.md.

import 'dart:io';

import 'package:bantay_llm/bantay_llm.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

const String _modelFileName = 'qwen3_0_6b_mixed_int4.litertlm';

/// Override the model location at build time when the file is not sitting in
/// the app-private documents directory:
///
///   flutter run --dart-define=BANTAY_MODEL_PATH=/sdcard/bantay/model.litertlm
const String _modelPathOverride = String.fromEnvironment('BANTAY_MODEL_PATH');

/// Which LiteRT-LM backend to benchmark. Prefill dominates on entry-level
/// phones, and GPU is the only backend that can change that number:
///
///   flutter run --dart-define=BANTAY_BACKEND=gpu
const String _backendOverride = String.fromEnvironment('BANTAY_BACKEND');

/// [override] takes the typed value from tests; otherwise the build-time
/// `BANTAY_BACKEND` define decides.
PreferredBackend resolveBackend({
  PreferredBackend? override,
  String? nameOverride,
}) {
  if (override != null) return override;
  final String value = (nameOverride ?? _backendOverride).toLowerCase();
  if (value == 'gpu') return PreferredBackend.gpu;
  return PreferredBackend.cpu;
}

Future<String> resolveModelPath({String? override}) async {
  if (override != null && override.isNotEmpty) return override;
  if (_modelPathOverride.isNotEmpty) return _modelPathOverride;
  final Directory dir = await getApplicationDocumentsDirectory();
  return '${dir.path}/$_modelFileName';
}

/// Sample incident. The values match the fixtures in bantay_llm's own tests so
/// phone output can be compared against the expected strings directly.
ImpactFacts sampleFacts() => ImpactFacts(
  occurredAt: DateTime.now(),
  peakG: 7.2,
  beforeImpact: BeforeImpact.walking,
  afterImpact: AfterImpact.noMovement,
  stillnessSeconds: 8,
  latitude: 14.59950,
  longitude: 120.98420,
  contactName: 'Ana',
);

void main() {
  // Required before preparing the LiteRT-LM model. See bantay_llm/README.md.
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BantayApp());
}

class BantayApp extends StatelessWidget {
  const BantayApp({
    super.key,
    this.modelPathOverride,
    this.backendOverride,
    this.autoPrepare = true,
  });

  /// Test hook forwarded to [Path2Harness].
  final String? modelPathOverride;

  /// Test hook forwarded to [Path2Harness].
  final PreferredBackend? backendOverride;

  /// Test hook: widget tests run under a fake-async zone, where the real file
  /// probe inside prepareFromFile never completes. Tests start unprepared and
  /// drive [Path2HarnessState.prepareNow] explicitly inside runAsync.
  final bool autoPrepare;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bantay',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00695C)),
        useMaterial3: true,
      ),
      home: Path2Harness(
        modelPathOverride: modelPathOverride,
        backendOverride: backendOverride,
        autoPrepare: autoPrepare,
      ),
    );
  }
}

class Path2Harness extends StatefulWidget {
  const Path2Harness({
    super.key,
    this.modelPathOverride,
    this.backendOverride,
    this.autoPrepare = true,
  });

  /// Test hook: forces a specific model location so the harness can be driven
  /// without a path_provider platform channel.
  final String? modelPathOverride;

  /// Test hook: forces a backend so tests never depend on the build-time define.
  final PreferredBackend? backendOverride;

  /// Test hook, see [BantayApp.autoPrepare].
  final bool autoPrepare;

  @override
  State<Path2Harness> createState() => Path2HarnessState();
}

class Path2HarnessState extends State<Path2Harness> {
  final BantayPath2 _path2 = BantayPath2();

  String _modelPath = '';
  bool _preparing = true;
  bool _modelReady = false;
  Duration? _coldLoad;
  bool _diagnosing = false;
  bool _diagnosticProbe = false;
  AlertLanguage? _diagnosticLanguage;
  String? _diagnosticCandidate;
  AlertResult? _diagnosticResult;
  Duration? _diagnosticElapsed;

  final Map<AlertLanguage, _RunRecord> _runs = {
    AlertLanguage.english: _RunRecord(AlertLanguage.english),
    AlertLanguage.tagalog: _RunRecord(AlertLanguage.tagalog),
  };

  @override
  void initState() {
    super.initState();
    if (widget.autoPrepare) _prepare();
  }

  /// Runs model preparation. Exposed so tests can call it inside runAsync.
  @visibleForTesting
  Future<void> prepareNow() => _prepare();

  Future<void> _prepare() async {
    // Any failure here leaves the fixed-alert fallback fully usable, which is
    // the whole point of Path 2 being optional.
    try {
      final String path = await resolveModelPath(
        override: widget.modelPathOverride,
      );
      final Stopwatch watch = Stopwatch()..start();
      // Preparation loads the model and opens a session. This is setup work and
      // must not happen after an impact. Failure leaves the fallback usable.
      final bool ready = await _path2.prepareFromFile(
        path,
        backend: resolveBackend(override: widget.backendOverride),
      );
      watch.stop();

      if (!mounted) return;
      setState(() {
        _modelPath = path;
        _modelReady = ready;
        _coldLoad = watch.elapsed;
        _preparing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _modelPath = 'unresolved';
        _modelReady = false;
        _coldLoad = Duration.zero;
        _preparing = false;
      });
    }
  }

  Future<void> _compose(AlertLanguage language) async {
    final ImpactFacts facts = sampleFacts();
    final _RunRecord record = _runs[language]!;

    // Path 1 owns the countdown. The fixed alert is available immediately;
    // the model only gets the chance to improve the wording.
    final AlertResult fallback = _path2.fallback(facts, language);
    setState(() => record.begin(fallback));

    final Stopwatch watch = Stopwatch()..start();
    final AlertResult result = await _path2.compose(facts, language);
    watch.stop();

    if (!mounted) return;
    setState(() => record.complete(result, watch.elapsed));
  }

  Future<void> _diagnose(AlertLanguage language) async {
    if (!_modelReady || _diagnosing) return;
    setState(() {
      _diagnosing = true;
      _diagnosticProbe = false;
      _diagnosticLanguage = language;
      _diagnosticCandidate = null;
      _diagnosticResult = null;
      _diagnosticElapsed = null;
    });

    String? candidate;
    final Stopwatch watch = Stopwatch()..start();
    final AlertResult result = await _path2.composeDiagnostic(
      sampleFacts(),
      language,
      onCandidate: (text) => candidate = text,
    );
    watch.stop();

    if (!mounted) return;
    setState(() {
      _diagnosing = false;
      _diagnosticCandidate = candidate;
      _diagnosticResult = result;
      _diagnosticElapsed = watch.elapsed;
    });
  }

  Future<void> _probePrompt() async {
    if (!_modelReady || _diagnosing) return;
    setState(() {
      _diagnosing = true;
      _diagnosticProbe = true;
      _diagnosticLanguage = null;
      _diagnosticCandidate = null;
      _diagnosticResult = null;
      _diagnosticElapsed = null;
    });

    final Stopwatch watch = Stopwatch()..start();
    String candidate;
    try {
      candidate = await _path2.probePrompt(
        'What is the capital of France? Answer with one word.',
      );
    } catch (error) {
      candidate = 'Probe error: $error';
    }
    watch.stop();

    if (!mounted) return;
    setState(() {
      _diagnosing = false;
      _diagnosticCandidate = candidate;
      _diagnosticElapsed = watch.elapsed;
    });
  }

  @override
  void dispose() {
    _path2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bantay - Path 2')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _modelCard(context),
          const SizedBox(height: 16),
          for (final AlertLanguage language in AlertLanguage.values) ...[
            _runCard(context, _runs[language]!),
            const SizedBox(height: 16),
          ],
          _diagnosticCard(context),
        ],
      ),
    );
  }

  Widget _modelCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (_preparing) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 16),
              Text('Preparing LiteRT-LM model...'),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _modelReady ? Icons.check_circle : Icons.cloud_off,
                  color: _modelReady
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _modelReady
                        ? 'Model ready (offline text mode available)'
                        : 'Model unavailable - offline text mode only',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _kv(theme, 'Cold load', '${_coldLoad!.inMilliseconds} ms'),
            _kv(theme, 'Backend', resolveBackend(
              override: widget.backendOverride,
            ).name),
            _kv(theme, 'Path', _modelPath),
          ],
        ),
      ),
    );
  }

  Widget _runCard(BuildContext context, _RunRecord record) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              record.language == AlertLanguage.tagalog ? 'Tagalog' : 'English',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: _preparing || _diagnosing
                  ? null
                  : () => _compose(record.language),
              child: const Text('Compose alert'),
            ),
            const SizedBox(height: 12),
            if (record.fallback != null) ...[
              Text(
                'Fixed alert (Path 1, always ready)',
                style: theme.textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              Text(record.fallback!),
              const Divider(height: 24),
            ],
            if (record.result != null) ...[
              Text('Path 2 result', style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(record.result!.text),
              const SizedBox(height: 12),
              _kv(
                theme,
                'llmUsed',
                record.llmUsed == null
                    ? 'running...'
                    : record.llmUsed!.toString(),
              ),
              if (record.elapsed != null)
                _kv(theme, 'Elapsed', '${record.elapsed!.inMilliseconds} ms'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _diagnosticCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Raw model diagnostic', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Allows up to 30 seconds. Test only; never use for an emergency alert.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final language in AlertLanguage.values)
                  OutlinedButton(
                    onPressed: !_modelReady || _diagnosing
                        ? null
                        : () => _diagnose(language),
                    child: Text(
                      language == AlertLanguage.tagalog
                          ? 'Test Tagalog'
                          : 'Test English',
                    ),
                  ),
                OutlinedButton(
                  onPressed: !_modelReady || _diagnosing ? null : _probePrompt,
                  child: const Text('Test short prompt'),
                ),
              ],
            ),
            if (_diagnosticLanguage != null || _diagnosticProbe) ...[
              const SizedBox(height: 12),
              Text(
                _diagnosing
                    ? 'Generating ${_diagnosticProbe ? 'short prompt' : _diagnosticLanguage!.name}...'
                    : _diagnosticProbe
                    ? 'Short prompt probe'
                    : 'Diagnostic ${_diagnosticLanguage!.name}',
                style: theme.textTheme.labelMedium,
              ),
              if (!_diagnosing) ...[
                const SizedBox(height: 8),
                Text(
                  _diagnosticCandidate?.isNotEmpty == true
                      ? _diagnosticCandidate!
                      : 'No candidate before timeout or error.',
                ),
                const SizedBox(height: 8),
                if (!_diagnosticProbe)
                  _kv(
                    theme,
                    'Accepted for alert',
                    _diagnosticResult!.llmUsed.toString(),
                  ),
                _kv(
                  theme,
                  'Elapsed',
                  '${_diagnosticElapsed!.inMilliseconds} ms',
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(ThemeData theme, String key, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text('$key: $value', style: theme.textTheme.bodySmall),
  );
}

class _RunRecord {
  _RunRecord(this.language);

  final AlertLanguage language;

  String? fallback;
  AlertResult? result;
  bool? llmUsed;
  Duration? elapsed;

  void begin(AlertResult fixed) {
    fallback = fixed.text;
    result = fixed;
    llmUsed = false;
    elapsed = null;
  }

  void complete(AlertResult value, Duration took) {
    result = value;
    llmUsed = value.llmUsed;
    elapsed = took;
  }
}
