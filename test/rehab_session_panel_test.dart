import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/rehab_session_panel.dart';
import 'package:rehab_monitor/wearable_connection.dart';
import 'wearable_connection_test.dart' as fixtures;

void main() {
  late WearableConnection connection;
  late List<Map<dynamic, dynamic>> sent;
  setUp(() {
    sent = [];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fixtures.commands, (call) async {
      if (call.method == 'sessionCommand') sent.add(call.arguments as Map<dynamic, dynamic>);
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('rehab/wearable/events'), (_) async => null);
    connection = WearableConnection(android: true);
  });
  tearDown(() => connection.dispose());

  Future<void> show(WidgetTester tester, {bool ranges = true}) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: RehabSessionPanel(connection: connection, rangesConfirmed: ranges),
    ))));
    await connection.connect();
    await tester.runAsync(() => fixtures.emit(fixtures.sample()..['analytics'] = fixtures.analytics()));
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text).last);
    await tester.tap(find.text(text).last);
    await tester.pumpAndSettle();
  }

  Future<void> state(WidgetTester tester, String value, {Map<String, dynamic>? data}) async {
    await tester.runAsync(() => fixtures.emit({'type': 'analytics', 'analytics': data ?? fixtures.analytics(state: value)}));
    await tester.pump();
  }

  Future<void> configure(WidgetTester tester) async {
    for (final label in ['Thigh hinge axis', 'Shin hinge axis']) {
      await tap(tester, label);
      await tap(tester, 'Y');
    }
    for (final label in ['Thigh axis direction', 'Shin axis direction']) {
      await tap(tester, label);
      await tap(tester, 'Positive (+)');
    }
    await tap(tester, 'Mounting and signed axes verified');
    await tap(tester, 'Confirm setup');
  }

  testWidgets('unconfirmed mounting and ranges cannot start; unknown is em dash', (tester) async {
    await show(tester, ranges: false);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start session')).onPressed, isNull);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm setup')).onPressed, isNull);
    expect(find.text('—'), findsNWidgets(5));
    expect(find.text('0'), findsNothing);
    expect(find.textContaining('prototype estimates'), findsOneWidget);
    await state(tester, 'ready');
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start session')).onPressed, isNull);
  });

  testWidgets('explicit heel captures and paced calibration lead to summary', (tester) async {
    await show(tester);
    await configure(tester);
    expect(sent.first['action'], 'configure');
    expect(sent.first['config'], {
      'ranges_confirmed': true, 'mounting_confirmed': true,
      'thigh_axis': {'index': 1, 'sign': 1}, 'shin_axis': {'index': 1, 'sign': 1},
    });
    await tap(tester, 'Capture unloaded heel');
    await state(tester, 'heel_unloaded');
    expect(find.textContaining('Keep the heel sensor unloaded'), findsOneWidget);
    await state(tester, 'setup');
    await tap(tester, 'Capture loaded heel');
    await state(tester, 'setup', data: fixtures.analytics()..['reason'] = 'Heel separation too small. Heel contact unavailable.');
    await tap(tester, 'Ready for standing reference');
    expect(sent.last['action'], 'standing');
    await state(tester, 'standing');
    expect(find.textContaining('three consecutive seconds'), findsOneWidget);
    await state(tester, 'movement_ready');
    await tap(tester, 'Ready for movement check');
    await state(tester, 'movement');
    expect(find.textContaining('two slow stand → sit → stand cycles'), findsOneWidget);
    await tap(tester, 'Finish movement check');
    await state(tester, 'ready');
    await tap(tester, 'Start session');
    await state(tester, 'active', data: fixtures.analytics(state: 'active', cycles: 2)..['angle_deg'] = 45.0);
    await tap(tester, 'End session');
    expect(sent.last['action'], 'end');
    await state(tester, 'ended', data: fixtures.analytics(state: 'ended', cycles: 2)..['summary'] = fixtures.summary(interrupted: false));
    expect(find.text('Session summary'), findsOneWidget);
    expect(find.text('2 completed cycles'), findsOneWidget);
    expect(find.textContaining('Partial cycles are excluded'), findsOneWidget);
    expect(sent.map((s) => s['action']), ['configure', 'heel_unloaded', 'heel_loaded', 'standing', 'movement', 'finish_movement', 'start', 'end']);
  });

  testWidgets('interruption disables Start and keeps interrupted summary distinct', (tester) async {
    await show(tester);
    await configure(tester);
    await state(tester, 'movement');
    await state(tester, 'interrupted', data: fixtures.analytics(state: 'interrupted')..['summary'] = fixtures.summary());
    expect(find.text('Interrupted session summary'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start session')).onPressed, isNull);
    expect(find.text('—'), findsNWidgets(5));
    expect(find.text('2 completed cycles'), findsOneWidget);
    await tap(tester, 'Retry calibration');
    expect(sent.last['action'], 'retry');
  });

  testWidgets('pending command disables actions and failure permits retry', (tester) async {
    await show(tester);
    await configure(tester);
    final gate = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(fixtures.commands, (call) async {
      if (call.method == 'sessionCommand') return gate.future;
      return null;
    });
    await tester.ensureVisible(find.text('Ready for standing reference'));
    await tester.tap(find.text('Ready for standing reference'));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Ready for standing reference')).onPressed, isNull);
    gate.completeError(PlatformException(code: 'session_unavailable', message: 'Wait for readings and retry.'));
    await tester.pumpAndSettle();
    expect(find.text('Wait for readings and retry.'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Ready for standing reference')).onPressed, isNotNull);
  });

  testWidgets('320px and large text keep setup and semantic metrics accessible', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final semantics = tester.ensureSemantics();
    await show(tester);
    await configure(tester);
    await state(tester, 'ready');
    await tester.ensureVisible(find.text('Start session'));
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('Estimated knee bend from standing: unavailable'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Board axis direction guide')), findsOneWidget);
    semantics.dispose();
  });
}
