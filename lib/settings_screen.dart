import 'dart:async';

import 'package:flutter/material.dart';

import 'app_settings.dart';
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
  bool _loading = true,
      _saving = false,
      _capturing = false,
      _sawCapture = false;
  String? _error, _message;

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
      if (mounted) setState(() => _settings = settings);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Settings unavailable. Retry loading.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(AppSettings settings, String success) async {
    setState(() {
      _saving = true;
      _unsaved = settings;
      _error = null;
      _message = null;
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
              AppSettings(
                injuredLeg: _settings.injuredLeg,
                heelZero: snapshot.heelZero,
              ),
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
                              AppSettings(
                                injuredLeg: values.single,
                                heelZero: _settings.heelZero,
                              ),
                              'Injured leg saved',
                            ),
                          );
                        },
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
                if (_message != null) ...[
                  const SizedBox(height: 12),
                  Text(_message!, semanticsLabel: _message),
                ],
                if (_error != null) ...[
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
