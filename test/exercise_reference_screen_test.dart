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
  }) async {
    await tester.runAsync(
      () => fixtures.emit(
        fixtures.sample(time: ++time)
          ..['analytics'] = (fixtures.analytics()
            ..['thigh'] = {
              'state': state,
              'exercise_id': 'squat',
              'reason': null,
              'zero_progress': progress,
              'tilt_deg': null,
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
      expect(find.text('Repetitions'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('Latest range'), findsOneWidget);
      expect(find.text('50.0°'), findsOneWidget);
      expect(find.text('Reference difference'), findsOneWidget);
      expect(find.text('5.0°'), findsOneWidget);
      expect(find.text('Edit exercise reference'), findsNothing);
    },
  );

  testWidgets('missing reference points to Register without another route', (
    tester,
  ) async {
    records = [];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThighSessionPanel(
            connection: connection,
            exerciseId: 'squat',
            store: store,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Set a reference in the Register tab.'), findsOneWidget);
    expect(find.text('Record exercise reference'), findsNothing);
    expect(find.text('Edit exercise reference'), findsNothing);
    expect(find.byType(ExerciseReferenceScreen), findsNothing);
  });

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
    },
  );
}
