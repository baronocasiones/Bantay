import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

import 'alert_composer.dart';

/// LiteRT-LM adapter. Load once during setup; never call from Path 1 detection.
class LitertAlertGenerator implements AlertGenerator {
  InferenceModel? _model;
  InferenceModelSession? _warmSession;
  InferenceModelSession? _activeSession;
  bool _busy = false;
  bool _cancelRequested = false;

  bool get isReady => _model != null;

  Future<void> initializeFromFile(
    String modelPath, {
    PreferredBackend backend = PreferredBackend.cpu,
  }) async {
    if (_model != null) return;
    if (!await File(modelPath).exists()) {
      throw FileSystemException('LiteRT-LM model file not found', modelPath);
    }

    await FlutterEdgeAi.initialize(inferenceEngines: const [LiteRtLmEngine()]);
    await FlutterEdgeAi.installModel(
      modelType: ModelType.qwen3,
      fileType: ModelFileType.litertlm,
    ).fromFile(modelPath).install();
    final model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 2048,
      preferredBackend: backend,
    );
    try {
      _warmSession = await _newSession(model);
      _model = model;
    } catch (_) {
      await model.close();
      rethrow;
    }
  }

  Future<InferenceModelSession> _newSession(InferenceModel model) =>
      model.createSession(
        temperature: 0.2,
        topK: 1,
        enableThinking: false,
        maxOutputTokens: 40,
      );

  @override
  Future<String> generate(String prompt) async {
    final model = _model;
    if (model == null) throw StateError('LiteRT-LM model is not ready.');
    if (_busy) throw StateError('LiteRT-LM generation already in progress.');

    _busy = true;
    _cancelRequested = false;
    InferenceModelSession? session;
    try {
      session = _warmSession ?? await _newSession(model);
      _warmSession = null;
      _activeSession = session;
      if (_cancelRequested) throw StateError('Generation cancelled.');

      await session.addQueryChunk(Message.text(text: prompt, isUser: true));
      if (_cancelRequested) throw StateError('Generation cancelled.');
      return await session.getResponse();
    } finally {
      _activeSession = null;
      try {
        await session?.close();
      } finally {
        _busy = false;
      }
    }
  }

  @override
  Future<void> stop() async {
    _cancelRequested = true;
    await _activeSession?.stopGeneration();
  }

  Future<void> dispose() async {
    await stop();
    await _warmSession?.close();
    _warmSession = null;
    final model = _model;
    _model = null;
    await model?.close();
  }
}
