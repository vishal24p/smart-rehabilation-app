import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'exercise_reference.dart';
import 'app_settings.dart';
import 'gait_analysis.dart';

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

enum RehabState {
  setup('setup'),
  heelZero('heel_zero'),
  heelUnloaded('heel_unloaded'),
  heelLoaded('heel_loaded'),
  standing('standing'),
  movementReady('movement_ready'),
  movement('movement'),
  ready('ready'),
  active('active'),
  ended('ended'),
  interrupted('interrupted'),
  needsCalibration('needs_calibration');

  const RehabState(this.wireName);
  final String wireName;
}

double? _metric(Map<String, dynamic> json, String key, {bool signed = false}) {
  if (!json.containsKey(key)) throw FormatException('Missing $key');
  final value = json[key];
  if (value == null) return null;
  if (value is! num || !value.isFinite || (!signed && value < 0)) {
    throw FormatException('Invalid $key');
  }
  return value.toDouble();
}

double? _share(Map<String, dynamic> json, String key) {
  if (json[key] == null) return null;
  final value = _metric(json, key);
  if (value! > 100) throw FormatException('Invalid $key');
  return value;
}

int? _cycles(Map<String, dynamic> json) {
  final value = json['cycles'];
  if (!json.containsKey('cycles') ||
      (value != null && (value is! int || value < 0))) {
    throw const FormatException('Invalid cycle count');
  }
  return value as int?;
}

class RehabSummary {
  const RehabSummary._({
    required this.cycles,
    required this.romDeg,
    required this.activeS,
    required this.cycleTimesS,
    required this.interrupted,
  });
  final int cycles;
  final double? romDeg;
  final double activeS;
  final List<double> cycleTimesS;
  final bool interrupted;

  factory RehabSummary.fromJson(Map<String, dynamic> json) {
    final cycles = _cycles(json);
    final activeS = _metric(json, 'active_s');
    final times = json['cycle_times_s'];
    if (cycles == null ||
        activeS == null ||
        json['interrupted'] is! bool ||
        times is! List ||
        times.length != cycles ||
        times.any((v) => v is! num || !v.isFinite || v < 0)) {
      throw const FormatException('Invalid session summary');
    }
    return RehabSummary._(
      cycles: cycles,
      romDeg: _metric(json, 'rom_deg'),
      activeS: activeS,
      cycleTimesS: List<double>.unmodifiable(
        times.map((v) => (v as num).toDouble()),
      ),
      interrupted: json['interrupted'] as bool,
    );
  }
}

class RehabAnalytics {
  const RehabAnalytics._({
    required this.state,
    required this.reason,
    required this.progress,
    this.angleDeg,
    this.romDeg,
    this.cycles,
    this.lastCycleS,
    this.heelContact,
    this.heelSaturated = false,
    this.leftHeelContact,
    this.leftHeelSaturated = false,
    this.heelShareRight,
    this.heelShareLeft,
    this.heelShareReason,
    this.heelZero,
    this.summary,
    this.thigh,
    this.gait,
  });
  final RehabState state;
  final String? reason;
  final double progress;
  final double? angleDeg, romDeg, lastCycleS;
  final int? cycles;
  final bool? heelContact;
  final bool heelSaturated;
  final bool? leftHeelContact;
  final bool leftHeelSaturated;
  final double? heelShareRight, heelShareLeft;
  final String? heelShareReason;
  final Map<String, dynamic>? heelZero;
  final RehabSummary? summary;
  final ThighAnalytics? thigh;
  final GaitAnalytics? gait;

  factory RehabAnalytics.fromJson(Map<String, dynamic> json) {
    final state = RehabState.values
        .where((s) => s.wireName == json['state'])
        .firstOrNull;
    final progress = _metric(json, 'progress');
    final contact = json['heel_contact'];
    final leftContact = json['left_heel_contact'];
    final leftSaturated = json['left_heel_saturated'];
    final shareReason = json['heel_share_reason'];
    final shareRight = _share(json, 'heel_share_right');
    final shareLeft = _share(json, 'heel_share_left');
    final summary = json['summary'];
    final thigh = json['thigh'];
    final gait = json['gait'];
    if (state == null ||
        !json.containsKey('reason') ||
        (json['reason'] != null && json['reason'] is! String) ||
        progress == null ||
        progress > 1 ||
        !json.containsKey('heel_contact') ||
        (contact != null && contact is! bool) ||
        json['heel_saturated'] is! bool ||
        (leftContact != null && leftContact is! bool) ||
        (json.containsKey('left_heel_saturated') && leftSaturated is! bool) ||
        (shareReason != null && shareReason is! String) ||
        ((shareRight == null) != (shareLeft == null)) ||
        (shareRight != null && (shareRight + shareLeft! - 100).abs() > 0.01) ||
        !json.containsKey('summary') ||
        (summary != null && summary is! Map<String, dynamic>) ||
        (thigh != null && thigh is! Map<String, dynamic>) ||
        (gait != null && gait is! Map<String, dynamic>) ||
        (json['heel_zero'] != null &&
            json['heel_zero'] is! Map<String, dynamic>)) {
      throw const FormatException('Invalid rehab analytics');
    }
    return RehabAnalytics._(
      state: state,
      reason: json['reason'] as String?,
      progress: progress,
      angleDeg: _metric(json, 'angle_deg', signed: true),
      romDeg: _metric(json, 'rom_deg'),
      cycles: _cycles(json),
      lastCycleS: _metric(json, 'last_cycle_s'),
      heelContact: contact as bool?,
      heelSaturated: json['heel_saturated'] as bool,
      leftHeelContact: leftContact as bool?,
      leftHeelSaturated: leftSaturated as bool? ?? false,
      heelShareRight: shareRight,
      heelShareLeft: shareLeft,
      heelShareReason: shareReason as String?,
      heelZero: json['heel_zero'] == null
          ? null
          : validateHeelZero(
              Map<String, dynamic>.from(json['heel_zero'] as Map),
            ),
      summary: summary == null
          ? null
          : RehabSummary.fromJson(summary as Map<String, dynamic>),
      thigh: thigh == null
          ? null
          : ThighAnalytics.fromJson(thigh as Map<String, dynamic>),
      gait: gait == null
          ? null
          : GaitAnalytics.fromJson(gait as Map<String, dynamic>),
    );
  }

  RehabAnalytics _withSummary(RehabSummary? value) => RehabAnalytics._(
    state: state,
    reason: reason,
    progress: progress,
    angleDeg: angleDeg,
    romDeg: romDeg,
    cycles: cycles,
    lastCycleS: lastCycleS,
    heelContact: heelContact,
    heelSaturated: heelSaturated,
    leftHeelContact: leftHeelContact,
    leftHeelSaturated: leftHeelSaturated,
    heelShareRight: heelShareRight,
    heelShareLeft: heelShareLeft,
    heelShareReason: heelShareReason,
    heelZero: heelZero,
    summary: value,
    thigh: thigh,
    gait: gait,
  );

  RehabAnalytics _unavailable(String reason) => RehabAnalytics._(
    state: RehabState.interrupted,
    reason: reason,
    progress: 0,
    summary: summary,
    thigh: thigh?.unavailable(reason),
    gait: gait?.unavailable(reason),
  );
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
    this.fsrLeft,
    required this.scaled,
  });

  final int timeUs, fsr;
  final int? fsrLeft;
  final bool restart, scaled;
  final List<double>? thighAccel, thighGyro, shinAccel, shinGyro;

  factory SensorSample.fromJson(Map<String, dynamic> json) {
    final time = json['time_us'];
    final fsr = json['fsr'];
    final fsrLeft = json['fsr_left'];
    final scaled = json['scaled'];
    if (time is! int ||
        time < 0 ||
        time > 0xffffffff ||
        fsr is! int ||
        fsr < 0 ||
        fsr > 4095 ||
        (fsrLeft != null &&
            (fsrLeft is! int || fsrLeft < 0 || fsrLeft > 4095)) ||
        scaled is! bool ||
        json['restart'] is! bool) {
      throw const FormatException('Invalid sensor sample');
    }
    List<double>? vector(String key) {
      if (!json.containsKey(key)) throw FormatException('Missing $key');
      final values = json[key];
      if (values == null) return null;
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

    final thighAccel = vector('thigh_accel');
    final thighGyro = vector('thigh_gyro');
    final shinAccel = vector('shin_accel');
    final shinGyro = vector('shin_gyro');
    if ((thighAccel == null) != (thighGyro == null) ||
        (shinAccel == null) != (shinGyro == null)) {
      throw const FormatException('Incomplete motion readings');
    }
    return SensorSample(
      timeUs: time,
      restart: json['restart'] as bool,
      thighAccel: thighAccel,
      thighGyro: thighGyro,
      shinAccel: shinAccel,
      shinGyro: shinGyro,
      fsr: fsr,
      fsrLeft: fsrLeft as int?,
      scaled: scaled,
    );
  }
}

class HeelPoint {
  const HeelPoint(this.receivedAt, this.adc, {this.leftAdc});
  final Duration receivedAt;
  final int adc;
  final int? leftAdc;
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
  Future<void>? _disconnecting;
  var _generation = 0;
  var _disposed = false;
  var _status = WearableStatus.idle;
  var _message = 'Connect your wearable to start receiving readings.';
  SensorSample? _latest;
  RehabAnalytics? _analytics;
  var _commandPending = false;
  String? _commandError;
  final _history = <HeelPoint>[];

  WearableStatus get status => _status;
  String get message => _message;
  SensorSample? get latest => _latest;
  RehabAnalytics? get analytics => _analytics;
  ThighAnalytics? get thigh => _analytics?.thigh;
  GaitAnalytics? get gait => _analytics?.gait;
  bool get commandPending => _commandPending || _disconnecting != null;
  String? get commandError => _commandError;
  List<HeelPoint> get history => List.unmodifiable(_history);
  bool get active => switch (_status) {
    WearableStatus.connecting ||
    WearableStatus.receiving ||
    WearableStatus.live ||
    WearableStatus.reconnecting => true,
    _ => false,
  };

  Future<void> connect({bool scaleConfirmed = false}) async {
    if (_disposed || active || _disconnecting != null) return;
    if (!_android) {
      _setStatus(
        WearableStatus.unsupported,
        'Live wearable readings are available in the Android app.',
      );
      return;
    }
    final generation = ++_generation;
    _commandPending = false;
    _commandError = null;
    await _subscription?.cancel();
    if (_disposed || generation != _generation) return;
    _setStatus(WearableStatus.connecting, 'Connecting to REHAB…');
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
        if (data.containsKey('analytics')) {
          _acceptAnalytics(_decodeAnalytics(data['analytics']));
        }
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
        _history.add(HeelPoint(now, sample.fsr, leftAdc: sample.fsrLeft));
        if (_history.length > 100) {
          _history.removeRange(0, _history.length - 100);
        }
        notifyListeners();
      } else if (data['type'] == 'analytics') {
        _acceptAnalytics(_decodeAnalytics(data['analytics']));
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

  RehabAnalytics _decodeAnalytics(dynamic data) {
    if (data is! Map<String, dynamic>) throw const FormatException();
    return RehabAnalytics.fromJson(data);
  }

  void _acceptAnalytics(RehabAnalytics snapshot) {
    _analytics = snapshot._withSummary(snapshot.summary ?? _analytics?.summary);
  }

  Future<void> sendSessionCommand(
    String action, {
    Map<String, dynamic>? config,
  }) async {
    if (_disposed || commandPending) return;
    if (_status != WearableStatus.live) {
      _commandError = 'Connect and wait for live readings before calibration.';
      notifyListeners();
      return;
    }
    final generation = _generation;
    _commandPending = true;
    _commandError = null;
    notifyListeners();
    try {
      final response = await commands.invokeMethod<dynamic>('sessionCommand', {
        'action': action,
        'config': ?config,
      });
      if (!_disposed && generation == _generation && response is String) {
        _acceptAnalytics(_decodeAnalytics(jsonDecode(response)));
      }
      if (!_disposed &&
          generation == _generation &&
          action == 'start' &&
          _analytics?.state == RehabState.active) {
        _analytics = _analytics!._withSummary(null);
      }
    } on PlatformException catch (error) {
      if (!_disposed && generation == _generation) {
        _commandError =
            error.message ??
            'Session command failed. Check readings and retry.';
      }
    } on MissingPluginException {
      if (!_disposed && generation == _generation) {
        _commandError = 'Install the Android build with session support.';
      }
    } finally {
      if (!_disposed && generation == _generation) {
        _commandPending = false;
        notifyListeners();
      }
    }
  }

  String _defaultMessage(WearableStatus status) => switch (status) {
    WearableStatus.receiving => 'Connected. Waiting for a valid sensor sample…',
    WearableStatus.reconnecting => 'Readings stopped. Reconnecting…',
    WearableStatus.disconnected =>
      'Wearable disconnected. Connect to try again.',
    WearableStatus.connecting => 'Connecting to REHAB…',
    WearableStatus.live => 'Receiving live sensor readings',
    _ => 'Check the wearable connection and retry.',
  };

  void _setStatus(WearableStatus status, String message) {
    _status = status;
    _message = message;
    if (status != WearableStatus.live) {
      _latest = null;
      _history.clear();
      _analytics = _analytics?._unavailable(message);
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> disconnect() {
    if (_disposed) return Future.value();
    return _disconnecting ??= Future<void>.microtask(_disconnect).whenComplete(
      () {
        _disconnecting = null;
        if (!_disposed) notifyListeners();
      },
    );
  }

  Future<void> _disconnect() async {
    if (_disposed) return;
    final generation = ++_generation;
    _commandPending = false;
    _commandError = null;
    // Reconnect must cancel this listener before installing a new channel handler.
    final subscription = _subscription;
    _setStatus(WearableStatus.disconnected, 'Wearable disconnected.');
    final snapshot = await _stopNative();
    if (!_disposed && generation == _generation && snapshot != null) {
      try {
        _acceptAnalytics(_decodeAnalytics(jsonDecode(snapshot)));
        _analytics = _analytics!._unavailable(
          'Readings stopped. Repeat calibration before starting.',
        );
        notifyListeners();
      } on FormatException {
        _commandError =
            'Session summary unavailable. Repeat calibration after reconnecting.';
        notifyListeners();
      }
    }
    await subscription?.cancel();
    if (identical(_subscription, subscription)) _subscription = null;
  }

  Future<String?> _stopNative() async {
    if (!_android) return null;
    try {
      return await commands.invokeMethod<String>('disconnect');
    } on PlatformException {
      /* Local state is already disconnected. */
    } on MissingPluginException {
      /* No native worker exists on this platform. */
    }
    return null;
  }

  Future<void> openWifiSettings() async {
    if (!_android || _disposed) return;
    final generation = _generation;
    try {
      await commands.invokeMethod<void>('openWifiSettings');
    } on PlatformException {
      if (_disposed || generation != _generation) return;
      _setStatus(
        WearableStatus.error,
        'Open Wi-Fi settings on your phone and join REHAB.',
      );
    } on MissingPluginException {
      if (_disposed || generation != _generation) return;
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
