import 'package:flutter/services.dart';

Map<String, dynamic> validateHeelZero(Map<String, dynamic> json) {
  if (json.length != 4 || json['version'] != 1 || json['adc_max'] != 1023) {
    throw const FormatException('Invalid heel baseline');
  }
  final result = <String, dynamic>{'version': 1, 'adc_max': 1023};
  for (final side in ['left', 'right']) {
    final values = json[side];
    if (values is! Map || values.length != 2) {
      throw const FormatException('Invalid heel baseline');
    }
    final baseline = values['baseline'];
    final deadband = values['deadband'];
    if (baseline is! num ||
        !baseline.isFinite ||
        baseline < 0 ||
        baseline > 1022 ||
        deadband is! num ||
        !deadband.isFinite ||
        deadband < 5 ||
        deadband > 1023) {
      throw const FormatException('Invalid heel baseline');
    }
    result[side] = Map<String, double>.unmodifiable({
      'baseline': baseline.toDouble(),
      'deadband': deadband.toDouble(),
    });
  }
  return Map<String, dynamic>.unmodifiable(result);
}

class AppSettings {
  const AppSettings({
    this.injuredLeg,
    this.heelZero,
    this.repTargets = const {'squat': 10, 'sit_to_stand': 10},
  });
  final String? injuredLeg;
  final Map<String, dynamic>? heelZero;
  final Map<String, int> repTargets;

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final leg = json['injured_leg'];
    final zero = json['heel_zero'];
    if ((json.length != 2 && json.length != 3) ||
        json.keys.any(
          (key) =>
              !const {'injured_leg', 'heel_zero', 'rep_targets'}.contains(key),
        ) ||
        !json.containsKey('injured_leg') ||
        !json.containsKey('heel_zero') ||
        (leg != null && leg != 'left' && leg != 'right') ||
        (zero != null && zero is! Map)) {
      throw const FormatException('Invalid settings');
    }
    final targets = json.containsKey('rep_targets')
        ? json['rep_targets']
        : const {'squat': 10, 'sit_to_stand': 10};
    if (targets is! Map ||
        targets.length != 2 ||
        ['squat', 'sit_to_stand'].any(
          (id) =>
              targets[id] is! int ||
              (targets[id] as int) < 1 ||
              (targets[id] as int) > 1000,
        )) {
      throw const FormatException('Invalid repetition targets');
    }
    return AppSettings(
      injuredLeg: leg as String?,
      heelZero: zero == null
          ? null
          : validateHeelZero(Map<String, dynamic>.from(zero as Map)),
      repTargets: Map<String, int>.unmodifiable(Map<String, int>.from(targets)),
    );
  }

  AppSettings copyWith({
    String? injuredLeg,
    Map<String, dynamic>? heelZero,
    Map<String, int>? repTargets,
  }) => AppSettings(
    injuredLeg: injuredLeg ?? this.injuredLeg,
    heelZero: heelZero ?? this.heelZero,
    repTargets: repTargets ?? this.repTargets,
  );

  Map<String, dynamic> toJson() => {
    'injured_leg': injuredLeg,
    'heel_zero': heelZero,
    'rep_targets': repTargets,
  };
}

class AppSettingsStore {
  const AppSettingsStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('rehab/wearable');
  final MethodChannel _channel;

  Future<AppSettings> load() async {
    final result = await _channel.invokeMethod<dynamic>('getSettings');
    if (result is! Map) throw const FormatException('Invalid saved settings');
    return AppSettings.fromJson(Map<String, dynamic>.from(result));
  }

  Future<AppSettings> save(AppSettings settings) async {
    final payload = AppSettings.fromJson(settings.toJson()).toJson();
    final result = await _channel.invokeMethod<dynamic>(
      'saveSettings',
      payload,
    );
    if (result is! Map) throw const FormatException('Invalid saved settings');
    return AppSettings.fromJson(Map<String, dynamic>.from(result));
  }
}
