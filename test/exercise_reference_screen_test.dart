import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/exercise_reference.dart';
import 'package:rehab_monitor/exercise_reference_screen.dart';
import 'package:rehab_monitor/thigh_session_panel.dart';
import 'package:rehab_monitor/wearable_connection.dart';

import 'wearable_connection_test.dart' as fixtures;

void main() {
  const storageChannel = MethodChannel('test/exercise-references');
  late WearableConnection connection;
  late ExerciseReferenceStore store;
  late List<Map<String, dynamic>> records;
  late List<MethodCall> commands;
  bool saveFails = false;
  int time = 0;

  Map<String, dynamic> reference(double peak) => ExerciseReference(
    exerciseId: 'squat',
    peakDeg: peak,
    bendThresholdDeg: .6 * peak,
    uprightBandDeg: (.15 * peak).clamp(5.0, 10.0),
    recordedAt: '2026-10-06T00:00:00.000Z',
  ).toJson();

  setUp(() {
    commands = [];
    records = [reference(45)];
    saveFails = false;
    time = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fixtures.commands, (call) async {
      commands.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('rehab/wearable/events'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      if (call.method == 'getExerciseReferences') return records;
      if (saveFails) throw PlatformException(code: 'save_failed');
      final saved = Map<String, dynamic>.from(call.arguments as Map);
      records = [saved];
      return saved;
    });
    connection = WearableConnection(android: true);
    store = ExerciseReferenceStore(channel: storageChannel);
  });
  tearDown(() {
    connection.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, null);
  });

  Future<void> snapshot(
    WidgetTester tester,
    String state, {
    double progress = 0,
    double? peak,
    double? latest,
    double? difference,
    int repetitions = 0,
    String exerciseId = 'squat',
    double? tilt,
    String? reason,
  }) async {
    await tester.runAsync(
      () => fixtures.emit(
        fixtures.sample(time: ++time)
          ..['analytics'] = (fixtures.analytics()
            ..['thigh'] = {
              'state': state,
              'exercise_id': exerciseId,
              'reason': reason,
              'zero_progress': progress,
              'tilt_deg': tilt,
              'reference_peak_deg': 45.0,
              'recorded_peak_deg': peak,
              'latest_peak_deg': latest,
              'difference_deg': difference,
              'repetitions': repetitions,
            }),
      ),
    );
    await tester.pump();
  }

  Future<void> showReference(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ExerciseReferenceScreen(
          exerciseId: 'squat',
          connection: connection,
          store: store,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await connection.connect();
    await snapshot(tester, 'idle');
  }

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(find.text(label), 100, maxScrolls: 80);
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'live missing thigh readings can disconnect and reconnect registration',
    (tester) async {
      await showReference(tester);
      await tester.runAsync(
        () => fixtures.emit(
          Map<String, dynamic>.from(fixtures.sample(time: ++time))
            ..['thigh_accel'] = null
            ..['thigh_gyro'] = null,
        ),
      );
      await tester.pumpAndSettle();
      expect(connection.status, WearableStatus.live);
      await tester.ensureVisible(find.text('Disconnect wearable'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Disconnect wearable'));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(commands.last.method, 'disconnect');
      expect(records.single['reference_peak_deg'], 45);
      expect(find.text('Connect wearable'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Connect wearable'));
        await Future<void>.delayed(Duration.zero);
      });
      await snapshot(tester, 'idle');
      expect(connection.status, WearableStatus.live);
      await tap(tester, 'Re-record reference');
      expect(
        (commands.last.arguments as Map)['action'],
        'thigh_reference_begin',
      );
    },
  );

  testWidgets(
    'recording previews and saves deliberately; failed replacement preserves target',
    (tester) async {
      await showReference(tester);
      expect(find.text('Saved reference: 45.0°'), findsOneWidget);
      await tap(tester, 'Re-record reference');
      expect(
        (commands.last.arguments as Map)['action'],
        'thigh_reference_begin',
      );
      await snapshot(tester, 'reference_ready', peak: 60);
      await tester.scrollUntilVisible(find.text('Recorded range: 60.0°'), 100);
      expect(records.single['reference_peak_deg'], 45);
      saveFails = true;
      await tap(tester, 'Save reference');
      expect(records.single['reference_peak_deg'], 45);
      expect(find.textContaining('Previous reference kept'), findsOneWidget);
      saveFails = false;
      await tap(tester, 'Save reference');
      expect(records.single['reference_peak_deg'], 60);
      expect(records.single['bend_threshold_deg'], 36);
      expect(records.single['upright_band_deg'], 9);
      expect(find.text('Reference saved'), findsOneWidget);
    },
  );

  testWidgets(
    'short zeroing gap resets Register countdown without another begin',
    (tester) async {
      await showReference(tester);
      await tap(tester, 'Re-record reference');
      await snapshot(tester, 'zeroing', progress: .8);
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);
      const reason =
          'Readings paused; return upright and hold still to continue.';
      await snapshot(tester, 'zeroing', reason: reason);
      await tester.pumpAndSettle();
      expect(find.text('3'), findsOneWidget);
      expect(find.text(reason), findsOneWidget);
      expect(find.text('Re-record reference'), findsNothing);
      expect(connection.status, WearableStatus.live);
      expect(records.single['reference_peak_deg'], 45);

      await snapshot(tester, 'zeroing', progress: .4);
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      expect(find.text(reason), findsNothing);
      await snapshot(tester, 'recording', tilt: 0);
      await tester.pumpAndSettle();
      expect(find.text('Finish recording'), findsOneWidget);
      await snapshot(tester, 'recording', reason: reason);
      expect(find.text(reason), findsOneWidget);
      expect(find.textContaining('Zero set. Bend'), findsNothing);
      expect(find.text('Re-record reference'), findsNothing);
      await snapshot(tester, 'recording', tilt: 0);
      expect(find.text(reason), findsNothing);
      expect(find.textContaining('Zero set. Bend'), findsOneWidget);
      expect(connection.thigh!.state, 'recording');
      expect(connection.status, WearableStatus.live);
      expect(records.single['reference_peak_deg'], 45);
      expect(
        commands.where((call) => call.method == 'sessionCommand').length,
        1,
      );
      expect(commands.where((call) => call.method == 'disconnect'), isEmpty);
    },
  );

  testWidgets(
    'hard sample gap keeps reference and live connection ready for fresh recording',
    (tester) async {
      await showReference(tester);
      await tap(tester, 'Re-record reference');
      await snapshot(tester, 'recording', tilt: 35);
      const reason = 'Device sample gap 2702 ms; repeat calibration.';
      await snapshot(tester, 'interrupted', reason: reason);
      expect(connection.status, WearableStatus.live);
      expect(records.single['reference_peak_deg'], 45);
      expect(find.text(reason), findsOneWidget);
      expect(find.text('Finish recording'), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          home: ExerciseReferenceScreen(
            exerciseId: 'squat',
            connection: connection,
            store: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, 'Re-record reference');
      expect(
        commands
            .where(
              (call) =>
                  call.method == 'sessionCommand' &&
                  (call.arguments as Map)['action'] == 'thigh_reference_begin',
            )
            .length,
        2,
      );
      await snapshot(tester, 'zeroing', progress: .4);
      await snapshot(tester, 'recording', tilt: 0, peak: 60);
      await tap(tester, 'Finish recording');
      expect(records.single['reference_peak_deg'], 45);
      await snapshot(tester, 'reference_ready', peak: 60);
      await tap(tester, 'Save reference');
      expect(records.single['reference_peak_deg'], 60);
      expect(connection.status, WearableStatus.live);
      expect(commands.where((call) => call.method == 'disconnect'), isEmpty);
    },
  );

  testWidgets(
    'cancelled recording preserves reference and route exit disconnects',
    (tester) async {
      await showReference(tester);
      await snapshot(tester, 'reference_ready', peak: 60);
      await tap(tester, 'Cancel recording');
      expect((commands.last.arguments as Map)['action'], 'thigh_cancel');
      expect(records.single['reference_peak_deg'], 45);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      expect(connection.latest, isNull);
      expect(commands.last.method, 'disconnect');
    },
  );

  testWidgets(
    'session uses saved reference; zero succeeds only from processor state',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ThighSessionPanel(
                  connection: connection,
                  exerciseId: 'squat',
                  store: store,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await connection.connect();
      await snapshot(tester, 'idle');
      await tap(tester, 'Start exercise');
      final config = (commands.last.arguments as Map)['config'] as Map;
      expect(config['exercise_id'], 'squat');
      expect((config['reference'] as Map)['reference_peak_deg'], 45);
      await snapshot(tester, 'zeroing', progress: 0);
      expect(find.text('3'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('Zero set. Begin your exercise.'), findsNothing);
      await snapshot(tester, 'zeroing', progress: .4);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('2'), findsOneWidget);
      await snapshot(tester, 'zeroing', progress: 1);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('1'), findsOneWidget);
      expect(find.text('Zero set. Begin your exercise.'), findsNothing);
      await snapshot(
        tester,
        'active',
        latest: 50,
        difference: 5,
        repetitions: 1,
      );
      expect(find.text('Zero set. Begin your exercise.'), findsOneWidget);
      const recovery = 'Stand upright and hold still to continue.';
      await snapshot(tester, 'active', reason: recovery, repetitions: 1);
      expect(find.text(recovery), findsOneWidget);
      expect(find.text('Zero set. Begin your exercise.'), findsNothing);
      await snapshot(
        tester,
        'active',
        latest: 50,
        difference: 5,
        repetitions: 1,
      );
      expect(find.text(recovery), findsNothing);
      expect(find.text('Zero set. Begin your exercise.'), findsOneWidget);
      expect(find.text('Repetitions'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('Latest range'), findsOneWidget);
      expect(find.text('50.0°'), findsOneWidget);
      expect(find.text('Reference difference'), findsOneWidget);
      expect(find.text('5.0°'), findsOneWidget);
      expect(find.text('Edit exercise reference'), findsNothing);
    },
  );

  for (final exerciseId in exerciseNames.keys) {
    testWidgets('$exerciseId recorder shows actual movement and gates Finish', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ExerciseReferenceScreen(
            exerciseId: exerciseId,
            connection: connection,
            store: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await connection.connect();
      await snapshot(tester, 'recording', exerciseId: exerciseId);
      await tester.scrollUntilVisible(find.text('Finish recording'), 100);
      FilledButton finish() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Finish recording'),
      );
      expect(find.text('Thigh tilt: —'), findsOneWidget);
      expect(find.text('Captured range: —'), findsOneWidget);
      expect(
        find.text(
          'Zero set. Bend at least 30°, pause briefly, then return standing and hold still briefly.',
        ),
        findsOneWidget,
      );
      expect(finish().onPressed, isNull);
      await snapshot(tester, 'recording', exerciseId: exerciseId, tilt: 35);
      expect(find.text('Thigh tilt: 35.0°'), findsOneWidget);
      expect(finish().onPressed, isNull);
      await snapshot(
        tester,
        'recording',
        exerciseId: exerciseId,
        tilt: 15,
        peak: 50,
      );
      expect(find.text('Captured range: 50.0°'), findsOneWidget);
      expect(find.text('Movement captured. Return standing.'), findsOneWidget);
      expect(finish().onPressed, isNull);
      await snapshot(
        tester,
        'recording',
        exerciseId: exerciseId,
        tilt: 10,
        peak: 50,
      );
      expect(find.text('Movement captured. Ready to finish.'), findsOneWidget);
      expect(finish().onPressed, isNotNull);
      await snapshot(tester, 'recording', exerciseId: exerciseId, peak: 50);
      expect(finish().onPressed, isNull);
      await snapshot(
        tester,
        'recording',
        exerciseId: exerciseId,
        tilt: 0,
        reason: 'Short sample gap; stand upright to recover.',
      );
      expect(find.text('Captured range: —'), findsOneWidget);
      expect(
        find.text('Short sample gap; stand upright to recover.'),
        findsOneWidget,
      );
      expect(finish().onPressed, isNull);
      await snapshot(
        tester,
        'interrupted',
        exerciseId: exerciseId,
        reason: 'Thigh timestamp reset; restart recording.',
      );
      expect(find.text('Finish recording'), findsNothing);
      expect(
        find.text('Thigh timestamp reset; restart recording.'),
        findsOneWidget,
      );
    });
    testWidgets(
      '$exerciseId missing reference keeps counter and opens inline recorder',
      (tester) async {
        records = [];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ThighSessionPanel(
                connection: connection,
                exerciseId: exerciseId,
                store: store,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Counting has not started. Set a movement reference first.',
          ),
          findsOneWidget,
        );
        expect(find.text('Repetitions'), findsOneWidget);
        expect(find.text('0'), findsOneWidget);
        await connection.connect();
        await snapshot(tester, 'idle', exerciseId: exerciseId);
        await tester.tap(find.text('Set movement reference'));
        await tester.pumpAndSettle();
        final recorder = tester.widget<ExerciseReferenceScreen>(
          find.byType(ExerciseReferenceScreen),
        );
        expect(recorder.exerciseId, exerciseId);
        expect(recorder.disconnectOnDispose, isFalse);
        await snapshot(tester, 'recording', exerciseId: exerciseId);
        records = [reference(45)..['exercise_id'] = exerciseId];
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(connection.status, WearableStatus.live);
        expect((commands.last.arguments as Map)['action'], 'thigh_cancel');
        expect(find.text('Start exercise'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Start exercise'),
              )
              .onPressed,
          isNotNull,
        );
        await snapshot(
          tester,
          'active',
          repetitions: 4,
          exerciseId: exerciseId,
        );
        expect(find.text('4'), findsOneWidget);
        expect(find.text('Record exercise reference'), findsNothing);
        expect(find.text('Edit exercise reference'), findsNothing);
        expect(find.byType(ExerciseReferenceScreen), findsNothing);
      },
    );
  }

  testWidgets(
    'countdown respects reduced motion and reference page fits large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: const Scaffold(body: SessionZeroCountdown(progress: .4)),
          ),
        ),
      );
      expect(
        tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher)).duration,
        Duration.zero,
      );
      await showReference(tester);
      await snapshot(tester, 'zeroing', progress: .4);
      await tester.scrollUntilVisible(
        find.text('Stand still'),
        100,
        maxScrolls: 80,
      );
      expect(tester.takeException(), isNull);
      await snapshot(tester, 'recording', tilt: 35, peak: 50);
      await tester.scrollUntilVisible(
        find.text('Captured range: 50.0°'),
        100,
        maxScrolls: 80,
      );
      expect(find.text('Thigh tilt: 35.0°'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
