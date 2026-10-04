import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum WearableStatus {
  idle,
  connecting,
  receiving,
  live,
  reconnecting,
  disconnected,
  error,
  unsupported,
}

class SensorSample {
  const SensorSample({
    required this.timeUs,
    required this.restart,
    required this.thighAccel,
    required this.thighGyro,
    required this.shinAccel,
    required this.shinGyro,
    required this.fsr,
    required this.scaled,
  });

  final int timeUs, fsr;
  final bool restart, scaled;
  final List<double> thighAccel, thighGyro, shinAccel, shinGyro;

  factory SensorSample.fromJson(Map<String, dynamic> json) {
    final time = json['time_us'];
    final fsr = json['fsr'];
    final scaled = json['scaled'];
    if (time is! int ||
        time < 0 ||
        time > 0xffffffff ||
        fsr is! int ||
        fsr < 0 ||
        fsr > 4095 ||
        scaled is! bool ||
        json['restart'] is! bool) {
      throw const FormatException('Invalid sensor sample');
    }
    List<double> vector(String key) {
      final values = json[key];
      if (values is! List ||
          values.length != 3 ||
          values.any(
            (v) =>
                v is! num ||
                !v.isFinite ||
                (!scaled && (v < -32768 || v > 32767 || v != v.round())),
          )) {
        throw const FormatException('Invalid motion readings');
      }
      return List<double>.unmodifiable(
        values.map((v) => (v as num).toDouble()),
      );
    }

    return SensorSample(
      timeUs: time,
      restart: json['restart'] as bool,
      thighAccel: vector('thigh_accel'),
      thighGyro: vector('thigh_gyro'),
      shinAccel: vector('shin_accel'),
      shinGyro: vector('shin_gyro'),
      fsr: fsr,
      scaled: scaled,
    );
  }
}

class HeelPoint {
  const HeelPoint(this.receivedAt, this.adc);
  final Duration receivedAt;
  final int adc;
}

class WearableConnection extends ChangeNotifier {
  WearableConnection({
    this.commands = const MethodChannel('rehab/wearable'),
    this.events = const EventChannel('rehab/wearable/events'),
    bool? android,
    Duration Function()? clock,
  }) : _android =
           android ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    final stopwatch = Stopwatch()..start();
    _clock = clock ?? () => stopwatch.elapsed;
  }

  final MethodChannel commands;
  final EventChannel events;
  final bool _android;
  late final Duration Function() _clock;
  StreamSubscription<dynamic>? _subscription;
  var _generation = 0;
  var _disposed = false;
  var _status = WearableStatus.idle;
  var _message = 'Connect your wearable to start receiving readings.';
  SensorSample? _latest;
  final _history = <HeelPoint>[];

  WearableStatus get status => _status;
  String get message => _message;
  SensorSample? get latest => _latest;
  List<HeelPoint> get history => List.unmodifiable(_history);
  bool get active => switch (_status) {
    WearableStatus.connecting ||
    WearableStatus.receiving ||
    WearableStatus.live ||
    WearableStatus.reconnecting => true,
    _ => false,
  };

  Future<void> connect({bool scaleConfirmed = false}) async {
    if (_disposed || active) return;
    if (!_android) {
      _setStatus(
        WearableStatus.unsupported,
        'Live wearable readings are available in the Android app.',
      );
      return;
    }
    final generation = ++_generation;
    await _subscription?.cancel();
    if (_disposed || generation != _generation) return;
    _setStatus(WearableStatus.connecting, 'Connecting to REHAB-WEARABLE…');
    _subscription = events.receiveBroadcastStream().listen(
      (event) {
        if (!_disposed && generation == _generation) _handleEvent(event);
      },
      onError: (Object error) {
        if (!_disposed && generation == _generation) {
          _setStatus(
            WearableStatus.error,
            'Connection unavailable. Retry or check Wi-Fi settings.',
          );
        }
      },
    );
    try {
      await commands.invokeMethod<void>('connect', {
        'scaleConfirmed': scaleConfirmed,
      });
    } on MissingPluginException {
      if (!_disposed && generation == _generation) {
        _setStatus(
          WearableStatus.unsupported,
          'Install the Android build with wearable support.',
        );
      }
    } on PlatformException catch (error) {
      if (!_disposed && generation == _generation) {
        _setStatus(
          WearableStatus.error,
          error.message ?? 'Unable to connect. Check Wi-Fi and retry.',
        );
      }
    }
  }

  void _handleEvent(dynamic event) {
    try {
      if (event is! String) throw const FormatException();
      final data = jsonDecode(event);
      if (data is! Map<String, dynamic>) throw const FormatException();
      if (data['type'] == 'status') {
        final status = WearableStatus.values
            .where((s) => s.name == data['status'])
            .firstOrNull;
        if (status == null) throw const FormatException();
        _setStatus(
          status == WearableStatus.live && _latest == null
              ? WearableStatus.receiving
              : status,
          data['message'] is String
              ? data['message'] as String
              : _defaultMessage(status),
        );
      } else if (data['type'] == 'sample') {
        final sample = SensorSample.fromJson(data);
        if (sample.restart ||
            (_latest != null && sample.timeUs < _latest!.timeUs)) {
          _history.clear();
        }
        _latest = sample;
        _status = WearableStatus.live;
        _message = 'Receiving live sensor readings';
        final now = _clock();
        _history.removeWhere(
          (point) => now - point.receivedAt > const Duration(seconds: 10),
        );
        _history.add(HeelPoint(now, sample.fsr));
        if (_history.length > 100) {
          _history.removeRange(0, _history.length - 100);
        }
        notifyListeners();
      } else {
        throw const FormatException();
      }
    } on FormatException {
      _setStatus(
        WearableStatus.error,
        'Unsupported sensor data. Check the wearable firmware.',
      );
    }
  }

  String _defaultMessage(WearableStatus status) => switch (status) {
    WearableStatus.receiving => 'Connected. Waiting for a valid sensor sample…',
    WearableStatus.reconnecting => 'Readings stopped. Reconnecting…',
    WearableStatus.disconnected =>
      'Wearable disconnected. Connect to try again.',
    WearableStatus.connecting => 'Connecting to REHAB-WEARABLE…',
    WearableStatus.live => 'Receiving live sensor readings',
    _ => 'Check the wearable connection and retry.',
  };

  void _setStatus(WearableStatus status, String message) {
    _status = status;
    _message = message;
    if (status != WearableStatus.live) {
      _latest = null;
      _history.clear();
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> disconnect() async {
    if (_disposed) return;
    ++_generation;
    final subscription = _subscription;
    _subscription = null;
    _setStatus(WearableStatus.disconnected, 'Wearable disconnected.');
    await subscription?.cancel();
    await _stopNative();
  }

  Future<void> _stopNative() async {
    if (!_android) return;
    try {
      await commands.invokeMethod<void>('disconnect');
    } on PlatformException {
      /* Local state is already disconnected. */
    } on MissingPluginException {
      /* No native worker exists on this platform. */
    }
  }

  Future<void> openWifiSettings() async {
    if (!_android || _disposed) return;
    try {
      await commands.invokeMethod<void>('openWifiSettings');
    } on PlatformException {
      _setStatus(
        WearableStatus.error,
        'Open Wi-Fi settings on your phone and join REHAB-WEARABLE.',
      );
    } on MissingPluginException {
      _setStatus(
        WearableStatus.unsupported,
        'Wi-Fi settings are available in the Android app.',
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    unawaited(_subscription?.cancel());
    unawaited(_stopNative());
    super.dispose();
  }
}
