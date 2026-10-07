import 'dart:async';

import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'exercise_reference.dart';
import 'wearable_connection.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({this.connection, this.store, super.key});
  final WearableConnection? connection;
  final AppSettingsStore? store;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  late final WearableConnection _connection;
  late final AppSettingsStore _store;
  AppSettings _settings = const AppSettings();
  AppSettings? _unsaved;
  final _targetsForm = GlobalKey<FormState>();
  final _targetFields = {
    'squat': TextEditingController(text: '10'),
    'sit_to_stand': TextEditingController(text: '10'),
  };
  bool _loading = true,
      _saving = false,
      _capturing = false,
      _sawCapture = false;
  String? _error, _message;
  bool _targetFeedback = false;

  @override
  void initState() {
    super.initState();
    _connection = widget.connection ?? WearableConnection();
    _store = widget.store ?? const AppSettingsStore();
    _connection.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await _store.load();
      if (mounted) {
        setState(() {
          _settings = settings;
          for (final entry in _targetFields.entries) {
            entry.value.text = '${settings.repTargets[entry.key]}';
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Settings unavailable. Retry loading.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(
    AppSettings settings,
    String success, {
    bool forTargets = false,
  }) async {
    setState(() {
      _saving = true;
      _unsaved = settings;
      _error = null;
      _message = null;
      _targetFeedback = forTargets;
    });
    try {
      final saved = await _store.save(settings);
      if (!mounted) return;
      setState(() {
        _settings = saved;
        _unsaved = null;
        _message = success;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Settings not saved. Retry saving.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _capture() async {
    setState(() {
      _targetFeedback = false;
      _capturing = true;
      _sawCapture = false;
      _error = null;
      _message = null;
    });
    await _connection.sendSessionCommand('heel_zero');
    if (!mounted) return;
    if (_connection.commandError != null) {
      setState(() {
        _capturing = false;
        _error = _connection.commandError;
      });
    } else if (_capturing &&
        !_sawCapture &&
        _connection.analytics?.state != RehabState.heelZero) {
      setState(() {
        _capturing = false;
        _error =
            _connection.analytics?.reason ??
            'Capture did not start. Retry capture.';
      });
    }
  }

  Future<void> _saveTargets() async {
    if (!(_targetsForm.currentState?.validate() ?? false)) return;
    FocusManager.instance.primaryFocus?.unfocus();
    await _save(
      _settings.copyWith(
        repTargets: {
          for (final entry in _targetFields.entries)
            entry.key: int.parse(entry.value.text.trim()),
        },
      ),
      'Repetition targets saved',
      forTargets: true,
    );
  }

  void _changed() {
    if (!mounted) return;
    final snapshot = _connection.analytics;
    if (_capturing) {
      if (_connection.status != WearableStatus.live ||
          _connection.commandError != null ||
          snapshot?.state == RehabState.interrupted) {
        _capturing = false;
        _error =
            _connection.commandError ?? 'Capture stopped. Reconnect and retry.';
      } else if (snapshot?.state == RehabState.heelZero) {
        _sawCapture = true;
      } else if (_sawCapture && snapshot != null) {
        _capturing = false;
        if (snapshot.state == RehabState.setup &&
            snapshot.heelZero != null &&
            snapshot.progress == 1) {
          unawaited(
            _save(
              _settings.copyWith(heelZero: snapshot.heelZero),
              'Baseline saved',
            ),
          );
        } else {
          _error =
              snapshot.reason ??
              'Capture failed. Keep both sensors unloaded and retry.';
        }
      }
    }
    setState(() {});
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
    _connection.removeListener(_changed);
    for (final controller in _targetFields.values) {
      controller.dispose();
    }
    if (widget.connection == null) {
      _connection.dispose();
    } else {
      unawaited(_connection.disconnect());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final busy =
        _loading || _saving || _capturing || _connection.commandPending;
    final live = _connection.status == WearableStatus.live;
    final bothSensors = _connection.latest?.fsrLeft != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  'Injured leg',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Choose the leg to highlight during exercises. You can change it anytime.',
                ),
                const SizedBox(height: 16),
                SegmentedButton<String>(
                  emptySelectionAllowed: true,
                  segments: const [
                    ButtonSegment(value: 'left', label: Text('Left')),
                    ButtonSegment(value: 'right', label: Text('Right')),
                  ],
                  selected: {_settings.injuredLeg}.whereType<String>().toSet(),
                  onSelectionChanged: busy || _error != null
                      ? null
                      : (values) {
                          if (values.isEmpty) return;
                          unawaited(
                            _save(
                              _settings.copyWith(injuredLeg: values.single),
                              'Injured leg saved',
                            ),
                          );
                        },
                ),
                const SizedBox(height: 32),
                Text(
                  'Repetition targets',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Each exercise stops automatically at its target. Changes apply to new exercises.',
                ),
                const SizedBox(height: 16),
                Form(
                  key: _targetsForm,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final entry in _targetFields.entries) ...[
                        TextFormField(
                          key: ValueKey('${entry.key}-rep-target'),
                          controller: entry.value,
                          enabled: !busy && _error == null,
                          keyboardType: TextInputType.number,
                          textInputAction: entry.key == 'squat'
                              ? TextInputAction.next
                              : TextInputAction.done,
                          decoration: InputDecoration(
                            labelText:
                                '${exerciseNames[entry.key]} repetitions',
                            helperText: '1–1000 repetitions',
                            border: const OutlineInputBorder(),
                          ),
                          validator: (value) {
                            final text = value?.trim() ?? '';
                            final number = int.tryParse(text);
                            return RegExp(r'^[0-9]+$').hasMatch(text) &&
                                    number != null &&
                                    number >= 1 &&
                                    number <= 1000
                                ? null
                                : 'Enter a whole number from 1 to 1000.';
                          },
                          onFieldSubmitted: entry.key == 'sit_to_stand' && !busy
                              ? (_) => unawaited(_saveTargets())
                              : null,
                        ),
                        const SizedBox(height: 16),
                      ],
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        onPressed: busy || _error != null ? null : _saveTargets,
                        child: const Text('Save targets'),
                      ),
                      if (_targetFeedback && _message != null) ...[
                        const SizedBox(height: 12),
                        Semantics(liveRegion: true, child: Text(_message!)),
                      ],
                      if (_targetFeedback && _error != null) ...[
                        const SizedBox(height: 12),
                        Semantics(liveRegion: true, child: Text(_error!)),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => _save(
                                  _unsaved!,
                                  'Repetition targets saved',
                                  forTargets: true,
                                ),
                          child: const Text('Retry saving'),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  'Heel-signal setup',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Percentages show each heel’s share of the sensor signal. They do not measure body-weight percentage.',
                ),
                const SizedBox(height: 12),
                Text(
                  _settings.heelZero == null
                      ? 'Capture an unloaded baseline once before using percentages.'
                      : 'Unloaded baseline saved for future sessions. Recapture if the sensor placement changes.',
                ),
                const SizedBox(height: 16),
                Text(_connection.message),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => _connection.active
                            ? _connection.disconnect()
                            : _connection.connect(),
                  child: Text(
                    _connection.active
                        ? 'Disconnect wearable'
                        : 'Connect wearable',
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Remove all pressure from both heel sensors, then hold them still for 2 seconds.',
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: busy || !live || !bothSensors || _error != null
                      ? null
                      : _capture,
                  child: const Text('Capture unloaded sensors'),
                ),
                if (_capturing) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: _sawCapture ? _connection.analytics?.progress : null,
                  ),
                  const Text('Capturing… keep both sensors unloaded.'),
                ],
                if (_loading || _saving) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                if (!_targetFeedback && _message != null) ...[
                  const SizedBox(height: 12),
                  Text(_message!, semanticsLabel: _message),
                ],
                if (!_targetFeedback && _error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () {
                            final unsaved = _unsaved;
                            if (unsaved != null) {
                              unawaited(_save(unsaved, 'Settings saved'));
                            } else if (_error ==
                                'Settings unavailable. Retry loading.') {
                              unawaited(_load());
                            } else {
                              setState(() => _error = null);
                            }
                          },
                    child: Text(
                      _unsaved != null
                          ? 'Retry saving'
                          : _error == 'Settings unavailable. Retry loading.'
                          ? 'Retry loading'
                          : 'Retry capture',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
