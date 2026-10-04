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

  testWidgets(
    'confirmed ranges reach Python and readings have semantic labels',
    (tester) async {
      final semantics = tester.ensureSemantics();
      Map<dynamic, dynamic>? arguments;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fixtures.commands, (call) async {
            if (call.method == 'connect')
              arguments = call.arguments as Map<dynamic, dynamic>;
            return null;
          });
      await tester.pumpWidget(
        MaterialApp(home: LiveSensorScreen(connection: connection)),
      );
      await tester.tap(find.text('IMU ranges confirmed'));
      await tester.pump();
      await tester.tap(find.text('Connect wearable'));
      await tester.pump();
      expect(arguments?['scaleConfirmed'], isTrue);
      final scaled = fixtures.sample()
        ..['scaled'] = true
        ..['thigh_accel'] = [0.2, 0.3, 0.4]
        ..['shin_accel'] = [0.1, 0.2, 0.3];
      await tester.runAsync(() => fixtures.emit(scaled));
      await tester.pump();
      await tester.scrollUntilVisible(find.text('Acceleration · g').first, 100);
      expect(find.text('Angular velocity · °/s'), findsWidgets);
      await tester.scrollUntilVisible(find.text('1200 / 4095'), 200);
      expect(
        find.bySemanticsLabel('Heel pressure ADC reading 1200 out of 4095'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('Heel ADC · last 10 seconds'),
        100,
      );
      expect(
        find.bySemanticsLabel(RegExp('Heel ADC graph.*latest 1200')),
        findsOneWidget,
      );
      semantics.dispose();
    },
  );

  testWidgets('background and route exit stop readings without auto-resume', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: LiveSensorScreen(connection: connection)),
    );
    await connection.connect();
    await tester.runAsync(() => fixtures.emit(fixtures.sample()));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(connection.status, WearableStatus.disconnected);
    expect(connection.latest, isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(connection.status, WearableStatus.disconnected);
    await connection.connect();
    await tester.runAsync(() => fixtures.emit(fixtures.sample()));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(connection.status, WearableStatus.disconnected);
    expect(connection.latest, isNull);
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
