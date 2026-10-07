import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/exercise_reference.dart';
import 'package:rehab_monitor/wearable_connection.dart';
import 'package:rehab_monitor/workout_session.dart';

import 'wearable_connection_test.dart' as fixtures;

Map<String, dynamic> workoutFixture() => {
  'id': 'session_1',
  'started_at': '2026-10-06T08:00:00.000Z',
  'ended_at': '2026-10-06T08:10:00.000Z',
  'status': 'ended',
  'exercises': [
    {
      'id': 'attempt_1',
      'exercise_id': 'squat',
      'started_at': '2026-10-06T08:01:00.000Z',
      'ended_at': '2026-10-06T08:02:00.000Z',
      'result': {
        'repetitions': 2,
        'rep_target': 2,
        'active_s': 12.5,
        'latest_peak_deg': 45.0,
        'reference_peak_deg': 50.0,
        'difference_deg': -5.0,
        'outcome': 'target_reached',
      },
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'workout round trip preserves actual exercise results and rejects duplicates',
    () {
      final json = workoutFixture();
      final record = WorkoutSession.fromJson(json);
      expect(record.toJson(), json);
      expect(record.totalReps, 2);
      json['exercises'] = [json['exercises'][0], json['exercises'][0]];
      expect(() => WorkoutSession.fromJson(json), throwsFormatException);
    },
  );
  test('invalid dates, status and targets cannot become saved history', () {
    final invalid = workoutFixture()..['ended_at'] = '2026-10-05T08:00:00.000Z';
    expect(() => WorkoutSession.fromJson(invalid), throwsFormatException);
    invalid['ended_at'] = '2026-10-06T08:10:00.000Z';
    invalid['status'] = 'active';
    expect(() => WorkoutSession.fromJson(invalid), throwsFormatException);
    final target = workoutFixture();
    target['exercises'][0]['result']['rep_target'] = 0;
    expect(() => WorkoutSession.fromJson(target), throwsFormatException);
  });
  test('store retry upserts the same stable session identity', () async {
    const channel = MethodChannel('test/workouts');
    final saved = <String, dynamic>{};
    var fail = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getWorkoutSessions') return saved.values.toList();
          if (fail) throw PlatformException(code: 'storage_failed');
          final row = Map<String, dynamic>.from(call.arguments as Map);
          saved[row['id'] as String] = row;
          return row;
        });
    final store = WorkoutSessionStore(channel: channel);
    final record = WorkoutSession.fromJson(workoutFixture());
    await expectLater(store.save(record), throwsA(isA<PlatformException>()));
    fail = false;
    await store.save(record);
    await store.save(record);
    expect((await store.load()).length, 1);
    expect(saved.keys.single, 'session_1');
  });

  test('store rejects malformed rows and changed saved identity', () async {
    const channel = MethodChannel('test/workout-invalid-response');
    dynamic response;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => response);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final store = WorkoutSessionStore(channel: channel);
    final record = WorkoutSession.fromJson(workoutFixture());
    for (final invalid in [
      null,
      [1],
      [<String, dynamic>{}],
    ]) {
      response = invalid;
      await expectLater(store.load(), throwsFormatException);
    }
    for (final invalid in [
      null,
      <String, dynamic>{},
      workoutFixture()..['id'] = 'other-session',
    ]) {
      response = invalid;
      await expectLater(store.save(record), throwsFormatException);
    }
  });

  group('workout controller', () {
    const storage = MethodChannel('test/workout-controller');
    late WearableConnection connection;
    late WorkoutSessionController controller;
    late List<Map<String, dynamic>> writes;
    late Map<String, Map<String, dynamic>> saved;
    late List<Map<String, dynamic>> begins;
    Map<String, dynamic>? disconnectSnapshot;
    Completer<void>? beginAckGate;
    bool saveFails = false;
    int time = 0;

    ExerciseReference reference(String id) => ExerciseReference(
      exerciseId: id,
      peakDeg: 50,
      bendThresholdDeg: 30,
      uprightBandDeg: 7.5,
      recordedAt: '2026-10-06T00:00:00.000Z',
    );

    Map<String, dynamic> result({
      int repetitions = 2,
      int target = 2,
      String outcome = 'target_reached',
    }) => {
      'repetitions': repetitions,
      'rep_target': target,
      'active_s': 12.5,
      'latest_peak_deg': repetitions == 0 ? null : 45.0,
      'reference_peak_deg': 50.0,
      'difference_deg': repetitions == 0 ? null : -5.0,
      'outcome': outcome,
    };

    Map<String, dynamic> analytics(
      String state, {
      String? exerciseId = 'squat',
      Map<String, dynamic>? frozen,
    }) => fixtures.analytics()
      ..['thigh'] = {
        'state': state,
        'exercise_id': exerciseId,
        'reason': null,
        'zero_progress': state == 'zeroing' ? 0.5 : 1.0,
        'tilt_deg': null,
        'reference_peak_deg': 50.0,
        'recorded_peak_deg': null,
        'latest_peak_deg': frozen?['latest_peak_deg'],
        'difference_deg': frozen?['difference_deg'],
        'repetitions': frozen?['repetitions'] ?? 0,
        'result': frozen,
      };

    Future<void> emit(
      String state, {
      String? exerciseId = 'squat',
      Map<String, dynamic>? frozen,
    }) => fixtures.emit(
      fixtures.sample(time: ++time)
        ..['analytics'] = analytics(
          state,
          exerciseId: exerciseId,
          frozen: frozen,
        ),
    );

    Future<void> snapshot(
      WidgetTester tester,
      String state, {
      String exerciseId = 'squat',
      Map<String, dynamic>? frozen,
    }) async {
      await tester.runAsync(
        () => emit(state, exerciseId: exerciseId, frozen: frozen),
      );
      await tester.pump();
    }

    Future<void> ready(WidgetTester tester) async {
      await tester.runAsync(connection.connect);
      await snapshot(tester, 'idle');
    }

    setUp(() {
      writes = [];
      saved = {};
      begins = [];
      time = 0;
      saveFails = false;
      disconnectSnapshot = null;
      beginAckGate = null;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(fixtures.commands, (call) async {
        if (call.method == 'disconnect') {
          return disconnectSnapshot == null
              ? null
              : jsonEncode(disconnectSnapshot);
        }
        if (call.method == 'sessionCommand') {
          final command = Map<String, dynamic>.from(call.arguments as Map);
          if (command['action'] == 'thigh_session_begin') {
            final config = Map<String, dynamic>.from(command['config'] as Map);
            begins.add(config);
            await emit('zeroing', exerciseId: config['exercise_id'] as String);
            if (beginAckGate != null) await beginAckGate!.future;
          } else if (command['action'] == 'thigh_cancel') {
            await emit('idle', exerciseId: null);
          }
        }
        return null;
      });
      messenger.setMockMethodCallHandler(
        const MethodChannel('rehab/wearable/events'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(storage, (call) async {
        if (call.method == 'getWorkoutSessions') return saved.values.toList();
        final row = Map<String, dynamic>.from(call.arguments as Map);
        writes.add(row);
        if (saveFails) throw PlatformException(code: 'storage_failed');
        saved[row['id'] as String] = row;
        return row;
      });
      connection = WearableConnection(android: true);
      controller = WorkoutSessionController(
        connection: connection,
        targets: {'squat': 2, 'sit_to_stand': 3},
        store: const WorkoutSessionStore(channel: storage),
      );
    });

    tearDown(() {
      controller.dispose();
      connection.dispose();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(storage, null);
      messenger.setMockMethodCallHandler(fixtures.commands, null);
      messenger.setMockMethodCallHandler(
        const MethodChannel('rehab/wearable/events'),
        null,
      );
    });

    testWidgets('failed creation retries the same session before choosing', (
      tester,
    ) async {
      saveFails = true;
      expect(await tester.runAsync(controller.start), isFalse);
      final pending = controller.preview!.toJson();
      expect(controller.record, isNull);
      expect(controller.needsRetry, isTrue);
      expect(controller.canChoose, isFalse);
      expect(
        await controller.beginExercise('squat', reference('squat')),
        isFalse,
      );
      saveFails = false;
      expect(await tester.runAsync(controller.retry), isTrue);
      expect(writes, [pending, pending]);
      expect(saved.keys.single, pending['id']);
      expect(controller.canChoose, isTrue);
      expect(controller.error, isNull);
    });

    testWidgets('sequential target completions save once and retain targets', (
      tester,
    ) async {
      await ready(tester);
      expect(await tester.runAsync(controller.start), isTrue);
      expect(
        await tester.runAsync(
          () => controller.beginExercise('squat', reference('squat')),
        ),
        isTrue,
      );
      expect(controller.hasAttempt, isTrue);
      expect(controller.canChoose, isFalse);
      expect(
        await controller.beginExercise(
          'sit_to_stand',
          reference('sit_to_stand'),
        ),
        isFalse,
      );
      await snapshot(tester, 'active');
      await snapshot(tester, 'ended', frozen: result());
      final first = controller.record!.exercises.single;
      expect(first.result.repetitions, 2);
      expect(first.result.repTarget, 2);
      expect(controller.canChoose, isTrue);
      await snapshot(tester, 'ended', frozen: result());
      expect(writes.length, 2);
      expect(controller.record!.exercises.length, 1);
      expect(
        await tester.runAsync(
          () => controller.beginExercise(
            'sit_to_stand',
            reference('sit_to_stand'),
          ),
        ),
        isTrue,
      );
      await snapshot(tester, 'active', exerciseId: 'sit_to_stand');
      await snapshot(
        tester,
        'ended',
        exerciseId: 'sit_to_stand',
        frozen: result(repetitions: 3, target: 3),
      );
      expect(controller.record!.exercises.map((item) => item.exerciseId), [
        'squat',
        'sit_to_stand',
      ]);
      expect(controller.record!.exercises.last.id, isNot(first.id));
      expect(begins.map((config) => config['rep_target']), [2, 3]);
      expect(await tester.runAsync(controller.finish), isTrue);
      expect(controller.record!.status, 'ended');
      expect(controller.record!.totalReps, 5);
      expect(saved.length, 1);
      expect(writes.length, 4);
    });

    testWidgets('failed result save retains the exact attempt for retry', (
      tester,
    ) async {
      await ready(tester);
      await tester.runAsync(controller.start);
      await tester.runAsync(
        () => controller.beginExercise('squat', reference('squat')),
      );
      await snapshot(tester, 'active');
      saveFails = true;
      await snapshot(tester, 'ended', frozen: result());
      final pending = controller.preview!.toJson();
      expect(controller.record!.exercises, isEmpty);
      expect(controller.preview!.exercises.single.result.repetitions, 2);
      expect(controller.hasAttempt, isTrue);
      expect(controller.needsRetry, isTrue);
      expect(controller.canChoose, isFalse);
      expect(await controller.finish(), isFalse);
      await snapshot(tester, 'ended', frozen: result());
      expect(writes.length, 2);
      saveFails = false;
      expect(await tester.runAsync(controller.retry), isTrue);
      expect(writes.last, pending);
      expect(
        controller.record!.exercises.single.id,
        pending['exercises'][0]['id'],
      );
      expect(controller.hasAttempt, isFalse);
      await snapshot(tester, 'ended', frozen: result());
      expect(writes.length, 3);
      expect(saved.length, 1);
    });

    testWidgets('natural disconnect during zero discards no invented result', (
      tester,
    ) async {
      await ready(tester);
      await tester.runAsync(controller.start);
      await tester.runAsync(
        () => controller.beginExercise('squat', reference('squat')),
      );
      await tester.runAsync(
        () => fixtures.emit({
          'type': 'status',
          'status': 'disconnected',
          'message': 'Connection lost during zero',
        }),
      );
      await tester.pump();
      expect(controller.hasAttempt, isFalse);
      expect(controller.record!.exercises, isEmpty);
      expect(writes.length, 1);
      expect(await tester.runAsync(controller.finish), isTrue);
      expect(controller.record!.exercises, isEmpty);
    });

    testWidgets(
      'zero cancellation accepts the native idle snapshot without an exercise ID',
      (tester) async {
        await ready(tester);
        await tester.runAsync(controller.start);
        await tester.runAsync(
          () => controller.beginExercise('squat', reference('squat')),
        );
        expect(await tester.runAsync(controller.endExercise), isTrue);
        expect(connection.thigh!.state, 'idle');
        expect(connection.thigh!.exerciseId, isNull);
        expect(controller.hasAttempt, isFalse);
        expect(controller.canChoose, isTrue);
        expect(controller.record!.exercises, isEmpty);
        expect(writes.length, 1);
      },
    );

    testWidgets('ending waits for the pending begin acknowledgement', (
      tester,
    ) async {
      await ready(tester);
      await tester.runAsync(controller.start);
      beginAckGate = Completer<void>();
      late Future<bool> begin;
      await tester.runAsync(() async {
        begin = controller.beginExercise('squat', reference('squat'));
        await Future<void>.delayed(Duration.zero);
      });
      expect(connection.commandPending, isTrue);
      expect(controller.hasAttempt, isTrue);
      expect(await tester.runAsync(controller.endExercise), isFalse);
      expect(controller.hasAttempt, isTrue);
      expect(writes.length, 1);
      beginAckGate!.complete();
      expect(await tester.runAsync(() => begin), isTrue);
      expect(connection.commandPending, isFalse);
      expect(await tester.runAsync(controller.endExercise), isTrue);
      expect(controller.hasAttempt, isFalse);
      expect(controller.record!.exercises, isEmpty);
    });

    testWidgets('disconnect acknowledgement persists actual interrupted reps', (
      tester,
    ) async {
      await ready(tester);
      await tester.runAsync(controller.start);
      await tester.runAsync(
        () => controller.beginExercise('squat', reference('squat')),
      );
      await snapshot(tester, 'active');
      final frozen = result(repetitions: 1, outcome: 'interrupted');
      disconnectSnapshot = analytics('interrupted', frozen: frozen);
      await tester.runAsync(controller.interrupt);
      expect(connection.status, WearableStatus.disconnected);
      expect(controller.hasAttempt, isFalse);
      expect(controller.record!.exercises.single.result.toJson(), frozen);
      expect(controller.record!.exercises.single.result.outcome, 'interrupted');
      expect(writes.length, 2);
      expect(await tester.runAsync(controller.finish), isTrue);
      expect(controller.record!.totalReps, 1);
    });
  });
}
