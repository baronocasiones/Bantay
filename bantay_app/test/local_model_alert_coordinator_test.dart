import 'package:bantay_app/alerts/local_model_alert_coordinator.dart';
import 'package:bantay_app/alerts/native_incident_gateway.dart';
import 'package:bantay_llm/bantay_llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final deadline = DateTime(2026, 10, 10, 12, 0, 15);

  NativeIncidentSnapshot snapshot({
    NativeIncidentStage stage = NativeIncidentStage.counting,
    bool manual = false,
    DateTime? deadlineOverride,
  }) => NativeIncidentSnapshot(
    armed: true,
    stage: stage,
    incidentId: 'fall-1',
    deadline: deadlineOverride ?? deadline,
    occurredAt: DateTime(2026, 10, 10, 11, 59, 59),
    peakG: 7.2,
    beforeImpact: 'walking',
    stillnessSeconds: 2,
    manual: manual,
  );

  test('maps fall facts and submits only grounded model result', () async {
    ImpactFacts? facts;
    Duration? timeoutSeen;
    String? submittedId;
    String? submittedText;
    final coordinator = LocalModelAlertCoordinator(
      compose:
          (
            value,
            language, {
            required timeout,
            required includeLocation,
          }) async {
            facts = value;
            timeoutSeen = timeout;
            expect(language, AlertLanguage.english);
            expect(includeLocation, isFalse);
            return const AlertResult('model wording', llmUsed: true);
          },
      submit: (id, text) async {
        submittedId = id;
        submittedText = text;
        return true;
      },
      now: () => DateTime(2026, 10, 10, 12, 0, 2),
      languageCode: () => 'en',
    );

    await coordinator.onIncident(snapshot(), contactName: 'Ana');

    expect(facts!.peakG, 7.2);
    expect(facts!.beforeImpact, BeforeImpact.walking);
    expect(facts!.afterImpact, AfterImpact.noMovement);
    expect(facts!.stillnessSeconds, 2);
    expect(facts!.contactName, 'Ana');
    expect(facts!.latitude, isNull);
    expect(timeoutSeen, const Duration(milliseconds: 12500));
    expect(submittedId, 'fall-1');
    expect(submittedText, 'model wording');
  });

  test('uses Tagalog for Filipino device locale', () async {
    AlertLanguage? languageSeen;
    final coordinator = LocalModelAlertCoordinator(
      compose:
          (_, language, {required timeout, required includeLocation}) async {
            languageSeen = language;
            return const AlertResult('candidate', llmUsed: false);
          },
      submit: (_, _) async => fail('fallback must not be submitted'),
      now: () => DateTime(2026, 10, 10, 12, 0, 2),
      languageCode: () => 'fil',
    );

    await coordinator.onIncident(snapshot(), contactName: 'Ana');
    expect(languageSeen, AlertLanguage.tagalog);
  });

  test('never composes manual SOS or non-counting incident', () async {
    var calls = 0;
    final coordinator = LocalModelAlertCoordinator(
      compose: (_, _, {required timeout, required includeLocation}) async {
        calls++;
        return const AlertResult('candidate', llmUsed: true);
      },
      submit: (_, _) async => true,
      now: () => DateTime(2026, 10, 10, 12, 0, 2),
      languageCode: () => 'en',
    );

    await coordinator.onIncident(snapshot(manual: true), contactName: 'Ana');
    await coordinator.onIncident(
      snapshot(stage: NativeIncidentStage.sent),
      contactName: 'Ana',
    );
    expect(calls, 0);
  });

  test(
    'skips incidents with too little time and deduplicates incident',
    () async {
      var calls = 0;
      final coordinator = LocalModelAlertCoordinator(
        compose: (_, _, {required timeout, required includeLocation}) async {
          calls++;
          return const AlertResult('candidate', llmUsed: true);
        },
        submit: (_, _) async => true,
        now: () => deadline.subtract(const Duration(milliseconds: 300)),
        languageCode: () => 'en',
      );
      final tooLate = snapshot(deadlineOverride: deadline);
      await coordinator.onIncident(tooLate, contactName: 'Ana');
      await coordinator.onIncident(tooLate, contactName: 'Ana');
      expect(calls, 0);
    },
  );

  test('does not submit a result after its deadline', () async {
    var submits = 0;
    final coordinator = LocalModelAlertCoordinator(
      compose: (_, _, {required timeout, required includeLocation}) async =>
          const AlertResult('late candidate', llmUsed: true),
      submit: (_, _) async {
        submits++;
        return true;
      },
      now: () => deadline,
      languageCode: () => 'en',
    );
    await coordinator.onIncident(snapshot(), contactName: 'Ana');
    expect(submits, 0);
  });

  test('does not submit fallback template', () async {
    var submits = 0;
    final coordinator = LocalModelAlertCoordinator(
      compose: (_, _, {required timeout, required includeLocation}) async =>
          const AlertResult('fixed fallback', llmUsed: false),
      submit: (_, _) async {
        submits++;
        return true;
      },
      now: () => DateTime(2026, 10, 10, 12, 0, 2),
      languageCode: () => 'en',
    );
    await coordinator.onIncident(snapshot(), contactName: 'Ana');
    expect(submits, 0);
  });
}
