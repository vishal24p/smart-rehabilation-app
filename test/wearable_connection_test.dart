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

Future<void> emit(Map<String, Object> data) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        events.name,
        codec.encodeSuccessEnvelope(jsonEncode(data)),
        (_) {},
      );
  await Future<void>.delayed(Duration.zero);
}

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

  test('delayed disconnect cleanup cannot stop a newer connection', () async {
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
    gate.complete(null);
    await stopped;
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
