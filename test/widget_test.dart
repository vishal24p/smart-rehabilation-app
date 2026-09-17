import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/main.dart';

void main() {
  testWidgets('shows session dashboard and Progress placeholder', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MyApp());

    expect(find.text('Session overview'), findsOneWidget);
    expect(find.text('Seated Knee Extension'), findsOneWidget);
    expect(find.text('16 / 20 correct'), findsOneWidget);
    expect(find.textContaining('28 / 36'), findsOneWidget);
    expect(find.text('78%'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Seated Knee Extension, 16 of 20 correct repetitions'),
      ),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(find.text('12 / 16 correct'), 200);
    expect(find.text('12 / 16 correct'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Supported Sit to Stand, 12 of 16 correct repetitions'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Progress'));
    await tester.pump();

    expect(
      find.text('Progress is coming in the next mock iteration.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();

    expect(
      find.text('Profile is coming in the next mock iteration.'),
      findsOneWidget,
    );

    semantics.dispose();
  });
}
