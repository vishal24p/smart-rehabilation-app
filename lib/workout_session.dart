import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'exercise_reference.dart';
import 'wearable_connection.dart';

String _newId() =>
    '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(0x7fffffff)}';

String _id(dynamic value) {
  if (value is! String || value.isEmpty || value.length > 100) {
    throw const FormatException('Invalid session identity');
  }
  return value;
}

DateTime _date(dynamic value) {
  if (value is! String) throw const FormatException('Invalid session date');
  final date = DateTime.tryParse(value);
  if (date == null ||
      !date.isUtc ||
      value.length < 20 ||
      date.toIso8601String().substring(0, 19) != value.substring(0, 19)) {
    throw const FormatException('Invalid session date');
  }
  return date;
}

class WorkoutAttempt {
  const WorkoutAttempt({
    required this.id,
    required this.exerciseId,
    required this.startedAt,
    required this.endedAt,
    required this.result,
  });
  final String id, exerciseId;
  final DateTime startedAt, endedAt;
  final ThighExerciseResult result;

  factory WorkoutAttempt.fromJson(Map<String, dynamic> json) {
    if (json.length != 5 ||
        !exerciseNames.containsKey(json['exercise_id']) ||
        json['result'] is! Map) {
      throw const FormatException('Invalid exercise result');
    }
    final start = _date(json['started_at']), end = _date(json['ended_at']);
    final result = ThighExerciseResult.fromJson(
      Map<String, dynamic>.from(json['result'] as Map),
    );
    if (end.isBefore(start) ||
        result.repTarget == null ||
        result.repetitions > result.repTarget!) {
      throw const FormatException('Invalid exercise result');
    }
    return WorkoutAttempt(
      id: _id(json['id']),
      exerciseId: json['exercise_id'] as String,
      startedAt: start,
      endedAt: end,
      result: result,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'exercise_id': exerciseId,
    'started_at': startedAt.toUtc().toIso8601String(),
    'ended_at': endedAt.toUtc().toIso8601String(),
    'result': result.toJson(),
  };
}

class WorkoutSession {
  const WorkoutSession({
    required this.id,
    required this.startedAt,
    this.endedAt,
    this.status = 'active',
    this.exercises = const [],
  });
  final String id, status;
  final DateTime startedAt;
  final DateTime? endedAt;
  final List<WorkoutAttempt> exercises;
  int get totalReps =>
      exercises.fold(0, (total, item) => total + item.result.repetitions);

  factory WorkoutSession.fromJson(Map<String, dynamic> json) {
    final status = json['status'], rows = json['exercises'];
    if (json.length != 5 ||
        !{'active', 'ended'}.contains(status) ||
        rows is! List ||
        (status == 'active') != (json['ended_at'] == null)) {
      throw const FormatException('Invalid saved session');
    }
    final start = _date(json['started_at']);
    final end = json['ended_at'] == null ? null : _date(json['ended_at']);
    var previousEnd = start;
    final ids = <String>{};
    final attempts = rows.map((row) {
      if (row is! Map) throw const FormatException('Invalid exercise result');
      final attempt = WorkoutAttempt.fromJson(Map<String, dynamic>.from(row));
      if (!ids.add(attempt.id) ||
          attempt.startedAt.isBefore(previousEnd) ||
          (end != null && attempt.endedAt.isAfter(end))) {
        throw const FormatException('Invalid exercise order');
      }
      previousEnd = attempt.endedAt;
      return attempt;
    }).toList();
    if (end != null && end.isBefore(start)) {
      throw const FormatException('Invalid session end');
    }
    return WorkoutSession(
      id: _id(json['id']),
      startedAt: start,
      endedAt: end,
      status: status as String,
      exercises: List.unmodifiable(attempts),
    );
  }

  WorkoutSession withExercises(List<WorkoutAttempt> attempts) => WorkoutSession(
    id: id,
    startedAt: startedAt,
    endedAt: endedAt,
    status: status,
    exercises: List.unmodifiable(attempts),
  );
  WorkoutSession ended(DateTime end) => WorkoutSession(
    id: id,
    startedAt: startedAt,
    endedAt: end,
    status: 'ended',
    exercises: exercises,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'started_at': startedAt.toUtc().toIso8601String(),
    'ended_at': endedAt?.toUtc().toIso8601String(),
    'status': status,
    'exercises': exercises.map((item) => item.toJson()).toList(),
  };
}

class WorkoutSessionStore {
  const WorkoutSessionStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('rehab/wearable');
  final MethodChannel _channel;
  Future<List<WorkoutSession>> load() async {
    final rows = await _channel.invokeMethod<dynamic>('getWorkoutSessions');
    if (rows is! List) throw const FormatException('Invalid saved sessions');
    return rows.map((row) {
      if (row is! Map) throw const FormatException('Invalid saved session');
      return WorkoutSession.fromJson(Map<String, dynamic>.from(row));
    }).toList();
  }

  Future<WorkoutSession> save(WorkoutSession session) async {
    final payload = WorkoutSession.fromJson(session.toJson()).toJson();
    final row = await _channel.invokeMethod<dynamic>(
      'saveWorkoutSession',
      payload,
    );
    if (row is! Map) throw const FormatException('Invalid saved session');
    final saved = WorkoutSession.fromJson(Map<String, dynamic>.from(row));
    if (saved.id != session.id) {
      throw const FormatException('Invalid saved session identity');
    }
    return saved;
  }
}

class WorkoutSessionController extends ChangeNotifier {
  WorkoutSessionController({
    required this.connection,
    required this.targets,
    this.store = const WorkoutSessionStore(),
  }) {
    connection.addListener(_changed);
  }
  final WearableConnection connection;
  final Map<String, int> targets;
  final WorkoutSessionStore store;
  WorkoutSession? _record, _pending;
  String? _attemptId, _exerciseId;
  DateTime? _attemptStart;
  bool _sawRunning = false, _sawActive = false, _disposed = false;
  Future<bool>? _write;
  bool busy = false;
  String? error;
  WorkoutSession? get record => _record;
  WorkoutSession? get preview => _pending ?? _record;
  bool get hasAttempt => _attemptId != null;
  bool get needsRetry => _pending != null && !busy;
  bool get canChoose =>
      _record?.status == 'active' && !hasAttempt && !busy && _pending == null;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<bool> start() =>
      _persist(WorkoutSession(id: _newId(), startedAt: DateTime.now().toUtc()));

  Future<bool> _persist(WorkoutSession value) {
    if (busy) return _write ?? Future.value(false);
    _pending = value;
    busy = true;
    error = null;
    _notify();
    return _write = _save(value);
  }

  Future<bool> _save(WorkoutSession value) async {
    try {
      _record = await store.save(value);
      _pending = null;
      if (_attemptId != null &&
          _record!.exercises.any((item) => item.id == _attemptId)) {
        _attemptId = null;
      }
      return true;
    } catch (_) {
      error = 'Session not saved. Retry before continuing.';
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> retry() =>
      _pending == null ? Future.value(true) : _persist(_pending!);

  Future<bool> beginExercise(
    String exerciseId,
    ExerciseReference reference,
  ) async {
    if (!canChoose) return false;
    final target = targets[exerciseId];
    if (target == null || target < 1 || target > 1000) {
      error = 'Set the exercise target in Settings.';
      _notify();
      return false;
    }
    _attemptId = _newId();
    _exerciseId = exerciseId;
    _attemptStart = DateTime.now().toUtc();
    _sawRunning = _sawActive = false;
    error = null;
    await connection.sendSessionCommand(
      'thigh_session_begin',
      config: {
        'exercise_id': exerciseId,
        'reference': reference.toJson(),
        'rep_target': target,
      },
    );
    if (connection.commandError != null || !_sawRunning) {
      _attemptId = null;
      error =
          connection.commandError ??
          connection.thigh?.reason ??
          'Exercise did not start. Retry.';
      _notify();
      return false;
    }
    return true;
  }

  void _changed() {
    if (_disposed || _attemptId == null || _pending != null) return;
    final thigh = connection.thigh;
    if (thigh?.state == 'idle' && _sawRunning && !_sawActive && thigh?.result == null) {
      _attemptId = null;
      _notify();
      return;
    }
    if (thigh?.exerciseId != _exerciseId) return;
    if (thigh!.state == 'zeroing' || thigh.state == 'active') {
      _sawRunning = true;
    }
    if (thigh.state == 'active') _sawActive = true;
    final result = thigh.result;
    if (thigh.state == 'idle' && _sawRunning && !_sawActive) {
      _attemptId = null;
      _notify();
      return;
    }
    if (thigh.state == 'interrupted' && result == null && _sawRunning && !_sawActive) {
      _attemptId = null;
      _notify();
      return;
    }
    if (!_sawRunning || result == null) return;
    final attempt = WorkoutAttempt(
      id: _attemptId!,
      exerciseId: _exerciseId!,
      startedAt: _attemptStart!,
      endedAt: DateTime.now().toUtc(),
      result: result,
    );
    unawaited(
      _persist(_record!.withExercises([..._record!.exercises, attempt])),
    );
  }

  Future<bool> endExercise() async {
    if (connection.commandPending) return false;
    if (!hasAttempt) return _pending == null;
    if (busy) {
      await _write;
      return !hasAttempt && _pending == null;
    }
    final state = connection.thigh?.state;
    if (state == 'zeroing') {
      await connection.sendSessionCommand('thigh_cancel');
      if (connection.commandError != null) {
        error = connection.commandError;
        _notify();
        return false;
      }
      if (busy) await _write;
      return !hasAttempt && _pending == null;
    }
    if (state == 'active' && connection.status == WearableStatus.live) {
      await connection.sendSessionCommand('thigh_session_end');
    } else {
      await connection.disconnect();
    }
    if (busy) await _write;
    if (hasAttempt) {
      error =
          connection.commandError ??
          'Final exercise result unavailable. Retry ending the exercise.';
      _notify();
    }
    return !hasAttempt && _pending == null;
  }

  Future<void> interrupt() async {
    await connection.disconnect();
    if (busy) await _write;
    if (hasAttempt && !_sawActive && _pending == null) {
      _attemptId = null;
      _notify();
    }
  }

  Future<bool> finish() async {
    if (busy || _pending != null || _record == null) return false;
    if (hasAttempt && !await endExercise()) return false;
    return _persist(_record!.ended(DateTime.now().toUtc()));
  }

  @override
  void dispose() {
    _disposed = true;
    connection.removeListener(_changed);
    super.dispose();
  }
}
