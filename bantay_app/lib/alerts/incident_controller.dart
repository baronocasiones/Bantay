import 'dart:async';

import 'package:bantay_app/alerts/alert_gateway.dart';
import 'package:bantay_llm/bantay_llm.dart';
import 'package:flutter/foundation.dart';

enum IncidentStage {
  idle,
  counting,
  canceled,
  sending,
  queued,
  sent,
  delivered,
  failed,
  /// Modem outcome unconfirmed. Distinct from `failed`, which implies a
  /// definite failure that is safe to retry.
  unknown,
}

typedef ComposeAlert = Future<AlertResult> Function(ImpactFacts, AlertLanguage);
typedef FallbackAlert = AlertResult Function(ImpactFacts, AlertLanguage);

class IncidentController extends ChangeNotifier {
  IncidentController({
    required this._gateway,
    required this._fallback,
    required this._compose,
    DateTime Function()? now,
    this.countdown = const Duration(seconds: 15),
  }) : _now = now ?? DateTime.now {
    _subscription = _gateway.states.listen(_onSmsState);
  }
  final AlertGateway _gateway;
  final FallbackAlert _fallback;
  final ComposeAlert _compose;
  final DateTime Function() _now;
  final Duration countdown;
  late final StreamSubscription<SmsSubmission> _subscription;
  Timer? _timer;
  int _generation = 0;

  IncidentStage stage = IncidentStage.idle;
  String? incidentId;
  String? destination;
  ImpactFacts? facts;
  AlertResult? alert;
  SmsSubmission? submission;
  DateTime? deadline;
  int secondsLeft = 0;
  bool get active => stage == IncidentStage.counting;

  void start({
    required ImpactFacts facts,
    required String number,
    AlertLanguage language = AlertLanguage.english,
    AlertResult? fixedAlert,
  }) {
    if (stage == IncidentStage.counting ||
        stage == IncidentStage.sending ||
        stage == IncidentStage.queued) {
      return;
    }
    final generation = ++_generation;
    this.facts = facts;
    destination = number;
    incidentId = [_now().microsecondsSinceEpoch, generation].join('-');
    alert = fixedAlert ?? _fallback(facts, language);
    submission = null;
    deadline = _now().add(countdown);
    secondsLeft = countdown.inSeconds;
    stage = IncidentStage.counting;
    notifyListeners();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => tick());
    if (fixedAlert == null) {
      unawaited(
        _compose(facts, language)
            .then((result) {
              if (_generation != generation || stage != IncidentStage.counting) {
                return;
              }
              alert = result;
              notifyListeners();
            })
            .catchError((Object _) {}),
      );
    }
  }

  void tick() {
    if (stage != IncidentStage.counting) return;
    final remaining = deadline!.difference(_now()).inMilliseconds;
    final next = remaining <= 0 ? 0 : (remaining / 1000).ceil();
    if (next != secondsLeft) {
      secondsLeft = next;
      notifyListeners();
    }
    if (remaining <= 0) unawaited(sendHelp());
  }

  void cancel() {
    if (stage != IncidentStage.counting) return;
    ++_generation;
    _timer?.cancel();
    stage = IncidentStage.canceled;
    notifyListeners();
  }

  Future<void> sendHelp() async {
    if (stage != IncidentStage.counting) return;
    ++_generation;
    _timer?.cancel();
    stage = IncidentStage.sending;
    final id = incidentId!;
    final number = destination!;
    final body = alert!.text;
    notifyListeners();
    try {
      final result = await _gateway.send(
        incidentId: id,
        number: number,
        body: body,
      );
      if (incidentId == id) _onSmsState(result);
    } catch (error) {
      if (incidentId == id) {
        _onSmsState(SmsSubmission(id, SmsState.failed, error: '$error'));
      }
    }
  }

  void _onSmsState(SmsSubmission event) {
    if (event.incidentId != incidentId) return;
    final previous = submission?.state;
    // Ranks only decide whether a late event may overwrite a terminal one.
    // `unknown` sits at the top with delivered: the outcome is unconfirmed,
    // and treating it as lower than `sent` would let a stale callback undo a
    // completed send.
    const rank = {
      SmsState.queued: 0,
      SmsState.sending: 1,
      SmsState.sent: 2,
      SmsState.failed: 2,
      SmsState.delivered: 3,
      SmsState.unknown: 3,
    };
    final eventRank = rank[event.state];
    // An unmapped state must never throw here; without a rank we simply keep
    // what we already have rather than inventing a stage.
    if (eventRank == null) return;
    if (previous != null && eventRank < rank[previous]!) return;
    submission = event;
    stage = switch (event.state) {
      SmsState.queued => IncidentStage.queued,
      SmsState.sending => IncidentStage.sending,
      SmsState.sent => IncidentStage.sent,
      SmsState.delivered => IncidentStage.delivered,
      SmsState.failed => IncidentStage.failed,
      // The modem may well have accepted the message; we cannot prove it, so
      // this is its own answer rather than a lie in either direction. The
      // distinguishing detail lives in `submission.error`.
      SmsState.unknown => IncidentStage.unknown,
    };
    notifyListeners();
  }

  void clear() {
    _timer?.cancel();
    ++_generation;
    stage = IncidentStage.idle;
    incidentId = null;
    destination = null;
    facts = null;
    alert = null;
    submission = null;
    deadline = null;
    secondsLeft = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _subscription.cancel();
    super.dispose();
  }
}
