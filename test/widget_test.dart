import 'package:flutter_test/flutter_test.dart';
import 'package:autogate_app/main.dart';

void main() {
  testWidgets('AutoGateApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const AutoGateApp());
    expect(find.text('AUTOGATE CONTROLLER'), findsOneWidget);
  });
}
