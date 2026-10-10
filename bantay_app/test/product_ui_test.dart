import 'package:bantay_app/ui/product_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('setup shows Figma steps and blocks missing emergency contact', (
    tester,
  ) async {
    await tester.pumpWidget(const ProductApp(testSetupOnly: true));
    expect(find.text('Your safety starts here'), findsOneWidget);
    expect(find.text('1. Emergency Contact'), findsOneWidget);
    expect(find.text('2. Check Sensors'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('3. Enable Guardian'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('3. Enable Guardian'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Start Calibration'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Start Calibration'));
    await tester.pump();
    expect(
      find.text('Enter a name and a valid +country-code number.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
