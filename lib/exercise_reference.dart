import 'package:flutter/services.dart';

const exerciseNames = {'squat': 'Squat', 'sit_to_stand': 'Sit-to-stand'};

class ExerciseReference {
  const ExerciseReference({
    required this.exerciseId,
    required this.peakDeg,
    required this.bendThresholdDeg,
    required this.uprightBandDeg,
    required this.recordedAt,
  });
  final String exerciseId, recordedAt;
  final double peakDeg, bendThresholdDeg, uprightBandDeg;

  factory ExerciseReference.fromJson(Map<String, dynamic> json) {
    double angle(String key) {
      final value = json[key];
      if (value is! num || !value.isFinite || value <= 0 || value > 180) {
        throw FormatException('Invalid $key');
      }
      return value.toDouble();
    }

    final id = json['exercise_id'];
    final date = json['recorded_at'];
    if (!exerciseNames.containsKey(id) ||
        json['measurement_version'] != 'thigh_tilt_v1' ||
        json['placement'] != 'front_thigh' ||
        date is! String ||
        DateTime.tryParse(date) == null ||
        !DateTime.parse(date).isUtc) {
      throw const FormatException('Invalid exercise reference');
    }
    final peak = angle('reference_peak_deg');
    final bend = angle('bend_threshold_deg');
    final upright = angle('upright_band_deg');
    if (upright >= bend || bend > peak) {
      throw const FormatException('Invalid movement bands');
    }
    return ExerciseReference(
      exerciseId: id as String,
      peakDeg: peak,
      bendThresholdDeg: bend,
      uprightBandDeg: upright,
      recordedAt: date,
    );
  }

  Map<String, dynamic> toJson() => {
    'exercise_id': exerciseId,
    'measurement_version': 'thigh_tilt_v1',
    'reference_peak_deg': peakDeg,
    'bend_threshold_deg': bendThresholdDeg,
    'upright_band_deg': uprightBandDeg,
    'placement': 'front_thigh',
    'recorded_at': recordedAt,
  };
}

class ExerciseReferenceStore {
  ExerciseReferenceStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('rehab/wearable');
  final MethodChannel _channel;

  Future<List<ExerciseReference>> load() async {
    final result = await _channel.invokeMethod<dynamic>(
      'getExerciseReferences',
    );
    if (result is! List) {
      throw const FormatException('Invalid saved references');
    }
    return result.map((row) {
      if (row is! Map) throw const FormatException('Invalid saved reference');
      return ExerciseReference.fromJson(Map<String, dynamic>.from(row));
    }).toList();
  }

  Future<ExerciseReference> save(ExerciseReference reference) async {
    final payload = ExerciseReference.fromJson(reference.toJson()).toJson();
    final result = await _channel.invokeMethod<dynamic>(
      'saveExerciseReference',
      payload,
    );
    if (result is! Map) throw const FormatException('Invalid saved reference');
    return ExerciseReference.fromJson(Map<String, dynamic>.from(result));
  }
}

class ThighExerciseResult {
  const ThighExerciseResult({
    required this.repetitions,
    this.repTarget,
    required this.activeS,
    this.latestPeakDeg,
    this.referencePeakDeg,
    this.differenceDeg,
    required this.outcome,
  });

  final int repetitions;
  final int? repTarget;
  final double activeS;
  final double? latestPeakDeg, referencePeakDeg, differenceDeg;
  final String outcome;

  factory ThighExerciseResult.fromJson(Map<String, dynamic> json) {
    const keys = {
      'repetitions',
      'rep_target',
      'active_s',
      'latest_peak_deg',
      'reference_peak_deg',
      'difference_deg',
      'outcome',
    };
    final repetitions = json['repetitions'];
    final target = json['rep_target'];
    final seconds = json['active_s'];
    final outcome = json['outcome'];
    if (!keys.every(json.containsKey) ||
        repetitions is! int ||
        repetitions < 0 ||
        (target != null && (target is! int || target < 1 || target > 1000)) ||
        seconds is! num ||
        !seconds.isFinite ||
        seconds < 0 ||
        !const {
          'target_reached',
          'ended_early',
          'interrupted',
        }.contains(outcome) ||
        (target is int && repetitions > target) ||
        (outcome == 'target_reached' &&
            (target == null || repetitions != target))) {
      throw const FormatException('Invalid thigh exercise result');
    }
    double? metric(String key, {bool signed = false}) {
      final value = json[key];
      if (value == null) return null;
      if (value is! num ||
          !value.isFinite ||
          value.abs() > 180 ||
          (!signed && value < 0)) {
        throw FormatException('Invalid result $key');
      }
      return value.toDouble();
    }

    final latest = metric('latest_peak_deg');
    final reference = metric('reference_peak_deg');
    final difference = metric('difference_deg', signed: true);
    if (((latest == null || reference == null) && difference != null) ||
        (latest != null &&
            reference != null &&
            (difference == null ||
                (difference - (latest - reference)).abs() > 0.000001))) {
      throw const FormatException('Invalid reference difference');
    }
    return ThighExerciseResult(
      repetitions: repetitions,
      repTarget: target as int?,
      activeS: seconds.toDouble(),
      latestPeakDeg: latest,
      referencePeakDeg: reference,
      differenceDeg: difference,
      outcome: outcome as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'repetitions': repetitions,
    'rep_target': repTarget,
    'active_s': activeS,
    'latest_peak_deg': latestPeakDeg,
    'reference_peak_deg': referencePeakDeg,
    'difference_deg': differenceDeg,
    'outcome': outcome,
  };
}

class ThighAnalytics {
  const ThighAnalytics({
    required this.state,
    this.exerciseId,
    this.reason,
    this.zeroProgress = 0,
    this.tiltDeg,
    this.referencePeakDeg,
    this.recordedPeakDeg,
    this.latestPeakDeg,
    this.differenceDeg,
    this.repetitions = 0,
    this.result,
  });
  final String state;
  final String? exerciseId, reason;
  final double zeroProgress;
  final double? tiltDeg,
      referencePeakDeg,
      recordedPeakDeg,
      latestPeakDeg,
      differenceDeg;
  final int repetitions;
  final ThighExerciseResult? result;

  factory ThighAnalytics.fromJson(Map<String, dynamic> json) {
    double? metric(String key, {bool signed = false}) {
      final value = json[key];
      if (value == null) return null;
      if (value is! num ||
          !value.isFinite ||
          (!signed && value < 0) ||
          value.abs() > 180) {
        throw FormatException('Invalid thigh $key');
      }
      return value.toDouble();
    }

    final state = json['state'];
    final id = json['exercise_id'];
    final reason = json['reason'];
    final progress = json['zero_progress'];
    final count = json['repetitions'];
    final result = json['result'];
    if (!const {
          'idle',
          'zeroing',
          'recording',
          'reference_ready',
          'active',
          'ended',
          'interrupted',
        }.contains(state) ||
        (id != null && !exerciseNames.containsKey(id)) ||
        (reason != null && reason is! String) ||
        progress is! num ||
        !progress.isFinite ||
        progress < 0 ||
        progress > 1 ||
        count is! int ||
        count < 0 ||
        (result != null && result is! Map<String, dynamic>)) {
      throw const FormatException('Invalid thigh analytics');
    }
    return ThighAnalytics(
      state: state as String,
      exerciseId: id as String?,
      reason: reason as String?,
      zeroProgress: progress.toDouble(),
      repetitions: count,
      tiltDeg: metric('tilt_deg'),
      referencePeakDeg: metric('reference_peak_deg'),
      recordedPeakDeg: metric('recorded_peak_deg'),
      latestPeakDeg: metric('latest_peak_deg'),
      differenceDeg: metric('difference_deg', signed: true),
      result: result == null
          ? null
          : ThighExerciseResult.fromJson(result as Map<String, dynamic>),
    );
  }

  ThighAnalytics unavailable(String message) => ThighAnalytics(
    state: 'interrupted',
    exerciseId: exerciseId,
    reason: message,
    referencePeakDeg: referencePeakDeg,
    repetitions: repetitions,
    result: result,
  );
}
