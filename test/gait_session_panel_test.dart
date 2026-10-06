import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/gait_analysis.dart';
import 'package:rehab_monitor/gait_session_panel.dart';
import 'package:rehab_monitor/live_sensor_screen.dart';
import 'package:rehab_monitor/wearable_connection.dart';

import 'gait_analysis_test.dart' as gait_fixtures;
import 'wearable_connection_test.dart' as fixtures;

class MemoryStore extends GaitReferenceStore {
  GaitReference? reference;
  bool failLoad = false, failSave = false;
  @override
  Future<GaitReference?> load() async {
    if (failLoad) throw const FormatException('storage unavailable');
    return reference;
  }

  @override
  Future<GaitReference> save(GaitReference value) async {
    if (failSave) throw const FormatException('save failed');
    return reference = value;
  }
}

void main() {
  late WearableConnection connection;
  late MemoryStore store;
  late List<Map<dynamic, dynamic>> sent;
  Completer<void>? pending;
  setUp(() {
    store = MemoryStore();
    sent = [];
    pending = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fixtures.commands, (call) async {
      if (call.method == 'sessionCommand') {
        sent.add(call.arguments as Map<dynamic, dynamic>);
        await pending?.future;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('rehab/wearable/events'),
      (_) async => null,
    );
    connection = WearableConnection(android: true);
  });
  tearDown(() => connection.dispose());

  Future<void> emitState(
    WidgetTester tester,
    String state, {
    Map<String, dynamic>? data,
  }) async {
    await tester.runAsync(
      () => fixtures.emit({
        'type': 'analytics',
        'analytics': fixtures.analytics()
          ..['gait'] = data ?? gait_fixtures.gaitJson(state: state),
      }),
    );
    await tester.pump();
  }

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: GaitSessionPanel(connection: connection, store: store),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await connection.connect();
    await tester.runAsync(
      () => fixtures.emit(
        fixtures.sample()
          ..['fsr_left'] = 800
          ..['analytics'] = (fixtures.analytics()
            ..['gait'] = gait_fixtures.gaitJson(state: 'setup')),
      ),
    );
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text).last);
    await tester.tap(find.text(text).last);
    await tester.pumpAndSettle();
  }

  Future<void> setup(WidgetTester tester) async {
    for (final label in ['Thigh hinge axis', 'Shin hinge axis']) {
      await tap(tester, label);
      await tap(tester, 'Y');
    }
    for (final label in ['Thigh axis direction', 'Shin axis direction']) {
      await tap(tester, label);
      await tap(tester, 'Positive (+)');
    }
    for (final label in [
      'IMUs use ±2g and ±250°/s; FSR values use 0–4095',
      'Right-leg mounting and signed axes verified',
      'Left/right forefoot labels verified by loading each sensor',
    ]) {
      await tap(tester, label);
    }
    await tap(tester, 'Confirm gait setup');
    await emitState(tester, 'ready');
    await tester.enterText(find.byKey(const ValueKey('gait-distance')), '12');
    await tester.pump();
  }

  ButtonStyleButton button(WidgetTester tester, String text) =>
      tester.widget<ButtonStyleButton>(
        find
            .ancestor(
              of: find.text(text),
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            )
            .first,
      );

  testWidgets(
    'forefoot calibration sends matching actions and requires a fresh baseline',
    (tester) async {
      await show(tester);
      await setup(tester);
      expect(
        find.textContaining('heel baselines cannot be used'),
        findsOneWidget,
      );
      expect((sent.first['config'] as Map)['forefoot_mapping_confirmed'], true);
      await tap(tester, 'Capture unloaded forefeet');
      expect(sent.last['action'], 'gait_forefoot_unloaded');
      await emitState(tester, 'forefoot_unloaded');
      expect(find.text('Cancel calibration'), findsOneWidget);
      expect(button(tester, 'Capture loaded forefeet').onPressed, isNull);
      await emitState(tester, 'setup');
      await tap(tester, 'Capture loaded forefeet');
      expect(sent.last['action'], 'gait_forefoot_loaded');
      expect(button(tester, 'Start comparison walk').onPressed, isNull);
    },
  );

  testWidgets(
    'manual start carries distance, tolerance and saved baseline; Stop ends walk',
    (tester) async {
      store.reference = GaitReference.fromJson(gait_fixtures.referenceJson());
      await show(tester);
      await setup(tester);
      expect(sent.first['action'], 'gait_configure');
      await tap(tester, 'Start comparison walk');
      expect(sent.last['action'], 'gait_session_begin');
      expect((sent.last['config'] as Map)['distance_m'], 12);
      expect((sent.last['config'] as Map)['tolerance_pct'], 20);
      expect(
        (sent.last['config'] as Map)['reference'],
        store.reference!.toJson(),
      );
      await emitState(tester, 'active');
      expect(find.text('Stop walk'), findsOneWidget);
      await tap(tester, 'Stop walk');
      expect(sent.last['action'], 'gait_session_end');
    },
  );

  testWidgets(
    'invalid distance/tolerance and missing baseline disable starts',
    (tester) async {
      await show(tester);
      await setup(tester);
      expect(button(tester, 'Start comparison walk').onPressed, isNull);
      for (final bad in ['0', '-1', 'NaN', 'Infinity', 'abc']) {
        await tester.enterText(
          find.byKey(const ValueKey('gait-distance')),
          bad,
        );
        await tester.pump();
        expect(button(tester, 'Start baseline walk').onPressed, isNull);
      }
      await tester.enterText(find.byKey(const ValueKey('gait-distance')), '12');
      await tester.enterText(
        find.byKey(const ValueKey('gait-tolerance')),
        '101',
      );
      await tester.pump();
      expect(button(tester, 'Start baseline walk').onPressed, isNull);
    },
  );

  testWidgets(
    'failed replacement preserves prior baseline and permits save retry',
    (tester) async {
      final old = GaitReference.fromJson(gait_fixtures.referenceJson());
      store.reference = old;
      await show(tester);
      final preview = gait_fixtures.referenceJson(date: '2026-10-06T13:00:00Z');
      await emitState(
        tester,
        'reference_ready',
        data: gait_fixtures.gaitJson(state: 'reference_ready')
          ..['reference_preview'] = preview
          ..['summary'] = (gait_fixtures.summaryJson()..['comparison'] = null),
      );
      store.failSave = true;
      await tap(tester, 'Replace saved baseline');
      expect(store.reference!.recordedAt, old.recordedAt);
      expect(
        find.textContaining('previous baseline is retained'),
        findsOneWidget,
      );
      expect(button(tester, 'Replace saved baseline').onPressed, isNotNull);
      store.failSave = false;
      await tap(tester, 'Replace saved baseline');
      expect(store.reference!.recordedAt, '2026-10-06T13:00:00Z');
    },
  );

  testWidgets(
    'short walk and named deviations are shown without diagnostic labels',
    (tester) async {
      await show(tester);
      await emitState(
        tester,
        'ended',
        data: gait_fixtures.gaitJson(state: 'ended')
          ..['summary'] = (gait_fixtures.summaryJson()
            ..['comparison'] = 'insufficient_data'),
      );
      expect(find.textContaining('Insufficient data'), findsOneWidget);
      await emitState(
        tester,
        'ended',
        data: gait_fixtures.gaitJson(state: 'ended')
          ..['summary'] = (gait_fixtures.summaryJson()
            ..['comparison'] = 'outside_reference'
            ..['deviations'] = [
              {'metric': 'cadence_spm', 'deviation_pct': 25.0},
            ]),
      );
      expect(find.text('Outside reference'), findsOneWidget);
      expect(find.textContaining('differs by 25.0%'), findsOneWidget);
      expect(find.text('Abnormal'), findsNothing);
    },
  );

  testWidgets(
    'pending commands disable duplicate starts and disconnect requires setup again',
    (tester) async {
      await show(tester);
      await setup(tester);
      pending = Completer<void>();
      await tester.ensureVisible(find.text('Start baseline walk'));
      await tester.tap(find.text('Start baseline walk'));
      await tester.pump();
      expect(button(tester, 'Start baseline walk').onPressed, isNull);
      pending!.complete();
      await tester.pumpAndSettle();
      await tester.runAsync(() => connection.disconnect());
      await tester.pump();
      expect(button(tester, 'Start baseline walk').onPressed, isNull);
    },
  );

  testWidgets(
    'calibration can be cancelled and distance averages wait for Stop',
    (tester) async {
      await show(tester);
      await setup(tester);
      await emitState(tester, 'standing');
      await tap(tester, 'Cancel calibration');
      expect(sent.last['action'], 'gait_cancel');
      await emitState(tester, 'setup');
      expect(button(tester, 'Start baseline walk').onPressed, isNull);
      await emitState(tester, 'active');
      expect(find.text('After Stop'), findsNWidgets(3));
      expect(find.text('Stop walk'), findsOneWidget);
    },
  );

  testWidgets(
    'gait screen fits 320px and large text; background retains native summary',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: LiveSensorScreen(connection: connection, exerciseId: 'gait'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Heel signal share'), findsNothing);
      await connection.connect();
      await tester.runAsync(
        () => fixtures.emit(
          fixtures.sample()
            ..['fsr_left'] = 800
            ..['analytics'] = (fixtures.analytics()
              ..['gait'] = (gait_fixtures.gaitJson(state: 'active')
                ..['summary'] = gait_fixtures.summaryJson(interrupted: true))),
        ),
      );
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Gait sensor setup'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(connection.status, WearableStatus.disconnected);
      expect(connection.gait!.summary!.metrics.values['duration_s'], 20);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );
}
