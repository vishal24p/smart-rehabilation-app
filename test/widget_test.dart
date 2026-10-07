import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/main.dart';
import 'package:rehab_monitor/live_sensor_screen.dart';
import 'package:rehab_monitor/exercise_reference_screen.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('rehab/wearable'),
          (call) async {
 if (call.method == 'getExerciseReferences' || call.method == 'getWorkoutSessions') return [];
 if (call.method == 'getSettings') return {'injured_leg': null, 'heel_zero': null};
 if (call.method == 'saveWorkoutSession') return call.arguments;
 return null;
 },
        );
  });
  testWidgets('home starts sessions without fabricated results', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.text('Start session'), findsOneWidget);
    expect(find.textContaining('Praveen'), findsNothing);
    expect(find.textContaining('accuracy'), findsNothing);
    expect(find.textContaining('Completed'), findsNothing);
    expect(find.textContaining('correct reps'), findsNothing);
    expect(find.text('Today’s progress'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
  for (final entry in {
    'Squat': 'squat',
    'Sit-to-stand': 'sit_to_stand',
  }.entries) {
    testWidgets('${entry.key} opens its selected live session', (tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start session'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LiveSensorScreen>(find.byType(LiveSensorScreen))
            .exerciseId,
        entry.value,
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Choose an exercise'), findsOneWidget);
    });
  }
  testWidgets('navigation opens registration and sensors exclusively', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    expect(find.byType(NavigationRail), findsOneWidget);
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();
    expect(find.byType(ExerciseReferenceScreen), findsOneWidget);
    await tester.tap(find.text('Sensors'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<LiveSensorScreen>(find.byType(LiveSensorScreen)).exerciseId,
      isNull,
    );
  });
  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets('home fits $size with large text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(const MyApp());
      await tester.tap(find.text('Sensors'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.text('Sensors'));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(size.width));
    });
  }

  testWidgets('resizing navigation retains active registration screen', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();
    final before = tester.state(find.byType(ExerciseReferenceScreen));
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(
      identical(tester.state(find.byType(ExerciseReferenceScreen)), before),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}
