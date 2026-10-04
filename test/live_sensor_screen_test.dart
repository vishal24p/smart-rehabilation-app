import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/live_sensor_screen.dart';
import 'package:rehab_monitor/wearable_connection.dart';
import 'wearable_connection_test.dart' as fixtures;

void main() {
  late WearableConnection connection;
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fixtures.commands, (_) async => null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('rehab/wearable/events'),
      (_) async => null,
    );
    connection = WearableConnection(android: true);
  });
  tearDown(() => connection.dispose());

  testWidgets('controls, raw readings and stale data behave honestly', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: LiveSensorScreen(connection: connection)),
    );
    expect(find.text('Live sensors'), findsOneWidget);
    expect(find.text('Connect wearable'), findsOneWidget);
    expect(find.text('No readings yet'), findsOneWidget);
    await tester.tap(find.text('Connect wearable'));
    await tester.pump();
    await tester.runAsync(() => fixtures.emit(fixtures.sample()));
    await tester.pump();
    expect(find.text('Live'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('1200 / 4095'), 200);
    expect(find.text('1200 / 4095'), findsOneWidget);
    expect(find.textContaining('raw counts'), findsWidgets);
    expect(find.textContaining('accuracy'), findsNothing);
    await tester.scrollUntilVisible(find.text('Disconnect'), -200);
    await tester.tap(find.text('Disconnect'));
    await tester.pump();
    expect(find.text('1200 / 4095'), findsNothing);
    expect(find.text('Retry connection'), findsOneWidget);
  });

  testWidgets('permission error is visible and retryable', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LiveSensorScreen(connection: connection)),
    );
    await tester.tap(find.text('Connect wearable'));
    await tester.pump();
    await tester.runAsync(
      () => fixtures.emit({
        'type': 'status',
        'status': 'error',
        'message': 'Nearby Wi-Fi permission denied. Allow it in Settings.',
      }),
    );
    await tester.pump();
    expect(find.textContaining('permission denied'), findsOneWidget);
    expect(find.text('Retry connection'), findsOneWidget);
  });

  for (final size in [const Size(320, 640), const Size(844, 390)]) {
    testWidgets('live screen fits $size with large text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(home: LiveSensorScreen(connection: connection)),
      );
      await tester.scrollUntilVisible(find.text('Connect wearable'), 100);
      await tester.tap(find.text('Connect wearable'));
      await tester.pump();
      await tester.runAsync(() => fixtures.emit(fixtures.sample()));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Heel ADC · last 10 seconds'),
        200,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
