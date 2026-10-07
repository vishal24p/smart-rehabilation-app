import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/wearable_connection.dart';

const commands = MethodChannel('rehab/wearable');
const events = EventChannel('rehab/wearable/events');
const codec = StandardMethodCodec();

Map<String, Object> sample({int time = 1, bool restart = false}) => {
  'type': 'sample',
  'time_us': time,
  'restart': restart,
  'thigh_accel': [1, 2, 3],
  'thigh_gyro': [4, 5, 6],
  'shin_accel': [7, 8, 9],
  'shin_gyro': [10, 11, 12],
  'fsr': 1200,
  'scaled': false,
};

Future<void> emit(Map<String, Object?> data) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        events.name,
        codec.encodeSuccessEnvelope(jsonEncode(data)),
        (_) {},
      );
  await Future<void>.delayed(Duration.zero);
}

Map<String, dynamic> analytics({String state = 'setup', int? cycles}) => {
  'state': state,
  'reason': 'Follow the calibration instructions.',
  'progress': 0.0,
  'angle_deg': null,
  'rom_deg': null,
  'cycles': cycles,
  'last_cycle_s': null,
  'heel_contact': null,
  'heel_saturated': false,
  'summary': null,
};

Map<String, dynamic> summary({bool interrupted = true}) => {
  'cycles': 2,
  'rom_deg': 60.0,
  'active_s': 12.0,
  'cycle_times_s': [2.1, 2.2],
  'interrupted': interrupted,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<String> calls;
  late WearableConnection connection;
  var elapsed = Duration.zero;

  setUp(() {
    calls = [];
    elapsed = Duration.zero;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commands, (call) async {
      calls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('rehab/wearable/events'),
      (call) async => null,
    );
    connection = WearableConnection(android: true, clock: () => elapsed);
  });
  tearDown(() {
    connection.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commands, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('rehab/wearable/events'),
      null,
    );
  });

  test('zero capture payload is validated and retained in analytics', () {
    final zero = {
      'version': 1,
      'adc_max': 1023,
      'left': {'baseline': 12.0, 'deadband': 5.0},
      'right': {'baseline': 11.0, 'deadband': 5.0},
    };
    final snapshot = analytics(state: 'heel_zero')..['heel_zero'] = zero;
    expect(RehabAnalytics.fromJson(snapshot).heelZero, zero);
    snapshot['heel_zero'] = 'bad';
    expect(() => RehabAnalytics.fromJson(snapshot), throwsFormatException);
    snapshot['heel_zero'] = {...zero, 'version': 2};
    expect(() => RehabAnalytics.fromJson(snapshot), throwsFormatException);
  });

  test(
    'legacy and dual heel samples retain independent readings and history',
    () async {
      await connection.connect();
      await emit(sample());
      expect(connection.latest!.fsr, 1200);
      expect(connection.latest!.fsrLeft, isNull);
      expect(connection.history.single.leftAdc, isNull);
      await emit(sample(time: 2)..['fsr_left'] = 750);
      expect(connection.latest!.fsr, 1200);
      expect(connection.latest!.fsrLeft, 750);
      expect(connection.history.last.adc, 1200);
      expect(connection.history.last.leftAdc, 750);
    },
  );

  test(
    'explicit missing IMUs stay unavailable without invented zero vectors',
    () {
      final thighOnly = SensorSample.fromJson(<String, dynamic>{
        ...sample(),
        'shin_accel': null,
        'shin_gyro': null,
      });
      expect(thighOnly.thighAccel, [1, 2, 3]);
      expect(thighOnly.thighGyro, [4, 5, 6]);
      expect(thighOnly.shinAccel, isNull);
      expect(thighOnly.shinGyro, isNull);
      final shinOnly = SensorSample.fromJson(<String, dynamic>{
        ...sample(),
        'thigh_accel': null,
        'thigh_gyro': null,
      });
      expect(shinOnly.thighAccel, isNull);
      expect(shinOnly.thighGyro, isNull);
      expect(shinOnly.shinAccel, [7, 8, 9]);
      expect(shinOnly.shinGyro, [10, 11, 12]);
      final heelsOnly = SensorSample.fromJson(<String, dynamic>{
        ...sample(),
        'thigh_accel': null,
        'thigh_gyro': null,
        'shin_accel': null,
        'shin_gyro': null,
        'fsr_left': 750,
      });
      expect(heelsOnly.thighAccel, isNull);
      expect(heelsOnly.shinAccel, isNull);
      expect(heelsOnly.fsr, 1200);
      expect(heelsOnly.fsrLeft, 750);
      final zero = SensorSample.fromJson(
        sample()
          ..['shin_accel'] = [0, 0, 0]
          ..['shin_gyro'] = [0, 0, 0],
      );
      expect(zero.shinAccel, [0, 0, 0]);
      expect(zero.shinGyro, [0, 0, 0]);
    },
  );

  test(
    'motion vectors require present keys, paired nulls and valid values',
    () {
      for (final key in [
        'thigh_accel',
        'thigh_gyro',
        'shin_accel',
        'shin_gyro',
      ]) {
        expect(
          () => SensorSample.fromJson(sample()..remove(key)),
          throwsFormatException,
        );
        expect(
          () =>
              SensorSample.fromJson(<String, dynamic>{...sample(), key: null}),
          throwsFormatException,
        );
        for (final value in <Object>[
          [1, 2],
          [1, 2, double.infinity],
          [1, 2, '3'],
          [1, 2, 32768],
          [1, 2, -32769],
          [1, 2, 3.5],
          false,
        ]) {
          expect(
            () => SensorSample.fromJson(sample()..[key] = value),
            throwsFormatException,
            reason: key,
          );
        }
      }
      final scaled = SensorSample.fromJson(
        sample()
          ..['scaled'] = true
          ..['thigh_accel'] = [0.5, 1.5, 2.5],
      );
      expect(scaled.thighAccel, [0.5, 1.5, 2.5]);
    },
  );

  test('samples reject invalid left ADC readings', () {
    for (final value in <Object>[-1, 4096, 1.5, '750', true]) {
      expect(
        () => SensorSample.fromJson(sample()..['fsr_left'] = value),
        throwsFormatException,
      );
    }
    for (final value in [0, 4095]) {
      expect(
        SensorSample.fromJson(sample()..['fsr_left'] = value).fsrLeft,
        value,
      );
    }
  });

  test('dual heel analytics accepts optional unavailable shares', () {
    final legacy = RehabAnalytics.fromJson(analytics());
    expect(legacy.leftHeelContact, isNull);
    expect(legacy.leftHeelSaturated, isFalse);
    expect(legacy.heelShareRight, isNull);
    expect(legacy.heelShareLeft, isNull);
    expect(legacy.heelShareReason, isNull);
    final dual = RehabAnalytics.fromJson(
      analytics()
        ..['left_heel_contact'] = true
        ..['left_heel_saturated'] = false
        ..['heel_share_right'] = 60
        ..['heel_share_left'] = 40.0,
    );
    expect(dual.leftHeelContact, isTrue);
    expect(dual.heelShareRight, 60);
    expect(dual.heelShareLeft, 40);
    final unavailable = RehabAnalytics.fromJson(
      analytics()
        ..['left_heel_contact'] = null
        ..['heel_share_right'] = null
        ..['heel_share_left'] = null,
    );
    expect(unavailable.leftHeelContact, isNull);
    expect(unavailable.heelShareRight, isNull);
    expect(unavailable.heelShareLeft, isNull);
    final noLoad = RehabAnalytics.fromJson(
      analytics()..['heel_share_reason'] = 'No heel load detected.',
    );
    expect(noLoad.heelShareReason, 'No heel load detected.');
    for (final shares in [
      {'heel_share_right': 50},
      {'heel_share_left': 50},
      {'heel_share_right': 60, 'heel_share_left': 60},
    ]) {
      expect(
        () => RehabAnalytics.fromJson(analytics()..addAll(shares)),
        throwsFormatException,
      );
    }
    for (final key in ['heel_share_right', 'heel_share_left']) {
      for (final value in <Object>[
        -1,
        101,
        double.nan,
        double.infinity,
        '50',
      ]) {
        expect(
          () => RehabAnalytics.fromJson(analytics()..[key] = value),
          throwsFormatException,
          reason: key,
        );
      }
    }
    for (final entry in <String, Object?>{
      'left_heel_contact': 1,
      'left_heel_saturated': null,
      'heel_share_reason': 1,
    }.entries) {
      expect(
        () => RehabAnalytics.fromJson(analytics()..[entry.key] = entry.value),
        throwsFormatException,
      );
    }
  });

  test(
    'connection preserves dual analytics and clears them when unavailable',
    () async {
      await connection.connect();
      await emit(
        sample()
          ..['analytics'] = (analytics()
            ..['left_heel_contact'] = true
            ..['left_heel_saturated'] = true
            ..['heel_share_right'] = 60
            ..['heel_share_left'] = 40),
      );
      expect(connection.analytics!.leftHeelContact, isTrue);
      expect(connection.analytics!.leftHeelSaturated, isTrue);
      expect(connection.analytics!.heelShareRight, 60);
      expect(connection.analytics!.heelShareLeft, 40);
      await emit({
        'type': 'analytics',
        'analytics': analytics()
          ..['heel_share_reason'] = 'No heel load detected.',
      });
      expect(connection.analytics!.heelShareReason, 'No heel load detected.');
      await connection.disconnect();
      expect(connection.analytics!.leftHeelContact, isNull);
      expect(connection.analytics!.heelShareRight, isNull);
      expect(connection.analytics!.heelShareLeft, isNull);
      expect(connection.analytics!.heelShareReason, isNull);
    },
  );

  test('analytics validates nullable metrics and immutable summary', () {
    expect(
      RehabAnalytics.fromJson(analytics()..['reason'] = null).reason,
      isNull,
    );
    final empty = RehabAnalytics.fromJson(analytics());
    expect(empty.angleDeg, isNull);
    expect(empty.cycles, isNull);
    expect(empty.heelContact, isNull);
    final data = analytics(state: 'ended', cycles: 2)
      ..['angle_deg'] = 5.5
      ..['rom_deg'] = 60
      ..['last_cycle_s'] = 2.2
      ..['heel_contact'] = true
      ..['summary'] = summary(interrupted: false);
    final parsed = RehabAnalytics.fromJson(data);
    expect(parsed.state, RehabState.ended);
    expect(parsed.angleDeg, 5.5);
    expect(parsed.summary!.cycleTimesS, [2.1, 2.2]);
    expect(() => parsed.summary!.cycleTimesS.add(3), throwsUnsupportedError);
  });

  test('analytics rejects malformed state, numbers, booleans and summary', () {
    for (final entry in <String, Object?>{
      'state': 'unknown',
      'reason': 1,
      'progress': 1.1,
      'angle_deg': double.infinity,
      'rom_deg': -1,
      'cycles': -1,
      'last_cycle_s': -0.1,
      'heel_contact': 'true',
      'heel_saturated': 1,
      'summary': {'cycles': 2},
    }.entries) {
      expect(
        () => RehabAnalytics.fromJson(analytics()..[entry.key] = entry.value),
        throwsFormatException,
        reason: entry.key,
      );
    }
    for (final entry in <String, Object?>{
      'cycles': -1,
      'active_s': -1,
      'cycle_times_s': [double.nan],
      'interrupted': 'false',
    }.entries) {
      expect(
        () => RehabAnalytics.fromJson(
          analytics()..['summary'] = (summary()..[entry.key] = entry.value),
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'samples keep compatibility; malformed analytics clears live metrics',
    () async {
      await connection.connect();
      await emit(sample());
      expect(connection.analytics, isNull);
      await emit(
        sample(time: 2)..['analytics'] = analytics(state: 'active', cycles: 0),
      );
      expect(connection.analytics!.cycles, 0);
      await emit({
        'type': 'analytics',
        'analytics': analytics()..['progress'] = -1,
      });
      expect(connection.status, WearableStatus.error);
      expect(connection.analytics!.cycles, isNull);
    },
  );

  test(
    'command pending prevents duplicate taps and failure keeps live state',
    () async {
      final gate = Completer<Object?>();
      var commandCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(commands, (call) async {
            if (call.method == 'sessionCommand') {
              commandCalls++;
              return gate.future;
            }
            return null;
          });
      await connection.connect();
      await emit(sample());
      final first = connection.sendSessionCommand('standing');
      await connection.sendSessionCommand('standing');
      expect(connection.commandPending, isTrue);
      await emit(sample(time: 2)..['analytics'] = analytics(state: 'ready'));
      gate.completeError(
        PlatformException(code: 'session_unavailable', message: 'Try again.'),
      );
      await first;
      expect(commandCalls, 1);
      expect(connection.commandPending, isFalse);
      expect(connection.commandError, 'Try again.');
      expect(connection.status, WearableStatus.live);
      expect(connection.analytics!.state, RehabState.ready);
    },
  );

  test(
    'disconnect reads native frozen summary before event cancellation',
    () async {
      final order = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(commands, (call) async {
            order.add(call.method);
            if (call.method == 'disconnect') {
              return jsonEncode(
                analytics(state: 'interrupted')..['summary'] = summary(),
              );
            }
            return null;
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('rehab/wearable/events'),
            (call) async {
              order.add(call.method);
              return null;
            },
          );
      await connection.connect();
      await emit(
        sample()..['analytics'] = analytics(state: 'active', cycles: 2),
      );
      await connection.disconnect();
      expect(order.indexOf('disconnect'), lessThan(order.indexOf('cancel')));
      expect(connection.analytics!.cycles, isNull);
      expect(connection.analytics!.summary!.cycles, 2);
      expect(connection.analytics!.summary!.interrupted, isTrue);
    },
  );

  test('successful start alone clears previous summary', () async {
    await connection.connect();
    await emit(
      sample()
        ..['analytics'] = (analytics(state: 'ended', cycles: 2)
          ..['summary'] = summary(interrupted: false)),
    );
    await emit({'type': 'analytics', 'analytics': analytics(state: 'ready')});
    expect(connection.analytics!.summary!.cycles, 2);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(commands, (call) async {
          if (call.method == 'sessionCommand') {
            await emit({
              'type': 'analytics',
              'analytics': analytics(state: 'active', cycles: 0),
            });
          }
          return null;
        });
    await connection.sendSessionCommand('start');
    expect(connection.analytics!.summary, isNull);
    expect(connection.analytics!.cycles, 0);
  });

  test(
    'disconnect coalesces and blocks reconnect until frozen summary is accepted',
    () async {
      final commandGate = Completer<Object?>();
      final stopGate = Completer<Object?>();
      var connects = 0, disconnects = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(commands, (call) async {
            if (call.method == 'sessionCommand') return commandGate.future;
            if (call.method == 'connect') connects++;
            if (call.method == 'disconnect') {
              disconnects++;
              return stopGate.future;
            }
            return null;
          });
      await connection.connect();
      await emit(sample());
      final command = connection.sendSessionCommand('standing');
      final stopped = connection.disconnect();
      final repeatedStop = connection.disconnect();
      await connection.connect();
      expect(connects, 1);
      expect(disconnects, 1);
      expect(connection.commandPending, isTrue);
      commandGate.completeError(PlatformException(code: 'old_failure'));
      stopGate.complete(
        jsonEncode(analytics(state: 'interrupted')..['summary'] = summary()),
      );
      await Future.wait([command, stopped, repeatedStop]);
      expect(connection.status, WearableStatus.disconnected);
      expect(connection.commandError, isNull);
      expect(connection.analytics!.summary!.cycles, 2);
      expect(connection.commandPending, isFalse);
      await connection.connect();
      expect(connects, 2);
      await emit(
        sample(time: 11)..['analytics'] = analytics(state: 'active', cycles: 1),
      );
      expect(connection.analytics!.cycles, 1);
      expect(connection.latest!.timeUs, 11);
    },
  );

  test('waits for a valid sample; clears stale values', () async {
    await connection.connect();
    expect(connection.status, WearableStatus.connecting);
    await emit({'type': 'status', 'status': 'receiving'});
    expect(connection.latest, isNull);
    await emit(sample());
    expect(connection.status, WearableStatus.live);
    expect(connection.latest!.fsr, 1200);
    await emit({'type': 'status', 'status': 'reconnecting'});
    expect(connection.latest, isNull);
    expect(connection.history, isEmpty);
  });

  test('restart clears graph; history is bounded in time and count', () async {
    await connection.connect();
    for (var i = 0; i < 115; i++) {
      elapsed = Duration(milliseconds: i * 100);
      await emit(sample(time: i + 1));
    }
    expect(connection.history.length, lessThanOrEqualTo(100));
    elapsed += const Duration(seconds: 11);
    await emit(sample(time: 200));
    expect(connection.history.length, 1);
    elapsed += const Duration(milliseconds: 100);
    await emit(sample(time: 1, restart: true));
    expect(connection.history.length, 1);
  });

  test('invalid samples cannot become live; no false physical units', () async {
    await connection.connect();
    final bad = sample()..['fsr'] = 4096;
    await emit(bad);
    expect(connection.latest, isNull);
    await emit(sample());
    expect(connection.latest!.scaled, isFalse);
    expect(connection.latest!.thighAccel, [1, 2, 3]);
  });

  test('disconnect cancels subscription and rejects late samples', () async {
    await connection.connect();
    await emit(sample());
    await connection.disconnect();
    await emit(sample(time: 2));
    expect(connection.status, WearableStatus.disconnected);
    expect(connection.latest, isNull);
    expect(calls, contains('disconnect'));
  });

  test(
    'unknown events fail safely and unsupported platform avoids channels',
    () async {
      await connection.connect();
      await emit({'type': 'unknown'});
      expect(connection.status, WearableStatus.error);
      final unsupported = WearableConnection(android: false);
      await unsupported.connect();
      expect(unsupported.status, WearableStatus.unsupported);
      unsupported.dispose();
    },
  );

  test('old Wi-Fi settings error cannot clear a newer live session', () async {
    final gate = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(commands, (call) async {
          if (call.method == 'openWifiSettings') return gate.future;
          return null;
        });
    final settings = connection.openWifiSettings();
    await connection.connect();
    await emit(sample());
    gate.completeError(PlatformException(code: 'settings_unavailable'));
    await settings;
    expect(connection.status, WearableStatus.live);
    expect(connection.latest!.fsr, 1200);
  });

  test('reconnect waits until delayed event cancellation finishes', () async {
    final gate = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('rehab/wearable/events'),
          (call) async {
            if (call.method == 'cancel') return gate.future;
            return null;
          },
        );
    await connection.connect();
    final stopped = connection.disconnect();
    await connection.connect();
    expect(connection.commandPending, isTrue);
    expect(calls.where((call) => call == 'connect').length, 1);
    gate.complete(null);
    await stopped;
    await connection.connect();
    expect(calls.last, 'connect');
    expect(connection.status, WearableStatus.connecting);
  });

  test('dispose releases native worker and ignores queued readings', () async {
    await connection.connect();
    connection.dispose();
    await emit(sample());
    expect(connection.latest, isNull);
    expect(calls, contains('disconnect'));
  });
}
