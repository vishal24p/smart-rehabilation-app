import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/session_home_screen.dart';

Map<String, dynamic> session(
  String id,
  DateTime start, {
  bool active = false,
}) => {
  'id': id,
  'started_at': start.toUtc().toIso8601String(),
  'ended_at': active
      ? null
      : start.add(const Duration(minutes: 3)).toUtc().toIso8601String(),
  'status': active ? 'active' : 'ended',
  'exercises': <Object>[],
};

void main() {
  var rows = <Map<String, dynamic>>[];
  var failLoad = false;
  var failSave = false;
  setUp(() {
    rows = [];
    failLoad = false;
    failSave = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('rehab/wearable'), (
          call,
        ) async {
          if (call.method == 'getWorkoutSessions') {
            if (failLoad) throw PlatformException(code: 'storage_error');
            return rows;
          }
          if (call.method == 'saveWorkoutSession') {
            if (failSave) throw PlatformException(code: 'storage_error');
            final saved = Map<String, dynamic>.from(call.arguments as Map);
            rows[rows.indexWhere((row) => row['id'] == saved['id'])] = saved;
            return saved;
          }
          return null;
        });
  });

  testWidgets('calendar groups multiple sessions by local start date', (
    tester,
  ) async {
    final today = DateTime(2026, 10, 6);
    rows = [
      session('one', DateTime(2026, 10, 6, 8)),
      session('two', DateTime(2026, 10, 6, 15)),
    ];
    await tester.pumpWidget(MaterialApp(home: SessionHomeScreen(today: today)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('2 sessions'), 100);
    expect(find.text('2 sessions'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('session-one')),
      100,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('session-one')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-one')), findsOneWidget);
    expect(find.byKey(const ValueKey('session-two')), findsOneWidget);
  });

  testWidgets('month controls cross year boundaries', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: SessionHomeScreen(today: DateTime(2027, 1, 3))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();
    expect(find.text('December 2026'), findsOneWidget);
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    expect(find.text('January 2027'), findsOneWidget);
  });

  testWidgets('calendar dates expose screen reader tap actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(home: SessionHomeScreen(today: DateTime(2026, 10, 6))),
    );
    await tester.pumpAndSettle();
    final day = find.byKey(const ValueKey('calendar-2026-10-6'));
    await tester.ensureVisible(day);
    await tester.pumpAndSettle();
    expect(
      tester
          .getSemantics(day)
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    semantics.dispose();
  });

  testWidgets('failed history load can retry without fake rows', (
    tester,
  ) async {
    failLoad = true;
    await tester.pumpWidget(const MaterialApp(home: SessionHomeScreen()));
    await tester.pumpAndSettle();
    expect(find.text('History unavailable. Retry loading.'), findsOneWidget);
    failLoad = false;
    await tester.tap(find.text('Retry history'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('No sessions on this day.'), 100);
    expect(find.text('No sessions on this day.'), findsOneWidget);
  });

  testWidgets('small large-text home uses accessible date chooser', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(home: SessionHomeScreen(today: DateTime(2026, 10, 6))),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Choose date'), 100);
    expect(find.text('Choose date'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unfinished session closes without resuming exercises', (
    tester,
  ) async {
    rows = [session('unfinished', DateTime(2026, 10, 6, 8), active: true)];
    await tester.pumpWidget(
      MaterialApp(home: SessionHomeScreen(today: DateTime(2026, 10, 6))),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('session-unfinished')),
      100,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('session-unfinished')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-unfinished')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close session'));
    await tester.pumpAndSettle();
    expect(rows.single['status'], 'ended');
    expect(rows.single['exercises'], isEmpty);
  });

  testWidgets('near-midnight UTC record displays on its local start day', (
    tester,
  ) async {
    final localStart = DateTime(2026, 10, 6, 0, 5);
    rows = [session('midnight', localStart.toUtc())];
    await tester.pumpWidget(
      MaterialApp(home: SessionHomeScreen(today: DateTime(2026, 10, 6))),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('session-midnight')),
      100,
    );
    expect(find.byKey(const ValueKey('session-midnight')), findsOneWidget);
  });

  testWidgets(
    'closing unfinished history retries same record after storage failure',
    (tester) async {
      rows = [session('unfinished', DateTime(2026, 10, 6, 8), active: true)];
      failSave = true;
      await tester.pumpWidget(
        MaterialApp(home: SessionHomeScreen(today: DateTime(2026, 10, 6))),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('session-unfinished')),
        100,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('session-unfinished')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('session-unfinished')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close session'));
      await tester.pumpAndSettle();
      expect(rows.single['status'], 'active');
      failSave = false;
      await tester.tap(find.text('Retry saving'));
      await tester.pumpAndSettle();
      expect(rows.single['id'], 'unfinished');
      expect(rows.single['status'], 'ended');
    },
  );

  testWidgets('detail shows real frozen metrics and missing values as dashes', (
    tester,
  ) async {
    final start = DateTime(2026, 10, 6, 8);
    rows = [
      session('result', start)
        ..['exercises'] = [
          {
            'id': 'attempt',
            'exercise_id': 'squat',
            'started_at': start.toUtc().toIso8601String(),
            'ended_at': start
                .add(const Duration(seconds: 30))
                .toUtc()
                .toIso8601String(),
            'result': {
              'repetitions': 0,
              'rep_target': 10,
              'active_s': 20.0,
              'latest_peak_deg': null,
              'reference_peak_deg': 45.0,
              'difference_deg': null,
              'outcome': 'ended_early',
            },
          },
        ],
    ];
    await tester.pumpWidget(
      MaterialApp(home: SessionHomeScreen(today: DateTime(2026, 10, 6))),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('session-result')),
      100,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('session-result')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-result')));
    await tester.pumpAndSettle();
    expect(find.text('Ended early'), findsOneWidget);
    expect(find.text('0 / 10'), findsOneWidget);
    expect(find.text('20.0 s'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Reference difference'), 100);
    expect(find.text('45.0°'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(2));
  });
}
