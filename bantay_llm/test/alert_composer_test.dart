import 'dart:async';

import 'package:bantay_llm/bantay_llm.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeGenerator implements AlertGenerator {
  FakeGenerator(this.respond);

  final Future<String> Function(String prompt) respond;
  String? lastPrompt;
  int stopCalls = 0;

  @override
  Future<String> generate(String prompt) {
    lastPrompt = prompt;
    return respond(prompt);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

void main() {
  final facts = ImpactFacts(
    occurredAt: DateTime(2026, 10, 9, 2, 14),
    peakG: 7.2,
    beforeImpact: BeforeImpact.walking,
    afterImpact: AfterImpact.noMovement,
    stillnessSeconds: 8,
    latitude: 14.59950,
    longitude: 120.98420,
    contactName: 'Ana',
  );

  test('model absent returns complete English alert', () async {
    final result = await AlertComposer().compose(facts, AlertLanguage.english);

    expect(result.llmUsed, isFalse);
    expect(result.text, contains('7.2g'));
    expect(result.text, contains('2:14 AM'));
    expect(result.text, contains('8 seconds'));
    expect(result.text, contains('14.59950, 120.98420'));
  });

  test('fixed alert is available synchronously before generation', () {
    final generator = FakeGenerator((_) => Completer<String>().future);
    final result = AlertComposer(
      generator: generator,
    ).fallback(facts, AlertLanguage.english);

    expect(result.llmUsed, isFalse);
    expect(result.text, contains('7.2g'));
    expect(generator.lastPrompt, isNull);
  });

  test('model failure returns Tagalog fallback', () async {
    // Use Future.error rather than `async => throw`: an async closure whose
    // body only throws infers Future<Never>, and AlertComposer.compose calls
    // .timeout(onTimeout: ...) on the returned future. That dispatches on the
    // runtime type argument, so a Future<Never> receiver makes Dart reject the
    // onTimeout callback with a TypeError and leak the original error. The real
    // LitertAlertGenerator.generate is async and always returns Future<String>.
    final generator = FakeGenerator(
      (_) => Future<String>.error(StateError('engine failed')),
    );
    final result = await AlertComposer(
      generator: generator,
    ).compose(facts, AlertLanguage.tagalog);

    expect(result.llmUsed, isFalse);
    expect(result.text, startsWith('BANTAY alert: Posibleng pagkahulog'));
    expect(result.text, contains('7.2g'));
    expect(result.text, contains('14.59950, 120.98420'));
  });

  test('timeout stops generation and returns fallback', () async {
    final pending = Completer<String>();
    final generator = FakeGenerator((_) => pending.future);
    final result = await AlertComposer(
      generator: generator,
      timeout: const Duration(milliseconds: 20),
    ).compose(facts, AlertLanguage.english);

    expect(result.llmUsed, isFalse);
    expect(generator.stopCalls, 1);
  });

  test('empty or invented facts cannot become alert text', () async {
    for (final output in [
      '   ',
      'BANTAY alert: 9.9g at 2:14 AM. No movement for 8 seconds. '
          '14.59950, 120.98420',
      'BANTAY alert: 7.2g at 2:14 AM. No movement for 8 seconds. '
          'Location: 0.00000, 0.00000',
      'BANTAY alert: 7.2g at 2:14 AM. No movement for 8 seconds. '
          'Location: 14.59950, 120.98420. Unconscious for 30 minutes.',
    ]) {
      final generator = FakeGenerator((_) async => output);
      final result = await AlertComposer(
        generator: generator,
      ).compose(facts, AlertLanguage.english);
      expect(result.llmUsed, isFalse, reason: output);
    }
  });

  test('valid grounded model text is accepted', () async {
    const output =
        'BANTAY alert: Possible fall at 2:14 AM. 7.2g impact. '
        'Walking before impact. No movement for 8 seconds. '
        'Location: 14.59950, 120.98420.';
    final generator = FakeGenerator((_) async => output);
    final result = await AlertComposer(
      generator: generator,
    ).compose(facts, AlertLanguage.english);

    expect(result.llmUsed, isTrue);
    expect(result.text, output);
    expect(generator.lastPrompt, contains('Write one English SMS'));
  });

  test('production wording can omit location for native GPS suffix', () async {
    const output =
        'BANTAY alert: Possible fall at 2:14 AM; 7.2g impact; '
        'walking before impact; no movement for 8 seconds.';
    final generator = FakeGenerator((_) async => output);
    final result = await AlertComposer(
      generator: generator,
    ).compose(facts, AlertLanguage.english, includeLocation: false);

    expect(result.llmUsed, isTrue);
    expect(result.text, output);
    expect(generator.lastPrompt, isNot(contains('Location unavailable')));
    expect(generator.lastPrompt, isNot(contains('14.59950')));
    expect(generator.lastPrompt!.length, lessThan(320));
  });

  test('production model cannot claim location is unavailable', () async {
    const output =
        'BANTAY alert: Possible fall at 2:14 AM; 7.2g impact; '
        'walking before impact; no movement for 8 seconds. Location unavailable.';
    final generator = FakeGenerator((_) async => output);
    final result = await AlertComposer(
      generator: generator,
    ).compose(facts, AlertLanguage.english, includeLocation: false);

    expect(result.llmUsed, isFalse);
  });

  test('production composer honors caller countdown timeout', () async {
    final pending = Completer<String>();
    final generator = FakeGenerator((_) => pending.future);
    final result = await AlertComposer(
      generator: generator,
      timeout: const Duration(milliseconds: 15),
    ).compose(facts, AlertLanguage.english, includeLocation: false);

    expect(result.llmUsed, isFalse);
    expect(generator.stopCalls, 1);
  });

  test('valid grounded Tagalog text is accepted', () async {
    const output =
        'BANTAY alert: Posibleng pagkahulog noong 2:14 AM. '
        '7.2g impact. Naglalakad bago nito; walang galaw sa loob ng '
        '8 segundo. Lokasyon: 14.59950, 120.98420.';
    final generator = FakeGenerator((_) async => output);
    final result = await AlertComposer(
      generator: generator,
    ).compose(facts, AlertLanguage.tagalog);

    expect(result.llmUsed, isTrue);
    expect(result.text, output);
    expect(generator.lastPrompt, contains('Write one Tagalog SMS'));
  });

  test('diagnostics can inspect rejected text without using it', () async {
    const raw = 'BANTAY alert: Confirmed injury after a fall.';
    String? observed;
    final generator = FakeGenerator((_) async => raw);

    final result = await AlertComposer(
      generator: generator,
      onCandidate: (text) => observed = text,
    ).compose(facts, AlertLanguage.english);

    expect(observed, raw);
    expect(result.llmUsed, isFalse);
    expect(result.text, isNot(raw));
  });

  test(
    'moved incident with no coordinates states location unavailable',
    () async {
      final moved = ImpactFacts(
        occurredAt: DateTime(2026, 10, 9, 14, 5),
        peakG: 4.1,
        beforeImpact: BeforeImpact.unknown,
        afterImpact: AfterImpact.movedImmediately,
        contactName: 'Ana',
      );
      final result = await AlertComposer().compose(
        moved,
        AlertLanguage.english,
      );

      expect(result.text, contains('2:05 PM'));
      expect(result.text, contains('moved immediately'));
      expect(result.text, contains('Location unavailable'));
      expect(result.text, isNot(contains('no movement')));
    },
  );

  test('model cannot add a location when none was measured', () async {
    final moved = ImpactFacts(
      occurredAt: DateTime(2026, 10, 9, 14, 5),
      peakG: 4.1,
      beforeImpact: BeforeImpact.unknown,
      afterImpact: AfterImpact.movedImmediately,
      contactName: 'Ana',
    );
    const output =
        'BANTAY alert: Possible fall at 2:05 PM. 4.1g impact. '
        'Moved immediately. Location: 4.1, 2.';
    final generator = FakeGenerator((_) async => output);
    final result = await AlertComposer(
      generator: generator,
    ).compose(moved, AlertLanguage.english);

    expect(result.llmUsed, isFalse);
    expect(result.text, contains('Location unavailable'));
  });
}
