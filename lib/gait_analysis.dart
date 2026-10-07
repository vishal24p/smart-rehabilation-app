import 'package:flutter/services.dart';

const gaitTimingKeys = [
  'cadence_spm',
  'right_step_time_s',
  'left_step_time_s',
  'right_stride_time_s',
  'left_stride_time_s',
];

const gaitMetricLabels = {
  'duration_s': 'Trial duration (s)',
  'distance_m': 'Entered distance (m)',
  'right_steps': 'Right steps',
  'left_steps': 'Left steps',
  'right_strides': 'Right complete strides',
  'left_strides': 'Left complete strides',
  'cadence_spm': 'Cadence (steps/min)',
  'right_step_time_s': 'Right step time (s)',
  'left_step_time_s': 'Left step time (s)',
  'right_stride_time_s': 'Right stride time (s)',
  'left_stride_time_s': 'Left stride time (s)',
  'timing_asymmetry_pct': 'Step timing asymmetry (%)',
  'right_forefoot_loaded_s': 'Right forefoot loaded, mean (s)',
  'left_forefoot_loaded_s': 'Left forefoot loaded, mean (s)',
  'right_forefoot_unloaded_s': 'Right forefoot unloaded, mean (s)',
  'left_forefoot_unloaded_s': 'Left forefoot unloaded, mean (s)',
  'right_leg_excursion_deg': 'Right-leg angular excursion (°)',
  'speed_mps': 'Trial average speed (m/s)',
  'average_step_length_m': 'Approx. average step length (m)',
  'average_stride_length_m': 'Approx. average stride length (m)',
};

double _number(Object? value, String key, {bool positive = false}) {
  if (value is! num ||
      !value.isFinite ||
      value < 0 ||
      (positive && value == 0)) {
    throw FormatException('Invalid gait $key');
  }
  return value.toDouble();
}

Map<String, dynamic> _map(Object? value) {
  if (value is! Map) throw const FormatException('Invalid gait payload');
  if (value.keys.any((key) => key is! String)) {
    throw const FormatException('Invalid gait keys');
  }
  return Map<String, dynamic>.from(value);
}

class GaitReference {
  GaitReference._(
    this.recordedAt,
    this.rightStrides,
    this.leftStrides,
    this.metrics,
  );

  final String recordedAt;
  final int rightStrides, leftStrides;
  final Map<String, double> metrics;

  factory GaitReference.fromJson(Map<String, dynamic> json) {
    final date = json['recorded_at'];
    final parsed = date is String ? DateTime.tryParse(date) : null;
    final right = json['right_strides'], left = json['left_strides'];
    const keys = {
      'measurement_version',
      'placement',
      'recorded_at',
      'right_strides',
      'left_strides',
      'metrics',
    };
    if (json.length != keys.length ||
        !keys.every(json.containsKey) ||
        json['measurement_version'] != 'gait_forefoot_timing_v1' ||
        json['placement'] != 'right_thigh_shin_bilateral_forefeet' ||
        parsed == null ||
        parsed.year < 1 ||
        !parsed.isUtc ||
        !(date as String).endsWith('Z') ||
        !RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$',
        ).hasMatch(date) ||
        parsed.toIso8601String().substring(0, 19) != date.substring(0, 19) ||
        right is! int ||
        left is! int ||
        right < 10 ||
        left < 10) {
      throw const FormatException('Invalid gait reference');
    }
    final raw = _map(json['metrics']);
    if (raw.length != gaitTimingKeys.length ||
        !gaitTimingKeys.every(raw.containsKey)) {
      throw const FormatException('Invalid reference metrics');
    }
    return GaitReference._(
      date,
      right,
      left,
      Map.unmodifiable({
        for (final key in gaitTimingKeys)
          key: _number(raw[key], key, positive: true),
      }),
    );
  }

  Map<String, dynamic> toJson() => {
    'measurement_version': 'gait_forefoot_timing_v1',
    'placement': 'right_thigh_shin_bilateral_forefeet',
    'recorded_at': recordedAt,
    'right_strides': rightStrides,
    'left_strides': leftStrides,
    'metrics': Map<String, double>.from(metrics),
  };
}

class GaitReferenceStore {
  GaitReferenceStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('rehab/wearable');
  final MethodChannel _channel;

  Future<GaitReference?> load() async {
    final raw = await _channel.invokeMethod<dynamic>('getGaitReference');
    return raw == null ? null : GaitReference.fromJson(_map(raw));
  }

  Future<GaitReference> save(GaitReference reference) async {
    final raw = await _channel.invokeMethod<dynamic>(
      'saveGaitReference',
      reference.toJson(),
    );
    return GaitReference.fromJson(_map(raw));
  }
}

class GaitMetrics {
  GaitMetrics._(this.values);
  final Map<String, num?> values;

  factory GaitMetrics.fromJson(Map<String, dynamic> json) {
    final result = <String, num?>{};
    for (final key in gaitMetricLabels.keys) {
      if (!json.containsKey(key)) throw FormatException('Missing gait $key');
      final value = json[key];
      if (key.endsWith('_steps') || key.endsWith('_strides')) {
        if (value is! int || value < 0) {
          throw FormatException('Invalid gait $key');
        }
        result[key] = value;
      } else {
        result[key] = value == null ? null : _number(value, key);
      }
    }
    if (result['duration_s'] == null) {
      throw const FormatException('Missing gait duration');
    }
    return GaitMetrics._(Map.unmodifiable(result));
  }

  factory GaitMetrics.empty() => GaitMetrics.fromJson({
    for (final key in gaitMetricLabels.keys)
      key:
          key == 'duration_s' ||
              key.endsWith('_steps') ||
              key.endsWith('_strides')
          ? 0
          : null,
  });
}

String? _comparison(Object? value) {
  if (value != null &&
      !const {
        'within_reference',
        'outside_reference',
        'insufficient_data',
      }.contains(value)) {
    throw const FormatException('Invalid gait comparison');
  }
  return value as String?;
}

class GaitDeviation {
  const GaitDeviation(this.metric, this.percent);
  final String metric;
  final double percent;
}

List<GaitDeviation> _deviations(Object? value) {
  if (value is! List) throw const FormatException('Invalid gait deviations');
  final seen = <String>{};
  return List.unmodifiable(
    value.map((row) {
      final json = _map(row);
      final metric = json['metric'];
      if (metric is! String ||
          !gaitTimingKeys.contains(metric) ||
          !seen.add(metric)) {
        throw const FormatException('Invalid gait deviation metric');
      }
      return GaitDeviation(metric, _number(json['deviation_pct'], metric));
    }),
  );
}

class GaitSummary {
  const GaitSummary(
    this.metrics,
    this.comparison,
    this.deviations,
    this.interrupted,
  );
  final GaitMetrics metrics;
  final String? comparison;
  final List<GaitDeviation> deviations;
  final bool interrupted;

  factory GaitSummary.fromJson(Map<String, dynamic> json) {
    if (json['interrupted'] is! bool || !json.containsKey('comparison')) {
      throw const FormatException('Invalid gait summary');
    }
    final result = GaitSummary(
      GaitMetrics.fromJson(_map(json['metrics'])),
      _comparison(json['comparison']),
      _deviations(json['deviations']),
      json['interrupted'] as bool,
    );
    if (result.interrupted && result.comparison != 'insufficient_data') {
      throw const FormatException('Interrupted trial cannot be classified');
    }
    final successful =
        result.comparison == 'within_reference' ||
        result.comparison == 'outside_reference';
    if (successful &&
        ((result.metrics.values['right_strides']! < 10) ||
            (result.metrics.values['left_strides']! < 10) ||
            !gaitTimingKeys.every(
              (key) => (result.metrics.values[key] ?? 0) > 0,
            ))) {
      throw const FormatException('Insufficient gait metrics for comparison');
    }
    if ((result.comparison == 'outside_reference') !=
        result.deviations.isNotEmpty) {
      throw const FormatException('Inconsistent gait comparison deviations');
    }
    return result;
  }
}

class GaitAnalytics {
  const GaitAnalytics({
    required this.state,
    this.reason,
    this.progress = 0,
    required this.metrics,
    this.comparison,
    this.deviations = const [],
    this.referencePreview,
    this.summary,
  });
  final String state;
  final String? reason, comparison;
  final double progress;
  final GaitMetrics metrics;
  final List<GaitDeviation> deviations;
  final GaitReference? referencePreview;
  final GaitSummary? summary;

  factory GaitAnalytics.fromJson(Map<String, dynamic> json) {
    final state = json['state'];
    final reason = json['reason'];
    final progress = _number(json['progress'], 'progress');
    if (!const {
          'setup',
          'forefoot_unloaded',
          'forefoot_loaded',
          'standing',
          'ready',
          'recording',
          'active',
          'reference_ready',
          'ended',
          'interrupted',
        }.contains(state) ||
        !json.containsKey('reason') ||
        (reason != null && reason is! String) ||
        progress > 1 ||
        !json.containsKey('comparison') ||
        !json.containsKey('reference_preview') ||
        !json.containsKey('summary')) {
      throw const FormatException('Invalid gait analytics');
    }
    final summary = json['summary'];
    final preview = json['reference_preview'];
    return GaitAnalytics(
      state: state as String,
      reason: reason as String?,
      progress: progress,
      metrics: GaitMetrics.fromJson(_map(json['metrics'])),
      comparison: _comparison(json['comparison']),
      deviations: _deviations(json['deviations']),
      referencePreview: preview == null
          ? null
          : GaitReference.fromJson(_map(preview)),
      summary: summary == null ? null : GaitSummary.fromJson(_map(summary)),
    );
  }

  GaitAnalytics unavailable(String message) => GaitAnalytics(
    state: 'interrupted',
    reason: message,
    metrics: GaitMetrics.empty(),
    comparison: 'insufficient_data',
    summary: summary,
  );
}
