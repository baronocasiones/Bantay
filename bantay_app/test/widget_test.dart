import 'package:bantay_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Widget tests run under a fake-async zone, so the real file probe inside
  // prepareFromFile never completes on its own. Start unprepared, then drive
  // prepareNow() inside runAsync, which escapes into real async.
  Future<void> pumpPreparedHarness(WidgetTester tester) async {
    await tester.pumpWidget(
      const BantayApp(
        autoPrepare: false,
        modelPathOverride: '/nonexistent/qwen3_0_6b.litertlm',
      ),
    );
    final Path2HarnessState state = tester.state(find.byType(Path2Harness));
    await tester.runAsync(state.prepareNow);
    await tester.pump();
  }

  testWidgets('shell starts in the preparing state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const BantayApp(
        autoPrepare: false,
        modelPathOverride: '/nonexistent/qwen3_0_6b.litertlm',
      ),
    );
    await tester.pump();

    expect(find.text('Preparing LiteRT-LM model...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('missing model degrades to offline text mode', (
    WidgetTester tester,
  ) async {
    await pumpPreparedHarness(tester);

    expect(find.text('Bantay - Path 2'), findsOneWidget);
    expect(
      find.text('Model unavailable - offline text mode only'),
      findsOneWidget,
    );
    expect(find.textContaining('Cold load'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Both language cards are present and the fixed alert is available
    // without the model.
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Tagalog'), findsOneWidget);
    expect(find.text('Compose alert'), findsNWidgets(2));
  });

  testWidgets('compose still yields a complete fixed alert with no model', (
    WidgetTester tester,
  ) async {
    await pumpPreparedHarness(tester);

    await tester.tap(find.text('Compose alert').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The English card renders the text twice by design: once as the Path 1
    // fixed alert and once as the Path 2 result.
    expect(find.textContaining('BANTAY alert: Possible fall'), findsNWidgets(2));
    expect(find.textContaining('7.2g'), findsWidgets);
    expect(find.text('llmUsed: false'), findsOneWidget);
  });

  test('sample facts match the bantay_llm test fixture', () {
    final facts = sampleFacts();
    expect(facts.impactText, '7.2g');
    expect(facts.coordinatesText, '14.59950, 120.98420');
    expect(facts.contactName, 'Ana');
  });
}