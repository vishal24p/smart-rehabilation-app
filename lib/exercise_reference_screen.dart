import 'dart:async';

import 'package:flutter/material.dart';

import 'exercise_reference.dart';
import 'thigh_session_panel.dart';
import 'wearable_connection.dart';

class ExerciseReferenceScreen extends StatefulWidget {
  const ExerciseReferenceScreen({
    this.exerciseId,
    this.connection,
    this.store,
    this.disconnectOnDispose = true,
    super.key,
  });
  final String? exerciseId;
  final WearableConnection? connection;
  final ExerciseReferenceStore? store;
  final bool disconnectOnDispose;

  @override
  State<ExerciseReferenceScreen> createState() =>
      _ExerciseReferenceScreenState();
}

class _ExerciseReferenceScreenState extends State<ExerciseReferenceScreen>
    with WidgetsBindingObserver {
  late final WearableConnection _connection;
  late final ExerciseReferenceStore _store;
  late String _exerciseId;
  final _references = <String, ExerciseReference>{};
  bool _loading = true, _saving = false;
  String? _error, _message;

  @override
  void initState() {
    super.initState();
    _connection = widget.connection ?? WearableConnection();
    _store = widget.store ?? ExerciseReferenceStore();
    _exerciseId = widget.exerciseId ?? exerciseNames.keys.first;
    WidgetsBinding.instance.addObserver(this);
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
          _references.clear();
          _references.addEntries(records.map((r) => MapEntry(r.exerciseId, r)));
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'References unavailable. Retry loading.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(double peak) async {
    setState(() {
      _saving = true;
      _error = null;
      _message = null;
    });
    final reference = ExerciseReference(
      exerciseId: _exerciseId,
      peakDeg: peak,
      bendThresholdDeg: 0.6 * peak,
      uprightBandDeg: (0.15 * peak).clamp(5.0, 10.0),
      recordedAt: DateTime.now().toUtc().toIso8601String(),
    );
    try {
      final saved = await _store.save(reference);
      if (!mounted) return;
      setState(() {
        _references[saved.exerciseId] = saved;
        _message = 'Reference saved';
      });
      await _connection.sendSessionCommand('thigh_cancel');
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Reference not saved. Previous reference kept. Retry saving.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_connection.disconnect());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.connection == null) {
      _connection.dispose();
    } else if (widget.disconnectOnDispose) {
      unawaited(_connection.disconnect());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Register exercise')),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: AnimatedBuilder(
            animation: _connection,
            builder: (context, _) {
              final snapshot = _connection.thigh;
              final current = snapshot?.exerciseId == _exerciseId
                  ? snapshot
                  : null;
              final state = current?.state;
              final capturing = {
                'zeroing',
                'recording',
                'reference_ready',
              }.contains(state);
              final pending = _connection.commandPending || _saving;
              final live = _connection.status == WearableStatus.live;
              final available = _connection.latest?.thighAccel != null;
              final saved = _references[_exerciseId];
              final finishReady =
                  current?.recordedPeakDeg != null &&
                  current?.tiltDeg != null &&
                  current!.tiltDeg! <= 10;
              return ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const Text(
                    'Place the sensor on your healthy thigh. Record one complete movement.',
                  ),
                  const SizedBox(height: 20),
                  DropdownButtonFormField<String>(
                    initialValue: _exerciseId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Exercise',
                      border: OutlineInputBorder(),
                    ),
                    items: exerciseNames.entries
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ),
                        )
                        .toList(),
                    onChanged: capturing || pending
                        ? null
                        : (value) => setState(() {
                            _exerciseId = value!;
                            _message = null;
                          }),
                  ),
                  const SizedBox(height: 16),
                  if (_loading)
                    const Center(child: CircularProgressIndicator())
                  else
                    Text(
                      saved == null
                          ? 'Not recorded'
                          : 'Saved reference: ${saved.peakDeg.toStringAsFixed(1)}°',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(_message!),
                      ),
                    ),
                  if (_error != null) ...[
                    Text(_error!),
                    if (!capturing)
                      TextButton(
                        onPressed: _loading || pending ? null : _load,
                        child: const Text('Retry loading references'),
                      ),
                  ],
                  const SizedBox(height: 16),
                  Text(live ? 'Wearable connected' : _connection.message),
                  const SizedBox(height: 8),
                  if (!live)
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: _connection.active || pending
                          ? null
                          : () => _connection.connect(scaleConfirmed: true),
                      child: const Text('Connect wearable'),
                    ),
                  if (live && !available)
                    const Text('Thigh readings unavailable. Check the sensor.'),
                  const SizedBox(height: 16),
                  if (state == 'zeroing')
                    SessionZeroCountdown(progress: current!.zeroProgress),
                  if (state == 'recording') ...[
                    if (current?.reason == null)
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          current?.recordedPeakDeg == null
                              ? 'Zero set. Bend at least 30°, pause briefly, then return standing.'
                              : finishReady
                              ? 'Movement captured. Ready to finish.'
                              : 'Movement captured. Return standing.',
                        ),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      'Thigh tilt: ${current?.tiltDeg == null ? '—' : '${current!.tiltDeg!.toStringAsFixed(1)}°'}',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Captured range: ${current?.recordedPeakDeg == null ? '—' : '${current!.recordedPeakDeg!.toStringAsFixed(1)}°'}',
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (current?.reason != null)
                    Semantics(liveRegion: true, child: Text(current!.reason!)),
                  if (_connection.commandError != null)
                    Text(_connection.commandError!),
                  if (!capturing)
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed:
                          live &&
                              available &&
                              !pending &&
                              !_loading &&
                              _error == null
                          ? () {
                              setState(() => _message = null);
                              _connection.sendSessionCommand(
                                'thigh_reference_begin',
                                config: {'exercise_id': _exerciseId},
                              );
                            }
                          : null,
                      child: Text(
                        saved == null
                            ? 'Record reference'
                            : 'Re-record reference',
                      ),
                    ),
                  if (state == 'recording')
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: pending || !live || !finishReady
                          ? null
                          : () => _connection.sendSessionCommand(
                              'thigh_reference_finish',
                            ),
                      child: const Text('Finish recording'),
                    ),
                  if (state == 'reference_ready' &&
                      current?.recordedPeakDeg != null) ...[
                    Text(
                      'Recorded range: ${current!.recordedPeakDeg!.toStringAsFixed(1)}°',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: pending || !live
                          ? null
                          : () => _save(current.recordedPeakDeg!),
                      child: const Text('Save reference'),
                    ),
                  ],
                  if (capturing)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                        ),
                        onPressed: pending
                            ? null
                            : () => _connection.sendSessionCommand(
                                'thigh_cancel',
                              ),
                        child: const Text('Cancel recording'),
                      ),
                    ),
                  if (_saving) const Text('Saving reference…'),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}
