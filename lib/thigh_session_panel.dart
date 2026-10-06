import 'package:flutter/material.dart';

import 'exercise_reference.dart';
import 'exercise_reference_screen.dart';
import 'wearable_connection.dart';

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
    super.key,
  });
  final WearableConnection connection;
  final String exerciseId;
  final ExerciseReferenceStore? store;

  @override
  State<ThighSessionPanel> createState() => _ThighSessionPanelState();
}

class _ThighSessionPanelState extends State<ThighSessionPanel> {
  late final ExerciseReferenceStore _store;
  ExerciseReference? _reference;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? ExerciseReferenceStore();
    _load();
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

  Future<void> _references() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ExerciseReferenceScreen(
          exerciseId: widget.exerciseId,
          connection: widget.connection,
          store: _store,
        ),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.connection,
    builder: (context, _) {
      final connection = widget.connection;
      final snapshot = connection.thigh;
      final current = snapshot?.exerciseId == widget.exerciseId
          ? snapshot
          : null;
      final state = current?.state;
      final pending = connection.commandPending;
      final live = connection.status == WearableStatus.live;
      final hasThigh = connection.latest?.thighAccel != null;
      final running = state == 'zeroing' || state == 'active';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            exerciseNames[widget.exerciseId]!,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'Standing-relative thigh tilt. This is not knee angle or an assessment of exercise correctness.',
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
              'Record a healthy-thigh reference for this exercise first.',
            ),
            OutlinedButton(
              onPressed: pending ? null : _references,
              child: const Text('Record exercise reference'),
            ),
          ] else if (_reference != null) ...[
            const SizedBox(height: 12),
            Text(
              'Saved reference range: ${_reference!.peakDeg.toStringAsFixed(1)}°',
            ),
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
            if (live && !hasThigh)
              const Text('Thigh readings unavailable. Check the sensor.'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed:
                  !_loading &&
                      _error == null &&
                      live &&
                      hasThigh &&
                      !pending &&
                      !running
                  ? () => connection.sendSessionCommand(
                      'thigh_session_begin',
                      config: {
                        'exercise_id': widget.exerciseId,
                        'reference': _reference!.toJson(),
                      },
                    )
                  : null,
              child: const Text('Start exercise'),
            ),
            if (running)
              OutlinedButton(
                onPressed: pending
                    ? null
                    : () => connection.sendSessionCommand(
                        state == 'active'
                            ? 'thigh_session_end'
                            : 'thigh_cancel',
                      ),
                child: Text(state == 'active' ? 'End exercise' : 'Cancel'),
              ),
            const SizedBox(height: 16),
            Text('Completed repetitions: ${current?.repetitions ?? 0}'),
            Text('Thigh tilt: ${_degrees(current?.tiltDeg)}'),
            Text('Latest range: ${_degrees(current?.latestPeakDeg)}'),
            Text(
              'Difference from reference: ${_degrees(current?.differenceDeg)}',
            ),
            TextButton(
              onPressed: running || pending ? null : _references,
              child: const Text('Edit exercise reference'),
            ),
          ],
        ],
      );
    },
  );

  String _degrees(double? value) =>
      value == null ? '—' : '${value.toStringAsFixed(1)}°';
}
