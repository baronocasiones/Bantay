import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'alert_composer.dart';
import 'impact_facts.dart';
import 'litert_alert_generator.dart';

/// Path 2 entry point. Path 1 can start its countdown before calling compose.
class BantayPath2 {
  BantayPath2() : _generator = LitertAlertGenerator();

  final LitertAlertGenerator _generator;

  bool get modelReady => _generator.isReady;

  AlertResult fallback(ImpactFacts facts, AlertLanguage language) =>
      const AlertComposer().fallback(facts, language);

  /// Call during setup, before monitoring starts. Failure leaves fallback ready.
  ///
  /// [backend] exists so the demo phone can be measured on CPU and GPU. CPU is
  /// the default: it works everywhere and, per the model card, is the only
  /// backend with published numbers. GPU only helps when prefill is the
  /// bottleneck, which is exactly the case on low-end CPUs.
  Future<bool> prepareFromFile(
    String modelPath, {
    PreferredBackend backend = PreferredBackend.cpu,
  }) async {
    try {
      await _generator.initializeFromFile(modelPath, backend: backend);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<AlertResult> compose(ImpactFacts facts, AlertLanguage language) {
    return AlertComposer(
      generator: _generator.isReady ? _generator : null,
    ).compose(facts, language);
  }

  /// Phone-harness measurement only. Never wait for this in an alert flow.
  Future<AlertResult> composeDiagnostic(
    ImpactFacts facts,
    AlertLanguage language, {
    required void Function(String text) onCandidate,
  }) {
    return AlertComposer(
      generator: _generator.isReady ? _generator : null,
      timeout: const Duration(seconds: 30),
      onCandidate: onCandidate,
    ).compose(facts, language);
  }

  /// Tests raw prompt handling on a phone. Its output is never an alert.
  Future<String> probePrompt(String prompt) {
    if (!_generator.isReady) throw StateError('Model is not ready.');
    return _generator
        .generate(prompt)
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            unawaited(_generator.stop().catchError((Object _) {}));
            return '';
          },
        );
  }

  Future<void> dispose() => _generator.dispose();
}
