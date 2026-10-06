import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/live_sensor_screen.dart';
import 'package:rehab_monitor/wearable_connection.dart';
import 'wearable_connection_test.dart' as fixtures;

Future<void> expandDisclosure(WidgetTester tester, String label) async {
  await tester.drag(find.byType(ListView), const Offset(0, 3000));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text(label), 150, maxScrolls: 80);
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Finder heelShare(String side, String value) => find.descendant(
  of: find.byKey(ValueKey('heel-${side.toLowerCase()}-share')),
  matching: find.text(value),
);

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

  testWidgets('heel columns show placeholders until readings and after loss', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(home: LiveSensorScreen(connection: connection)),
    );
    await tester.scrollUntilVisible(find.text('No sensors connected'), 100);
    expect(heelShare('Left', '—'), findsOneWidget);
    expect(heelShare('Right', '—'), findsOneWidget);
    expect(find.bySemanticsLabel('Left unavailable'), findsOneWidget);
    await connection.connect();
    await tester.runAsync(
      () => fixtures.emit(
        fixtures.sample()
          ..['fsr_left'] = 800
          ..['analytics'] = (fixtures.analytics()
            ..['heel_share_left'] = 40.0
            ..['heel_share_right'] = 60.0),
      ),
    );
    await tester.pump();
    expect(heelShare('Left', '40%'), findsOneWidget);
    expect(heelShare('Right', '60%'), findsOneWidget);
    expect(find.bySemanticsLabel('Right 60%'), findsOneWidget);
    expect(find.text('No sensors connected'), findsNothing);
    await tester.runAsync(() => connection.disconnect());
    await tester.pump();
    expect(heelShare('Left', '—'), findsOneWidget);
    expect(heelShare('Right', '—'), findsOneWidget);
    expect(find.text('No sensors connected'), findsOneWidget);
    expect(heelShare('Left', '0%'), findsNothing);
    semantics.dispose();
  });

  testWidgets(
    'selected exercise keeps shares visible and diagnostics collapsed at 2x text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      Map<dynamic, dynamic>? connectArguments;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fixtures.commands, (call) async {
            if (call.method == 'getExerciseReferences') {
              return <Object>[];
            }
            if (call.method == 'connect') {
              connectArguments = call.arguments as Map;
            }
            return null;
          });
      await tester.pumpWidget(
        MaterialApp(
          home: LiveSensorScreen(connection: connection, exerciseId: 'squat'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('Squat')),
        findsOneWidget,
      );
      expect(find.text('Calibration & setup'), findsNothing);
      expect(find.text('Open Wi-Fi settings'), findsNothing);
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Connect wearable'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Connect wearable'));
      await tester.pump();
      expect(connectArguments?['scaleConfirmed'], isTrue);
      await tester.runAsync(
        () => fixtures.emit(
          fixtures.sample()
            ..['fsr_left'] = 800
            ..['analytics'] = (fixtures.analytics()
              ..['heel_share_left'] = 40.0
              ..['heel_share_right'] = 60.0),
        ),
      );
      await tester.pump();
      expect(find.text('Receiving live sensor readings'), findsNothing);
      expect(find.text('Thigh · MPU 0x69'), findsNothing);
      expect(find.text('Heel ADC · last 10 seconds'), findsNothing);
      await tester.scrollUntilVisible(find.text('Heel signal share'), 100);
      await tester.scrollUntilVisible(heelShare('Left', '40%'), 100);
      expect(heelShare('Right', '60%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(
        () => fixtures.emit(
          fixtures.sample(time: 2)
            ..['fsr_left'] = 0
            ..['analytics'] = (fixtures.analytics()
              ..['heel_share_left'] = 0.0
              ..['heel_share_right'] = 100.0),
        ),
      );
      await tester.pump();
      expect(heelShare('Right', '100%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expandDisclosure(tester, 'Sensor details');
      await tester.scrollUntilVisible(find.text('Thigh · MPU 0x69'), 100);
      expect(find.text('Acceleration · raw counts'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('live ADC shares need no captures and respect invalid signals', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: LiveSensorScreen(connection: connection)),
    );
    await connection.connect();
    var time = 1;
    Future<void> readings(int? left, int right, {String? reason}) async {
      await tester.runAsync(
        () => fixtures.emit(
          Map<String, Object?>.from(fixtures.sample(time: time++))
            ..['fsr_left'] = left
            ..['fsr'] = right
            ..['analytics'] = (fixtures.analytics()
              ..['heel_share_reason'] =
                  reason ?? 'Capture unloaded and loaded heels first'),
        ),
      );
      await tester.pump();
    }

    await readings(800, 1200);
    await tester.scrollUntilVisible(
      heelShare('Left', '40%'),
      100,
      maxScrolls: 80,
    );
    expect(heelShare('Right', '60%'), findsOneWidget);
    expect(find.text('Higher signal: right'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Sensor signal share'), 100);
    expect(find.text('Sensor signal share'), findsOneWidget);
    expect(find.textContaining('4095'), findsNothing);
    expect(find.textContaining('Live FSR readings'), findsNothing);
    await readings(1200, 800);
    expect(heelShare('Left', '60%'), findsOneWidget);
    expect(find.text('Higher signal: left'), findsOneWidget);
    await readings(0, 1000, reason: 'Heel ADC saturated');
    expect(heelShare('Left', '0%'), findsOneWidget);
    expect(heelShare('Right', '100%'), findsOneWidget);
    await readings(0, 0, reason: 'Heel ADC saturated');
    expect(find.text('No heel signal'), findsOneWidget);
    expect(find.textContaining('Higher signal:'), findsNothing);
    await readings(4095, 1000, reason: 'Heel ADC saturated');
    expect(find.text('Sensor limit reached'), findsOneWidget);
    await readings(null, 1000);
    expect(find.text('Left sensor unavailable'), findsOneWidget);
    await readings(800, 1200, reason: 'No load detected');
    await tester.scrollUntilVisible(find.text('No load detected'), 100);
    expect(find.text('No load detected'), findsOneWidget);
    expect(heelShare('Left', '40%'), findsNothing);
    await tester.runAsync(() => connection.disconnect());
    await tester.pump();
    expect(find.textContaining('Live FSR readings'), findsNothing);
  });

  testWidgets('loading estimate follows displayed shares and clears', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: LiveSensorScreen(connection: connection)),
    );
    await connection.connect();
    await tester.runAsync(() => fixtures.emit(fixtures.sample()));
    await tester.pump();
    for (final left in [65.0, 35.0, 50.4]) {
      await tester.runAsync(
        () => fixtures.emit({
          'type': 'analytics',
          'analytics': fixtures.analytics()
            ..['heel_share_left'] = left
            ..['heel_share_right'] = 100 - left,
        }),
      );
      await tester.pump();
      final label = left.round() == 50
          ? 'Equal shares'
          : 'Higher estimate: ${left > 50 ? 'left' : 'right'}';
      await tester.scrollUntilVisible(find.text(label), 100, maxScrolls: 80);
      await tester.scrollUntilVisible(
        heelShare('Left', '${left.round()}%'),
        -100,
        maxScrolls: 80,
      );
      expect(heelShare('Left', '${left.round()}%'), findsOneWidget);
      expect(heelShare('Right', '${100 - left.round()}%'), findsOneWidget);
      expect(find.text(label), findsOneWidget);
    }
    await tester.runAsync(
      () => fixtures.emit({
        'type': 'analytics',
        'analytics': fixtures.analytics()
          ..['heel_share_reason'] = 'No load detected',
      }),
    );
    await tester.pump();
    expect(find.textContaining('Higher estimate:'), findsNothing);
    expect(find.text('Equal shares'), findsNothing);
    await tester.runAsync(() => connection.disconnect());
    await tester.pump();
    expect(find.textContaining('Higher estimate:'), findsNothing);
  });

  testWidgets(
    'thigh-only stream keeps heel comparison and marks shin unavailable',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: LiveSensorScreen(connection: connection)),
      );
      await connection.connect();
      final thighOnly = Map<String, Object?>.from(fixtures.sample())
        ..['shin_accel'] = null
        ..['shin_gyro'] = null
        ..['fsr_left'] = 800
        ..['analytics'] = (fixtures.analytics()
          ..['heel_share_left'] = 40.0
          ..['heel_share_right'] = 60.0);
      await tester.runAsync(() => fixtures.emit(thighOnly));
      await tester.pump();
      await tester.scrollUntilVisible(
        heelShare('Left', '40%'),
        100,
        maxScrolls: 80,
      );
      await expandDisclosure(tester, 'Sensor details');
      await tester.scrollUntilVisible(
        find.text('Sensor readings unavailable in this stream'),
        -200,
        maxScrolls: 80,
      );
      expect(find.text('Shin · MPU 0x68'), findsOneWidget);
      expect(
        find.text('Sensor readings unavailable in this stream'),
        findsOneWidget,
      );
      expect(connection.latest!.shinAccel, isNull);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => fixtures.emit(fixtures.sample(time: 2)));
      await tester.pump();
      expect(connection.latest!.shinAccel, [7, 8, 9]);
      expect(
        find.text('Sensor readings unavailable in this stream'),
        findsNothing,
      );
    },
  );

  testWidgets('dual heels show graphs, bottom shares and unavailable states', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: LiveSensorScreen(connection: connection)),
    );
    await connection.connect();
    await tester.runAsync(
      () => fixtures.emit(
        fixtures.sample()
          ..['fsr_left'] = 800
          ..['analytics'] = (fixtures.analytics()
            ..['heel_share_left'] = 40.0
            ..['heel_share_right'] = 60.0),
      ),
    );
    await tester.pump();
    await expandDisclosure(tester, 'Sensor details');
    await tester.scrollUntilVisible(
      find.text('Left heel ADC · last 10 seconds'),
      200,
      maxScrolls: 80,
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      heelShare('Left', '40%'),
      100,
      maxScrolls: 80,
    );
    expect(heelShare('Right', '60%'), findsOneWidget);
    expect(find.text('Baseline-adjusted signal share'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('4095'), findsNothing);
    await tester.runAsync(
      () => fixtures.emit({
        'type': 'analytics',
        'analytics': fixtures.analytics()
          ..['heel_share_reason'] = 'No load detected',
      }),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('No load detected'),
      200,
      maxScrolls: 80,
    );
    expect(heelShare('Left', '40%'), findsNothing);
    expect(heelShare('Right', '60%'), findsNothing);
    await tester.runAsync(() => connection.disconnect());
    await tester.pump();
    expect(find.text('No load detected'), findsNothing);
    expect(find.textContaining('4095'), findsNothing);
  });

  testWidgets('controls, raw readings and stale data behave honestly', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: LiveSensorScreen(connection: connection)),
    );
    expect(find.text('Live sensors'), findsOneWidget);
    expect(find.text('Connect wearable'), findsOneWidget);
    await expandDisclosure(tester, 'Sensor details');
    await tester.scrollUntilVisible(
      find.text('No readings yet'),
      200,
      maxScrolls: 80,
    );
    expect(find.text('No readings yet'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Connect wearable'),
      -200,
      maxScrolls: 80,
    );
    await tester.tap(find.text('Connect wearable'));
    await tester.pump();
    await tester.runAsync(() => fixtures.emit(fixtures.sample()));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Live'), -200);
    expect(find.text('Live'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Thigh · MPU 0x69'),
      200,
      maxScrolls: 80,
    );
    expect(connection.latest!.fsr, 1200);
    expect(find.textContaining('4095'), findsNothing);
    expect(find.textContaining('raw counts'), findsWidgets);
    expect(find.textContaining('accuracy'), findsNothing);
    await tester.scrollUntilVisible(find.text('Disconnect'), -200);
    await tester.tap(find.text('Disconnect'));
    await tester.pump();
    expect(connection.latest, isNull);
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
            if (call.method == 'connect') {
              arguments = call.arguments as Map<dynamic, dynamic>;
            }
            return null;
          });
      await tester.pumpWidget(
        MaterialApp(home: LiveSensorScreen(connection: connection)),
      );
      await expandDisclosure(tester, 'Calibration & setup');
      await tester.tap(find.text('IMU ranges confirmed'));
      await tester.pump();
      await tester.scrollUntilVisible(find.text('Connect wearable'), -200);
      await tester.tap(find.text('Connect wearable'));
      await tester.pump();
      expect(arguments?['scaleConfirmed'], isTrue);
      final scaled = fixtures.sample()
        ..['scaled'] = true
        ..['thigh_accel'] = [0.2, 0.3, 0.4]
        ..['shin_accel'] = [0.1, 0.2, 0.3];
      await tester.runAsync(() => fixtures.emit(scaled));
      await tester.pump();
      await expandDisclosure(tester, 'Sensor details');
      await tester.scrollUntilVisible(
        find.text('Thigh · MPU 0x69'),
        200,
        maxScrolls: 80,
      );
      expect(find.text('Acceleration · g'), findsWidgets);
      expect(find.text('Angular velocity · °/s'), findsWidgets);
      expect(find.textContaining('4095'), findsNothing);
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
    await tester.pumpAndSettle();
    expect(connection.status, WearableStatus.disconnected);
    expect(connection.latest, isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(connection.status, WearableStatus.disconnected);
    await tester.runAsync(() => connection.connect());
    await tester.runAsync(() => fixtures.emit(fixtures.sample()));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(connection.status, WearableStatus.disconnected);
    expect(connection.latest, isNull);
  });

  for (final duringSession in [false, true]) {
    testWidgets('background preserves native summary: active=$duringSession', (
      tester,
    ) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fixtures.commands, (call) async {
            if (call.method == 'disconnect') {
              final snapshot = fixtures.analytics(
                state: duringSession ? 'interrupted' : 'needs_calibration',
              )..['reason'] = null;
              if (duringSession) snapshot['summary'] = fixtures.summary();
              return jsonEncode(snapshot);
            }
            return null;
          });
      await tester.pumpWidget(
        MaterialApp(home: LiveSensorScreen(connection: connection)),
      );
      await connection.connect();
      await tester.runAsync(
        () => fixtures.emit(
          fixtures.sample()
            ..['analytics'] = fixtures.analytics(
              state: duringSession ? 'active' : 'standing',
              cycles: duringSession ? 2 : null,
            ),
        ),
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(connection.status, WearableStatus.disconnected);
      expect(connection.analytics!.cycles, isNull);
      expect(connection.analytics!.angleDeg, isNull);
      // Resume before scrolling offscreen content; readings stay disconnected.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(connection.status, WearableStatus.disconnected);
      await expandDisclosure(tester, 'Calibration & setup');
      await tester.scrollUntilVisible(
        find.text('Start session'),
        200,
        maxScrolls: 80,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Start session'),
            )
            .onPressed,
        isNull,
      );
      if (duringSession) {
        await tester.scrollUntilVisible(
          find.text('Interrupted session summary'),
          200,
          maxScrolls: 80,
        );
        expect(find.text('2 completed cycles'), findsOneWidget);
        expect(connection.analytics!.summary!.interrupted, isTrue);
      } else {
        expect(connection.analytics!.summary, isNull);
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(connection.status, WearableStatus.disconnected);
    });
  }

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
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Connect wearable'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Connect wearable'));
      await tester.pump();
      await tester.runAsync(
        () => fixtures.emit(
          fixtures.sample()
            ..['fsr_left'] = 800
            ..['analytics'] = (fixtures.analytics()
              ..['heel_share_left'] = 40.0
              ..['heel_share_right'] = 60.0),
        ),
      );
      await tester.pump();
      expect(connection.status, WearableStatus.live);
      await expandDisclosure(tester, 'Sensor details');
      await tester.scrollUntilVisible(
        find.text('Left heel ADC · last 10 seconds'),
        200,
        maxScrolls: 80,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
