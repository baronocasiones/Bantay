import 'dart:collection';
import 'dart:developer' as developer;

import 'package:bantay_app/alerts/native_incident_gateway.dart';
import 'package:bantay_llm/bantay_llm.dart';

typedef ComposeLocalAlert = Future<AlertResult> Function(
  ImpactFacts facts,
  AlertLanguage language, {
  required Duration timeout,
  required bool includeLocation,
});

typedef SubmitLocalAlert = Future<bool> Function(
  String incidentId,
  String text,
);

/// Runs optional on-device wording during a native fall countdown.
///
/// This coordinator never decides whether an alert is real or sends an SMS.
/// Native Path 1 remains responsible for the deadline and final acceptance.
class LocalModelAlertCoordinator {
  LocalModelAlertCoordinator({
    required this.compose,
    required this.submit,
    required this.now,
    required this.languageCode,
    this.bridgeReserve = const Duration(milliseconds: 500),
  });

  final ComposeLocalAlert compose;
  final SubmitLocalAlert submit;
  final DateTime Function() now;
  final String Function() languageCode;
  final Duration bridgeReserve;
  final Queue<String> _recentIds = Queue<String>();
  final Set<String> _handledIds = <String>{};

  Future<void> onIncident(
    NativeIncidentSnapshot snapshot, {
    required String contactName,
  }) async {
    final id = snapshot.incidentId;
    final deadline = snapshot.deadline;
    final occurredAt = snapshot.occurredAt;
    final peakG = snapshot.peakG;
    final stillnessSeconds = snapshot.stillnessSeconds;
    if (!snapshot.counting ||
        snapshot.manual ||
        id == null ||
        deadline == null ||
        occurredAt == null ||
        peakG == null ||
        stillnessSeconds == null ||
        _handledIds.contains(id)) {
      return;
    }

    final beforeImpact = switch (snapshot.beforeImpact) {
      'walking' => BeforeImpact.walking,
      'still' => BeforeImpact.still,
      'running' => BeforeImpact.running,
      _ => BeforeImpact.unknown,
    };
    final remaining = deadline.difference(now());
    final timeout = remaining - bridgeReserve;
    if (timeout <= Duration.zero) {
      developer.log(
        'model skipped: insufficient countdown time',
        name: 'Bantay.Path2',
        error: 'incident=$id remainingMs=${remaining.inMilliseconds}',
      );
      _remember(id);
      return;
    }
    _remember(id);

    final facts = ImpactFacts(
      occurredAt: occurredAt,
      peakG: peakG,
      beforeImpact: beforeImpact,
      afterImpact: AfterImpact.noMovement,
      stillnessSeconds: stillnessSeconds,
      contactName: contactName,
    );
    // Emergency SMS recipients in this release are served in Tagalog,
    // independent of the phone's UI locale.
    final language = AlertLanguage.tagalog;
    final started = now();
    developer.log(
      'model generation started',
      name: 'Bantay.Path2',
      error:
          'incident=$id timeoutMs=${timeout.inMilliseconds} '
          'phoneLocale=${_languageFor(languageCode()).name} '
          'alertLanguage=${language.name}',
    );

    try {
      final result = await compose(
        facts,
        language,
        timeout: timeout,
        includeLocation: false,
      );
      final elapsedMs = now().difference(started).inMilliseconds;
      if (!result.llmUsed) {
        developer.log(
          'model result rejected or fallback used',
          name: 'Bantay.Path2',
          error: 'incident=$id elapsedMs=$elapsedMs llmUsed=false',
        );
        return;
      }
      if (now().isBefore(deadline)) {
        final accepted = await submit(id, result.text);
        developer.log(
          'model result returned',
          name: 'Bantay.Path2',
          error:
              'incident=$id elapsedMs=$elapsedMs llmUsed=true '
              'nativeAccepted=$accepted',
        );
      } else {
        developer.log(
          'model result arrived after deadline',
          name: 'Bantay.Path2',
          error: 'incident=$id elapsedMs=$elapsedMs llmUsed=true',
        );
      }
    } catch (error, stackTrace) {
      developer.log(
        'model path failed open',
        name: 'Bantay.Path2',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _remember(String id) {
    _handledIds.add(id);
    _recentIds.addLast(id);
    if (_recentIds.length > 32) _handledIds.remove(_recentIds.removeFirst());
  }

  static AlertLanguage _languageFor(String code) =>
      code.toLowerCase() == 'fil' || code.toLowerCase() == 'tl'
      ? AlertLanguage.tagalog
      : AlertLanguage.english;
}
