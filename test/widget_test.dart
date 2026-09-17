import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/main.dart';

void main() {
  testWidgets('shows session dashboard and Progress placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Session overview'), findsOneWidget);
    expect(find.text('Seated Knee Extension'), findsOneWidget);
    expect(find.text('16 / 20 correct'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('12 / 16 correct'), 200);
    expect(find.text('12 / 16 correct'), findsOneWidget);

    await tester.tap(find.text('Progress'));
    await tester.pump();

    expect(
      find.text('Progress is coming in the next mock iteration.'),
      findsOneWidget,
    );
  });
}
