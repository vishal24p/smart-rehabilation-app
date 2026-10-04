import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/main.dart';

void main() {
  testWidgets('opens live sensors separately from the sample review', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.scrollUntilVisible(find.text('Live sensors'), 200);
    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live sensors'));
    await tester.pumpAndSettle();
    expect(find.text('No readings yet'), findsOneWidget);
    expect(find.text('78%'), findsNothing);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 1500));
    await tester.pumpAndSettle();
    expect(find.text('Today’s session'), findsOneWidget);
  });
  testWidgets('shows a completed session review', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MyApp());

    expect(find.text('Good morning, Praveen'), findsOneWidget);
    expect(find.text('Today’s session'), findsOneWidget);
    expect(find.text('Completed today'), findsOneWidget);
    expect(find.text('78% accuracy · 8 reps to improve'), findsOneWidget);
    expect(
      find.bySemanticsLabel('28 of 36 correct repetitions'),
      findsOneWidget,
    );
    expect(find.text('78%'), findsOneWidget);
    expect(
      tester.getRect(find.text('~12 min')).right,
      closeTo(tester.getRect(find.text('78%')).right, 0.1),
    );
    final overallProgress = find.bySemanticsLabel(RegExp('Overall progress'));
    expect(overallProgress, findsOneWidget);
    expect(tester.getSemantics(overallProgress).value, '78%');

    final theme = Theme.of(tester.element(find.byType(HomeScreen)));
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, Colors.white);

    await tester.scrollUntilVisible(find.text('Seated Knee Extension'), 200);
    expect(find.text('Seated Knee Extension'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Seated Knee Extension: completed'),
      findsOneWidget,
    );
    expect(find.text('Completed'), findsWidgets);
    expect(find.text('16 / 20', findRichText: true), findsOneWidget);
    await tester.ensureVisible(find.byType(LinearProgressIndicator).first);
    await tester.pump();
    final kneeProgress = find.bySemanticsLabel(
      'Seated Knee Extension: 16 of 20 correct repetitions',
    );
    expect(kneeProgress, findsOneWidget);
    expect(tester.getSemantics(kneeProgress).value, '80%');

    await tester.scrollUntilVisible(
      find.text('12 / 16', findRichText: true),
      200,
    );
    expect(find.text('Supported Sit to Stand'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Supported Sit to Stand: completed'),
      findsOneWidget,
    );
    expect(find.text('12 / 16', findRichText: true), findsOneWidget);
    await tester.ensureVisible(find.byType(LinearProgressIndicator).last);
    await tester.pump();
    final standProgress = find.bySemanticsLabel(
      'Supported Sit to Stand: 12 of 16 correct repetitions',
    );
    expect(standProgress, findsOneWidget);
    expect(tester.getSemantics(standProgress).value, '75%');

    final continueButton = find.widgetWithText(FilledButton, 'Review session');
    await tester.scrollUntilVisible(continueButton, 200);
    await tester.tap(continueButton);
    await tester.pumpAndSettle();

    expect(find.text('Today’s session'), findsOneWidget);
    expect(find.text('Progress'), findsNothing);
    expect(find.text('Profile'), findsNothing);

    semantics.dispose();
  });

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets('fits $size with large text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(const MyApp());
      await tester.scrollUntilVisible(
        find.text('Sample session · Sensors are not connected'),
        150,
      );
      await tester.scrollUntilVisible(find.text('Review session'), 150);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      _expectInsideViewport(tester, find.text('Review session'));
      _expectInsideViewport(
        tester,
        find.text('Sample session · Sensors are not connected'),
      );
      await tester.tap(find.text('Review session'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

void _expectInsideViewport(WidgetTester tester, Finder finder) {
  final rect = tester.getRect(finder);
  final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(viewport.width));
  expect(rect.bottom, lessThanOrEqualTo(viewport.height));
}
