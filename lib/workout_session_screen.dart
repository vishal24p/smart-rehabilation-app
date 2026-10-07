import 'dart:async';
import 'package:flutter/material.dart';
import 'exercise_reference.dart';
import 'live_sensor_screen.dart';
import 'workout_session.dart';

class WorkoutSessionScreen extends StatefulWidget {
  const WorkoutSessionScreen({required this.controller, super.key});
  final WorkoutSessionController controller;
  @override
  State<WorkoutSessionScreen> createState() => _WorkoutSessionScreenState();
}

class _WorkoutSessionScreenState extends State<WorkoutSessionScreen>
    with WidgetsBindingObserver {
  bool _leaving = false;
  bool _exerciseOpen = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(widget.controller.interrupt());
    }
  }

  Future<void> _finish() async {
    if (await widget.controller.finish() && mounted) {
      setState(() => _leaving = true);
      Navigator.of(context).pop();
    }
  }

  Future<void> _choose(String id) async {
    if (_exerciseOpen || !widget.controller.canChoose) return;
    setState(() => _exerciseOpen = true);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            _ManagedExercise(controller: widget.controller, exerciseId: id),
      ),
    );
    if (mounted) setState(() => _exerciseOpen = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.connection.dispose();
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final owner = widget.controller;
      final session = owner.preview;
      return PopScope(
        canPop: _leaving ||
            (owner.record?.status == 'ended' && !owner.busy && !owner.needsRetry),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && !owner.busy && !owner.needsRetry) unawaited(_finish());
        },
        child: Scaffold(
          appBar: AppBar(title: const Text('Your session')),
          body: SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Text(
                      'Choose an exercise',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Complete one exercise, then choose another or end your session.',
                    ),
                    const SizedBox(height: 24),
                    for (final exercise in exerciseNames.entries) ...[
                      FilledButton.tonal(
                        onPressed: owner.canChoose && !_exerciseOpen
                            ? () => _choose(exercise.key)
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      exercise.value,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleLarge,
                                    ),
                                    Text(
                                      '${owner.targets[exercise.key]} repetitions',
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.arrow_forward_rounded),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (session != null && session.exercises.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Saved exercises',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      for (final attempt in session.exercises)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(exerciseNames[attempt.exerciseId]!),
                          subtitle: Text(
                            attempt.result.outcome == 'target_reached'
                                ? 'Exercise completed'
                                : attempt.result.outcome == 'interrupted'
                                ? 'Interrupted'
                                : 'Ended early',
                          ),
                          trailing: Text(
                            '${attempt.result.repetitions} / ${attempt.result.repTarget}',
                          ),
                        ),
                    ],
                    if (owner.busy) ...[
                      const LinearProgressIndicator(),
                      const Text('Saving session…'),
                    ],
                    if (owner.error != null) ...[
                      Semantics(liveRegion: true, child: Text(owner.error!)),
                      if (owner.needsRetry)
                        TextButton(
                          onPressed: () => owner.retry(),
                          child: const Text('Retry saving'),
                        ),
                    ],
                    const SizedBox(height: 32),
                    OutlinedButton(
                      onPressed: owner.canChoose ? _finish : null,
                      child: const Text('End session'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _ManagedExercise extends StatefulWidget {
  const _ManagedExercise({required this.controller, required this.exerciseId});
  final WorkoutSessionController controller;
  final String exerciseId;
  @override
  State<_ManagedExercise> createState() => _ManagedExerciseState();
}

class _ManagedExerciseState extends State<_ManagedExercise> {
  bool _asking = false;
  Future<void> _back() async {
    final owner = widget.controller;
    if (_asking ||
        owner.busy ||
        owner.needsRetry ||
        owner.connection.commandPending) {
      return;
    }
    _asking = true;
    final state = owner.connection.thigh?.state;
    var confirmed = true;
    if (owner.hasAttempt && state == 'active') {
      confirmed =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('End exercise early?'),
              content: const Text(
                'Completed repetitions will be saved. An unfinished repetition will not count.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Keep exercising'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('End exercise'),
                ),
              ],
            ),
          ) ??
          false;
    }
    if (confirmed &&
        (!owner.hasAttempt || await owner.endExercise()) &&
        mounted) {
      Navigator.of(context).pop();
    }
    _asking = false;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.controller,
      widget.controller.connection,
    ]),
    builder: (context, _) => PopScope(
      canPop:
          !widget.controller.hasAttempt &&
          !widget.controller.busy &&
          !widget.controller.needsRetry &&
          !widget.controller.connection.commandPending,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: LiveSensorScreen(
        exerciseId: widget.exerciseId,
        workout: widget.controller,
      ),
    ),
  );
}
