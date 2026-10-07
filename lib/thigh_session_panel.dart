import 'package:flutter/material.dart';

import 'exercise_reference.dart';
import 'exercise_reference_screen.dart';
import 'wearable_connection.dart';
import 'workout_session.dart';

class SessionZeroCountdown extends StatelessWidget {
  const SessionZeroCountdown({required this.progress, super.key});
  final double progress;

  @override
  Widget build(BuildContext context) {
    final number = (3 - (progress.clamp(0.0, 1.0) * 3).floor()).clamp(1, 3);
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      liveRegion: true,
      child: Column(
        children: [
          Text(
            'Setting session zero',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: reduced
                ? Duration.zero
                : const Duration(milliseconds: 200),
            child: Text(
              '$number',
              key: ValueKey(number),
              style: const TextStyle(fontSize: 80, fontWeight: FontWeight.w600),
            ),
          ),
          const Text('Stand still'),
        ],
      ),
    );
  }
}

class ThighSessionPanel extends StatefulWidget {
  const ThighSessionPanel({
    required this.connection,
    required this.exerciseId,
    this.store,
    this.workout,
    super.key,
  });
  final WearableConnection connection;
  final String exerciseId;
  final ExerciseReferenceStore? store;
  final WorkoutSessionController? workout;

  @override
  State<ThighSessionPanel> createState() => _ThighSessionPanelState();
}

class _ThighSessionPanelState extends State<ThighSessionPanel> {
  late final ExerciseReferenceStore _store;
  ExerciseReference? _reference;
  String? _error;
  bool _loading = true;
  bool _began = false, _starting = false;
  bool _settingReference = false;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? ExerciseReferenceStore();
    _load();
  }

  Future<void> _begin() async {
    setState(() => _starting = true);
    final workout = widget.workout;
    bool accepted;
    if (workout != null) {
      accepted = await workout.beginExercise(widget.exerciseId, _reference!);
    } else {
      await widget.connection.sendSessionCommand(
        'thigh_session_begin',
        config: {
          'exercise_id': widget.exerciseId,
          'reference': _reference!.toJson(),
        },
      );
      accepted = widget.connection.commandError == null;
    }
    if (mounted) {
      setState(() {
        _began = accepted;
        _starting = false;
      });
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final records = await _store.load();
      if (mounted) {
        setState(() {
          _reference = records
              .where((r) => r.exerciseId == widget.exerciseId)
              .firstOrNull;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Reference unavailable. Retry loading.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setReference() async {
    setState(() => _settingReference = true);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ExerciseReferenceScreen(
          exerciseId: widget.exerciseId,
          connection: widget.connection,
          store: _store,
          disconnectOnDispose: false,
        ),
      ),
    );
    if (!mounted) return;
    final state = widget.connection.thigh?.state;
    if ({'zeroing', 'recording', 'reference_ready'}.contains(state)) {
      await widget.connection.sendSessionCommand('thigh_cancel');
    }
    if (!mounted) return;
    setState(() => _settingReference = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.connection,
      if (widget.workout != null) widget.workout!,
    ]),
    builder: (context, _) {
      final connection = widget.connection;
      final workout = widget.workout;
      final managed = workout != null;
      final snapshot = connection.thigh;
      final current =
          !_settingReference &&
              snapshot?.exerciseId == widget.exerciseId &&
              (!managed ||
                  _began ||
                  (_starting &&
                      {'zeroing', 'active'}.contains(snapshot?.state)))
          ? snapshot
          : null;
      final state = current?.state;
      final pending =
          connection.commandPending || _starting || (workout?.busy ?? false);
      final live = connection.status == WearableStatus.live;
      final hasThigh = connection.latest?.thighAccel != null;
      final running = state == 'zeroing' || state == 'active';
      final result = current?.result;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Thigh movement · not knee angle'),
          const SizedBox(height: 16),
          Semantics(
            label:
                'Completed repetitions: ${current?.repetitions ?? 0}${managed ? ' of ${workout.targets[widget.exerciseId]}' : ''}',
            excludeSemantics: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Repetitions'),
                Text(
                  '${current?.repetitions ?? 0}${managed ? ' / ${workout.targets[widget.exerciseId]}' : ''}',
                  style: Theme.of(context).textTheme.displaySmall,
                ),
              ],
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          if (_error != null) ...[
            Text(_error!),
            TextButton(
              onPressed: _load,
              child: const Text('Retry loading reference'),
            ),
          ] else if (!_loading && _reference == null) ...[
            const SizedBox(height: 12),
            const Text(
              'Counting has not started. Set a movement reference first.',
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: pending || _settingReference ? null : _setReference,
              child: const Text('Set movement reference'),
            ),
          ] else if (_reference != null) ...[
            const SizedBox(height: 12),
            _metric('Saved range', _degrees(_reference!.peakDeg)),
            if (state == 'zeroing') ...[
              const SizedBox(height: 16),
              SessionZeroCountdown(progress: current!.zeroProgress),
            ],
            if (state == 'active')
              Semantics(
                liveRegion: true,
                child: const Text('Zero set. Begin your exercise.'),
              ),
            if (current?.reason != null)
              Semantics(liveRegion: true, child: Text(current!.reason!)),
            if (connection.commandError != null) Text(connection.commandError!),
            if (workout?.error != null) ...[
              Semantics(liveRegion: true, child: Text(workout!.error!)),
              if (workout.needsRetry)
                TextButton(
                  onPressed: () => workout.retry(),
                  child: const Text('Retry saving'),
                ),
            ],
            if (live && !hasThigh)
              const Text('Thigh readings unavailable. Check the sensor.'),
            const SizedBox(height: 12),
            if (result != null)
              Semantics(
                liveRegion: true,
                child: Text(switch (result.outcome) {
                  'target_reached' => 'Exercise completed',
                  'ended_early' => 'Exercise ended early',
                  _ => 'Exercise interrupted',
                }, style: Theme.of(context).textTheme.headlineSmall),
              ),
            if (!managed || !_began)
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                onPressed:
                    !_loading &&
                        _error == null &&
                        live &&
                        hasThigh &&
                        !pending &&
                        !running &&
                        (!managed || workout.canChoose)
                    ? _begin
                    : null,
                child: const Text('Start exercise'),
              ),
            if (running)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: pending
                      ? null
                      : () => managed
                            ? workout.endExercise()
                            : connection.sendSessionCommand(
                                state == 'active'
                                    ? 'thigh_session_end'
                                    : 'thigh_cancel',
                              ),
                  child: Text(state == 'active' ? 'End exercise' : 'Cancel'),
                ),
              ),
            const Divider(height: 24),
            _metric('Thigh tilt', _degrees(current?.tiltDeg)),
            _metric('Latest range', _degrees(current?.latestPeakDeg)),
            _metric('Reference difference', _degrees(current?.differenceDeg)),
            if (managed && _began && !workout.hasAttempt) ...[
              const SizedBox(height: 24),
              FilledButton(
                onPressed: pending || workout.needsRetry
                    ? null
                    : () => Navigator.of(context).pop(),
                child: const Text('Return to session'),
              ),
            ],
            if (workout?.busy ?? false) const Text('Saving exercise…'),
          ],
        ],
      );
    },
  );

  String _degrees(double? value) =>
      value == null ? '—' : '${value.toStringAsFixed(1)}°';

  Widget _metric(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label)),
        const SizedBox(width: 16),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );
}
