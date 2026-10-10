import 'dart:async';

import 'package:bantay_app/alerts/alert_gateway.dart';
import 'package:bantay_app/alerts/incident_controller.dart';
import 'package:bantay_llm/bantay_llm.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class _Gateway implements AlertGateway {
  final controller = StreamController<SmsSubmission>.broadcast();
  final calls = <String>[];
  @override
  Stream<SmsSubmission> get states => controller.stream;
  @override
  Future<bool> smsPermissionStatus() async => true;
  @override
  Future<bool> requestSmsPermission() async => true;
  @override
  Future<SmsSubmission> send({
    required String incidentId,
    required String number,
    required String body,
  }) async {
    calls.add(body);
    return SmsSubmission(incidentId, SmsState.queued);
  }

  @override
  Future<List<SmsSubmission>> outboxSnapshot() async => [];
  @override
  void dispose() => controller.close();
}

ImpactFacts _facts() => ImpactFacts(
  occurredAt: DateTime(2026, 10, 10, 12),
  peakG: 5,
  beforeImpact: BeforeImpact.still,
  afterImpact: AfterImpact.noMovement,
  stillnessSeconds: 2,
  contactName: 'Test Contact',
);
void main() {
  test(
    'fixed text exists before slow generation and send never waits',
    () async {
      final gateway = _Gateway();
      final slow = Completer<AlertResult>();
      final controller = IncidentController(
        gateway: gateway,
        fallback: (_, _) => const AlertResult('fixed', llmUsed: false),
        compose: (_, _) => slow.future,
      );
      controller.start(facts: _facts(), number: '+630000000000');
      expect(controller.alert!.text, 'fixed');
      await controller.sendHelp();
      expect(gateway.calls, ['fixed']);
      slow.complete(const AlertResult('late', llmUsed: true));
      await Future<void>.delayed(Duration.zero);
      expect(controller.alert!.text, 'fixed');
      controller.dispose();
      gateway.dispose();
    },
  );
  test('late queued response cannot overwrite carrier sent callback', () async {
    final gateway = _Gateway();
    final controller = IncidentController(
      gateway: gateway,
      fallback: (_, _) => const AlertResult('fixed', llmUsed: false),
      compose: (_, _) async => const AlertResult('fixed', llmUsed: false),
    );
    controller.start(facts: _facts(), number: '+630000000000');
    await controller.sendHelp();
    gateway.controller.add(
      SmsSubmission(controller.incidentId!, SmsState.sent),
    );
    await Future<void>.delayed(Duration.zero);
    gateway.controller.add(
      SmsSubmission(controller.incidentId!, SmsState.queued),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.stage, IncidentStage.sent);
    controller.dispose();
    gateway.dispose();
  });
  test('cancel prevents all sends', () {
    fakeAsync((async) {
      final gateway = _Gateway();
      final controller = IncidentController(
        gateway: gateway,
        now: () => DateTime(2026).add(async.elapsed),
        fallback: (_, _) => const AlertResult('fixed', llmUsed: false),
        compose: (_, _) async => const AlertResult('fixed', llmUsed: false),
      );
      controller.start(facts: _facts(), number: '+630000000000');
      controller.cancel();
      async.elapse(const Duration(seconds: 16));
      expect(gateway.calls, isEmpty);
      controller.dispose();
      gateway.dispose();
    });
  });
  test('expiry and repeated send issue one submission', () {
    fakeAsync((async) {
      final gateway = _Gateway();
      final controller = IncidentController(
        gateway: gateway,
        now: () => DateTime(2026).add(async.elapsed),
        fallback: (_, _) => const AlertResult('fixed', llmUsed: false),
        compose: (_, _) async => const AlertResult('fixed', llmUsed: false),
      );
      controller.start(facts: _facts(), number: '+630000000000');
      async.elapse(const Duration(seconds: 15));
      expect(gateway.calls, ['fixed']);
      controller.sendHelp();
      expect(gateway.calls, hasLength(1));
      controller.dispose();
      gateway.dispose();
    });
  });
}
