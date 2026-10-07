import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/exercise_reference.dart';
import 'package:rehab_monitor/wearable_connection.dart';
import 'package:rehab_monitor/workout_session.dart';
import 'package:rehab_monitor/workout_session_screen.dart';
import 'package:rehab_monitor/thigh_session_panel.dart';
import 'wearable_connection_test.dart' as fixtures;

void main() {
  late WorkoutSessionController owner;
  late WearableConnection connection;
  var time = 0;
  var failSave = false;
  var failEnd = false;
  var nativeStops = 0;
  Map<String, dynamic>? disconnectSnapshot;
  late List<String> actions;
  late List<Map<String, dynamic>> writes;
  final reference = ExerciseReference(
    exerciseId: 'squat',
    peakDeg: 50,
    bendThresholdDeg: 30,
    uprightBandDeg: 7,
    recordedAt: '2026-10-06T00:00:00.000Z',
  );

  Map<String, dynamic> thigh(
    String state, {
    int reps = 0,
    bool result = false,
    String outcome = 'target_reached',
    String? reason,
  }) => {
    'state': state,
    'exercise_id': 'squat',
    'reason': reason,
    'zero_progress': 0.0,
    'tilt_deg': null,
    'reference_peak_deg': 50.0,
    'recorded_peak_deg': null,
    'latest_peak_deg': reps > 0 ? 45.0 : null,
    'difference_deg': reps > 0 ? -5.0 : null,
    'repetitions': reps,
    'result': result
        ? {
            'repetitions': reps,
            'rep_target': 2,
            'active_s': 12.0,
            'latest_peak_deg': 45.0,
            'reference_peak_deg': 50.0,
            'difference_deg': -5.0,
            'outcome': outcome,
          }
        : null,
  };
  Future<void> send(Map<String, dynamic> snapshot) => fixtures.emit(
    fixtures.sample(time: ++time)
      ..['analytics'] = (fixtures.analytics()..['thigh'] = snapshot),
  );

  setUp(() {
    time = 0;
    failSave = false;
    failEnd = false;
    nativeStops = 0;
    disconnectSnapshot = null;
    actions = [];
    writes = [];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('rehab/wearable/events'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(fixtures.commands, (call) async {
      if (call.method == 'getSettings') {
        return {'injured_leg': 'left', 'heel_zero': null};
      }
      if (call.method == 'getExerciseReferences') return [reference.toJson()];
      if (call.method == 'saveWorkoutSession') {
        if (failSave) throw PlatformException(code: 'save_failed');
        writes.add(Map<String, dynamic>.from(call.arguments as Map));
        return call.arguments;
      }
      if (call.method == 'sessionCommand') {
        final action = (call.arguments as Map)['action'] as String;
        actions.add(action);
        if (action == 'thigh_session_begin') await send(thigh('zeroing'));
        if (action == 'thigh_session_end') {
          if (failEnd) throw PlatformException(code: 'end_failed');
          await send(
            thigh('ended', reps: 1, result: true, outcome: 'ended_early'),
          );
        }
      }
      if (call.method == 'disconnect') {
        nativeStops++;
        if (disconnectSnapshot != null) return jsonEncode(disconnectSnapshot);
      }
      return null;
    });
    connection = WearableConnection(android: true);
    owner = WorkoutSessionController(
      connection: connection,
      targets: {'squat': 2, 'sit_to_stand': 3},
    );
  });

  Future<void> openActiveExercise(WidgetTester tester) async {
    await tester.runAsync(() async {
      await owner.start();
      await connection.connect();
      await send(thigh('idle'));
    });
    await tester.pumpWidget(
      MaterialApp(home: WorkoutSessionScreen(controller: owner)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Squat'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Start exercise'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Start exercise'));
    });
    await tester.pump();
    await tester.runAsync(() => send(thigh('active', reps: 1)));
    await tester.pump();
  }

  for (final firstEndFails in [false, true]) {
    testWidgets(
      'active Back saves early result before returning: endFails=$firstEndFails',
      (tester) async {
        await openActiveExercise(tester);
        failEnd = firstEndFails;
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('End exercise early?'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.widgetWithText(FilledButton, 'End exercise'));
        });
        await tester.pumpAndSettle();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        if (firstEndFails) {
          expect(owner.hasAttempt, isTrue);
          expect(owner.record!.exercises, isEmpty);
          expect(find.text('Choose an exercise'), findsNothing);
          expect(writes.length, 1);
          failEnd = false;
          await tester.pageBack();
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await tester.tap(find.widgetWithText(FilledButton, 'End exercise'));
          });
          await tester.pumpAndSettle();
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pumpAndSettle();
        }
        expect(owner.record!.exercises.single.result.outcome, 'ended_early');
        expect(owner.record!.exercises.single.result.repetitions, 1);
        expect(owner.hasAttempt, isFalse);
        expect(writes.length, 2);
        expect(connection.active, isTrue);
        expect(
          actions.where((action) => action == 'thigh_session_end').length,
          firstEndFails ? 2 : 1,
        );
        expect(find.text('Choose an exercise'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('backgrounding managed child persists interrupted result once', (
    tester,
  ) async {
    await openActiveExercise(tester);
    disconnectSnapshot = fixtures.analytics()
      ..['thigh'] = thigh(
        'interrupted',
        reps: 1,
        result: true,
        outcome: 'interrupted',
      );
    await tester.runAsync(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(owner.record!.exercises.single.result.outcome, 'interrupted');
    expect(owner.record!.exercises.single.result.repetitions, 1);
    expect(owner.hasAttempt, isFalse);
    expect(writes.length, 2);
    expect(connection.status, WearableStatus.disconnected);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(connection.status, WearableStatus.disconnected);
    expect(
      actions.where((action) => action == 'thigh_session_begin').length,
      1,
    );
    expect(writes.length, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'sample gap saves interrupted reps once while transport stays live',
    (tester) async {
      await openActiveExercise(tester);
      await tester.pumpWidget(
        MaterialApp(home: WorkoutSessionScreen(controller: owner)),
      );
      await tester.pump();
      expect(nativeStops, 0);
      const reason = 'Device sample gap 2702 ms; repeat calibration.';
      final interrupted = thigh(
        'interrupted',
        reps: 1,
        result: true,
        outcome: 'interrupted',
        reason: reason,
      );
      await tester.runAsync(() => send(interrupted));
      await tester.pumpAndSettle();
      await tester.runAsync(() => send(interrupted));
      await tester.pumpAndSettle();
      expect(connection.status, WearableStatus.live);
      expect(nativeStops, 0);
      expect(find.text(reason), findsOneWidget);
      expect(owner.record!.exercises.single.result.repetitions, 1);
      expect(owner.record!.exercises.single.result.outcome, 'interrupted');
      expect(owner.hasAttempt, isFalse);
      expect(writes.length, 2);
      await tester.ensureVisible(find.text('Return to session'));
      await tester.tap(find.text('Return to session'));
      await tester.pumpAndSettle();
      expect(find.text('Choose an exercise'), findsOneWidget);
      expect(connection.status, WearableStatus.live);
      expect(nativeStops, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'target completion freezes UI and returns to next exercise or end session',
    (tester) async {
      await tester.runAsync(() async {
        await owner.start();
        await connection.connect();
        await send(thigh('idle'));
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => WorkoutSessionScreen(controller: owner),
                  ),
                ),
                child: const Text('Open session'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open session'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Squat'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Start exercise'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Start exercise'));
      });
      await tester.pump();
      await tester.runAsync(() => send(thigh('active')));
      await tester.pump();
      failSave = true;
      await tester.runAsync(() => send(thigh('ended', reps: 2, result: true)));
      await tester.pump();
      await tester.ensureVisible(find.text('Exercise completed'));
      expect(find.text('Exercise completed'), findsOneWidget);
      expect(find.text('Start exercise'), findsNothing);
      expect(find.text('2 / 2'), findsOneWidget);
      expect(owner.canChoose, isFalse);
      failSave = false;
      await tester.ensureVisible(find.text('Retry saving'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Retry saving'));
      });
      await tester.pump();
      await tester.scrollUntilVisible(find.text('Return to session'), 200);
      await tester.tap(find.text('Return to session'));
      await tester.pumpAndSettle();
      expect(find.text('Choose an exercise'), findsOneWidget);
      expect(find.text('Sit-to-stand'), findsOneWidget);
      expect(owner.record!.exercises.length, 1);
      expect(connection.active, isTrue);
      failSave = true;
      await tester.scrollUntilVisible(find.text('End session'), 200);
      await tester.runAsync(() async {
        await tester.tap(find.text('End session'));
      });
      await tester.pumpAndSettle();
      expect(owner.needsRetry, isTrue);
      expect(owner.record!.status, 'active');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Choose an exercise'), findsOneWidget);
      failSave = false;
      await tester.ensureVisible(find.text('Retry saving'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Retry saving'));
      });
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Open session'), findsOneWidget);
      expect(writes.last['status'], 'ended');
      expect(actions.where((a) => a == 'thigh_session_begin').length, 1);
    },
  );

  testWidgets('maximum repetition target fits narrow screen at large text', (
    tester,
  ) async {
    owner.dispose();
    owner = WorkoutSessionController(
      connection: connection,
      targets: {'squat': 1000, 'sit_to_stand': 1000},
    );
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.runAsync(() async {
      await owner.start();
      await connection.connect();
      await send(thigh('idle'));
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              ThighSessionPanel(
                connection: connection,
                exerciseId: 'squat',
                workout: owner,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Start exercise'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Start exercise'));
    });
    await tester.pump();
    await tester.runAsync(() => send(thigh('active', reps: 1000)));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('1000 / 1000'), 100);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    owner.dispose();
    connection.dispose();
  });
}
