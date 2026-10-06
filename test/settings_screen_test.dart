import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/app_settings.dart';
import 'package:rehab_monitor/settings_screen.dart';
import 'package:rehab_monitor/main.dart';
import 'package:rehab_monitor/wearable_connection.dart';
import 'wearable_connection_test.dart' as fixtures;

const zero = {
  'version': 1,
  'adc_max': 1023,
  'left': {'baseline': 12.0, 'deadband': 5.0},
  'right': {'baseline': 11.0, 'deadband': 5.0},
};

void main() {
  late Map<String, dynamic> saved;
  late WearableConnection connection;
  late List<String> actions;
  var failSave = false;
  setUp(() {
    saved = {'injured_leg': null, 'heel_zero': null};
    actions = [];
    failSave = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fixtures.commands, (call) async {
      if (call.method == 'getSettings') return saved;
      if (call.method == 'saveSettings') {
        if (failSave) throw PlatformException(code: 'storage_error');
        saved = Map<String, dynamic>.from(call.arguments as Map);
        return saved;
      }
      if (call.method == 'sessionCommand') {
        actions.add((call.arguments as Map)['action'] as String);
        await fixtures.emit({
          'type': 'analytics',
          'analytics': fixtures.analytics(state: 'heel_zero')
            ..['heel_zero'] = null,
        });
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

  test('settings rejects invalid baselines', () {
    expect(
      () => AppSettings.fromJson({'injured_leg': 'other', 'heel_zero': null}),
      throwsFormatException,
    );
    expect(
      () => AppSettings.fromJson({
        'injured_leg': 'left',
        'heel_zero': {
          ...zero,
          'left': {'baseline': double.nan, 'deadband': 5},
        },
      }),
      throwsFormatException,
    );
  });

  testWidgets('injured leg persists and reloads', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(connection: connection)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Right'));
    await tester.pumpAndSettle();
    expect(saved['injured_leg'], 'right');
    await tester.scrollUntilVisible(find.text('Injured leg saved'), 150);
    expect(find.text('Injured leg saved'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(connection: connection)),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>))
          .selected,
      {'right'},
    );
  });

  testWidgets('baseline saves only after fresh capture finishes', (
    tester,
  ) async {
    saved['heel_zero'] = zero;
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(connection: connection)),
    );
    await tester.pumpAndSettle();
    await connection.connect();
    await tester.runAsync(
      () => fixtures.emit(
        fixtures.sample()
          ..['fsr'] = 12
          ..['fsr_left'] = 11
          ..['analytics'] = (fixtures.analytics()..['heel_zero'] = zero),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Capture unloaded sensors'), 150);
    await tester.tap(find.text('Capture unloaded sensors'));
    await tester.pump();
    expect(actions, ['heel_zero']);
    expect(find.text('Baseline saved'), findsNothing);
    await tester.runAsync(
      () => fixtures.emit({
        'type': 'analytics',
        'analytics': fixtures.analytics(state: 'heel_zero')
          ..['heel_zero'] = null,
      }),
    );
    await tester.pump();
    await tester.runAsync(
      () => fixtures.emit({
        'type': 'analytics',
        'analytics': fixtures.analytics()
          ..['reason'] = null
          ..['progress'] = 1.0
          ..['heel_zero'] = zero,
      }),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Baseline saved'), 100);
    expect(find.text('Baseline saved'), findsOneWidget);
    expect(saved['heel_zero'], zero);
  });

  testWidgets('save failure keeps old leg and permits retry', (tester) async {
    saved['injured_leg'] = 'left';
    failSave = true;
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(connection: connection)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Right'));
    await tester.pumpAndSettle();
    expect(saved['injured_leg'], 'left');
    await tester.scrollUntilVisible(find.text('Retry saving'), 150);
    await tester.ensureVisible(find.text('Retry saving'));
    await tester.pumpAndSettle();
    failSave = false;
    await tester.tap(find.text('Retry saving'));
    await tester.pumpAndSettle();
    expect(saved['injured_leg'], 'right');
  });

  testWidgets(
    'disconnection cancels pending baseline without saving stale data',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(connection: connection)),
      );
      await tester.pumpAndSettle();
      await connection.connect();
      await tester.runAsync(
        () => fixtures.emit(
          fixtures.sample()
            ..['fsr'] = 12
            ..['fsr_left'] = 11,
        ),
      );
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Capture unloaded sensors'),
        150,
      );
      await tester.tap(find.text('Capture unloaded sensors'));
      await tester.pump();
      await tester.runAsync(() => connection.disconnect());
      await tester.pumpAndSettle();
      expect(saved['heel_zero'], isNull);
      expect(find.text('Baseline saved'), findsNothing);
      await tester.scrollUntilVisible(find.text('Retry capture'), 100);
      expect(
        find.text('Capture stopped. Reconnect and retry.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('settings navigation fits small screen at large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(const MyApp());
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
