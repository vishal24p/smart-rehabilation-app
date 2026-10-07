import 'package:flutter/material.dart';

import 'gait_analysis.dart';
import 'wearable_connection.dart';

class GaitSessionPanel extends StatefulWidget {
  const GaitSessionPanel({required this.connection, this.store, super.key});
  final WearableConnection connection;
  final GaitReferenceStore? store;

  @override
  State<GaitSessionPanel> createState() => _GaitSessionPanelState();
}

class _GaitSessionPanelState extends State<GaitSessionPanel> {
  final _distance = TextEditingController();
  final _tolerance = TextEditingController(text: '20');
  late final GaitReferenceStore _store;
  GaitReference? _baseline;
  int? _thighAxis, _shinAxis, _thighSign, _shinSign;
  var _ranges = false, _mounting = false, _forefootMapping = false;
  var _configured = false, _loading = true, _saving = false;
  var _loadFailed = false;
  var _setupRequest = 0;
  String? _storageError;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? GaitReferenceStore();
    widget.connection.addListener(_connectionChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant GaitSessionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connection != widget.connection) {
      oldWidget.connection.removeListener(_connectionChanged);
      widget.connection.addListener(_connectionChanged);
      _configured = false;
      _setupRequest++;
    }
  }

  void _connectionChanged() {
    if (widget.connection.status != WearableStatus.live ||
        widget.connection.gait?.state == 'interrupted') {
      _configured = false;
      _setupRequest++;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _storageError = null;
      _loadFailed = false;
    });
    try {
      final baseline = await _store.load();
      if (mounted) setState(() => _baseline = baseline);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadFailed = true;
          _storageError =
              'Could not load baseline. Retry loading before replacing it.';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(GaitReference reference) async {
    setState(() {
      _saving = true;
      _storageError = null;
    });
    try {
      final saved = await _store.save(reference);
      if (mounted) setState(() => _baseline = saved);
    } catch (_) {
      if (mounted) {
        setState(
          () => _storageError =
              'Baseline was not saved. Your previous baseline is retained. Retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _channelsPresent {
    final sample = widget.connection.latest;
    return sample?.thighAccel != null &&
        sample?.shinAccel != null &&
        sample?.fsrLeft != null;
  }

  double? _positive(TextEditingController controller, {double? maximum}) {
    final value = double.tryParse(controller.text.trim());
    return value != null &&
            value.isFinite &&
            value > 0 &&
            (maximum == null || value <= maximum)
        ? value
        : null;
  }

  void _editSetup(VoidCallback edit) => setState(() {
    edit();
    _configured = false;
    _setupRequest++;
  });

  Future<void> _configure() async {
    final request = ++_setupRequest;
    await widget.connection.sendSessionCommand(
      'gait_configure',
      config: {
        'ranges_confirmed': _ranges,
        'mounting_confirmed': _mounting,
        'forefoot_mapping_confirmed': _forefootMapping,
        'thigh_axis': {'index': _thighAxis, 'sign': _thighSign},
        'shin_axis': {'index': _shinAxis, 'sign': _shinSign},
      },
    );
    if (mounted &&
        request == _setupRequest &&
        widget.connection.status == WearableStatus.live &&
        widget.connection.commandError == null &&
        widget.connection.gait?.reason == null) {
      setState(() => _configured = true);
    }
  }

  Future<void> _start({required bool baseline}) async {
    final distance = _positive(_distance),
        tolerance = _positive(_tolerance, maximum: 100);
    if (distance == null ||
        tolerance == null ||
        (!baseline && _baseline == null)) {
      return;
    }
    await widget.connection.sendSessionCommand(
      baseline ? 'gait_reference_begin' : 'gait_session_begin',
      config: {
        'distance_m': distance,
        'tolerance_pct': tolerance,
        if (!baseline) 'reference': _baseline!.toJson(),
      },
    );
  }

  Future<void> _cancelCalibration() async {
    await widget.connection.sendSessionCommand('gait_cancel');
    if (mounted) {
      setState(() {
        _configured = false;
        _setupRequest++;
      });
    }
  }

  @override
  void dispose() {
    widget.connection.removeListener(_connectionChanged);
    _distance.dispose();
    _tolerance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.connection,
    builder: (context, _) {
      final connection = widget.connection;
      final gait = connection.gait;
      final state = gait?.state ?? 'setup';
      final walking = state == 'recording' || state == 'active';
      final calibrating = {
        'forefoot_unloaded',
        'forefoot_loaded',
        'standing',
      }.contains(state);
      final enabled =
          connection.status == WearableStatus.live &&
          !connection.commandPending;
      final editable =
          !walking && !calibrating && !connection.commandPending && !_saving;
      final setupValid =
          _ranges &&
          _mounting &&
          _forefootMapping &&
          _thighAxis != null &&
          _shinAxis != null &&
          _thighSign != null &&
          _shinSign != null &&
          _channelsPresent;
      final inputsValid =
          _positive(_distance) != null &&
          _positive(_tolerance, maximum: 100) != null;
      final ready =
          {'ready', 'ended', 'reference_ready'}.contains(state) && _configured;
      final canStart = enabled && editable && ready && inputsValid;
      final preview = gait?.referencePreview;
      final summary = gait?.summary;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Gait analysis', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text(
            'Right thigh and shin IMUs; one FSR under the ball of each foot. Compare a walk with your recorded baseline.',
          ),
          const SizedBox(height: 8),
          const Text(
            'A baseline is a reference walk, not proof of healthy gait. Record a new forefoot baseline; heel baselines cannot be used. Keep placement and walking conditions consistent.',
          ),
          if (!_channelsPresent && connection.latest != null)
            const Text('Both IMUs and both forefoot signals are required.'),
          const SizedBox(height: 16),
          ExpansionTile(
            title: const Text('Gait sensor setup'),
            tilePadding: EdgeInsets.zero,
            maintainState: true,
            initiallyExpanded: true,
            children: [
              _axis(
                'Thigh hinge axis',
                _thighAxis,
                editable,
                (v) => _editSetup(() {
                  _thighAxis = v;
                  _mounting = false;
                }),
              ),
              _axis(
                'Shin hinge axis',
                _shinAxis,
                editable,
                (v) => _editSetup(() {
                  _shinAxis = v;
                  _mounting = false;
                }),
              ),
              _direction(
                'Thigh axis direction',
                _thighSign,
                editable,
                (v) => _editSetup(() {
                  _thighSign = v;
                  _mounting = false;
                }),
              ),
              _direction(
                'Shin axis direction',
                _shinSign,
                editable,
                (v) => _editSetup(() {
                  _shinSign = v;
                  _mounting = false;
                }),
              ),
              _check(
                'IMUs use ±2g and ±250°/s; FSR values use 0–4095',
                _ranges,
                editable,
                (v) => _editSetup(() => _ranges = v),
              ),
              _check(
                'Right-leg mounting and signed axes verified',
                _mounting,
                editable,
                (v) => _editSetup(() => _mounting = v),
              ),
              _check(
                'Left/right forefoot labels verified by loading each sensor',
                _forefootMapping,
                editable,
                (v) => _editSetup(() => _forefootMapping = v),
              ),
              OutlinedButton(
                onPressed: enabled && editable && setupValid
                    ? _configure
                    : null,
                child: const Text('Confirm gait setup'),
              ),
              OutlinedButton(
                onPressed: enabled && editable && _configured
                    ? () => connection.sendSessionCommand(
                        'gait_forefoot_unloaded',
                      )
                    : null,
                child: const Text('Capture unloaded forefeet'),
              ),
              const Text(
                'With both feet supported, keep pressure off both FSRs for the unloaded capture. Then press both sensors steadily for the loaded capture.',
              ),
              OutlinedButton(
                onPressed: enabled && editable && _configured
                    ? () =>
                          connection.sendSessionCommand('gait_forefoot_loaded')
                    : null,
                child: const Text('Capture loaded forefeet'),
              ),
              OutlinedButton(
                onPressed: enabled && editable && _configured
                    ? () => connection.sendSessionCommand('gait_standing')
                    : null,
                child: const Text('Calibrate standing'),
              ),
            ],
          ),
          if (calibrating) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: gait?.progress ?? 0),
            const Text(
              'Hold the instructed position until calibration finishes. Walking starts only when you press Start.',
            ),
            TextButton(
              onPressed: enabled ? _cancelCalibration : null,
              child: const Text('Cancel calibration'),
            ),
          ],
          if (gait?.reason != null)
            Semantics(liveRegion: true, child: Text(gait!.reason!)),
          if (connection.commandError != null)
            Semantics(liveRegion: true, child: Text(connection.commandError!)),
          if (connection.commandPending) const Text('Sending gait command…'),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('gait-distance'),
            controller: _distance,
            enabled: editable,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Measured walking distance (m)',
              helperText: 'Enter the actual path distance for this trial.',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('gait-tolerance'),
            controller: _tolerance,
            enabled: editable,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Baseline deviation tolerance (%)',
              helperText:
                  'Greater than 0, up to 100. Demo setting, not a clinical cutoff.',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          const Text(
            'Each walk needs at least 10 complete strides per foot for comparison. Start at the beginning of the measured path; press Stop at its end. Pauses are included in trial average speed.',
          ),
          const SizedBox(height: 12),
          if (_loading) const Text('Loading saved baseline…'),
          if (_storageError != null) ...[
            Text(_storageError!),
            if (_loadFailed && !_loading && editable)
              TextButton(
                onPressed: _load,
                child: const Text('Retry loading baseline'),
              ),
          ],
          if (_baseline == null && !_loading)
            const Text('No baseline saved. Record and save a baseline first.'),
          if (_baseline != null)
            Text(
              'Saved baseline: ${_baseline!.recordedAt}\n${_baseline!.rightStrides} right and ${_baseline!.leftStrides} left complete strides.',
            ),
          if (!walking) ...[
            FilledButton(
              onPressed: canStart && !_loading && !_loadFailed
                  ? () => _start(baseline: true)
                  : null,
              child: Text(
                _baseline == null
                    ? 'Start baseline walk'
                    : 'Record replacement baseline',
              ),
            ),
            OutlinedButton(
              onPressed:
                  canStart && !_loading && _baseline != null && !_loadFailed
                  ? () => _start(baseline: false)
                  : null,
              child: const Text('Start comparison walk'),
            ),
          ] else ...[
            Semantics(
              liveRegion: true,
              child: Text(
                state == 'recording'
                    ? 'Baseline walk recording'
                    : 'Comparison walk recording',
              ),
            ),
            FilledButton(
              onPressed: enabled
                  ? () => connection.sendSessionCommand(
                      state == 'recording'
                          ? 'gait_reference_finish'
                          : 'gait_session_end',
                    )
                  : null,
              child: const Text('Stop walk'),
            ),
          ],
          if (preview != null && state == 'reference_ready') ...[
            const SizedBox(height: 12),
            const Text(
              'Baseline preview — save only if this was your intended reference walk.',
            ),
            for (final key in gaitTimingKeys)
              Text(
                '${gaitMetricLabels[key]}: ${preview.metrics[key]!.toStringAsFixed(2)}',
              ),
            FilledButton(
              onPressed:
                  editable &&
                      !_loading &&
                      !_loadFailed &&
                      preview.recordedAt != _baseline?.recordedAt
                  ? () => _save(preview)
                  : null,
              child: Text(
                _saving
                    ? 'Saving baseline…'
                    : _baseline == null
                    ? 'Save baseline'
                    : 'Replace saved baseline',
              ),
            ),
          ],
          if (gait != null && (walking || summary != null)) ...[
            const SizedBox(height: 20),
            Text(
              walking
                  ? 'Live walk measurements'
                  : summary!.interrupted
                  ? 'Interrupted walk summary'
                  : 'Walk summary',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (!walking && summary != null) ...[
              Semantics(
                liveRegion: true,
                child: Text(_comparisonText(summary.comparison)),
              ),
              for (final deviation in summary.deviations)
                Text(
                  '${gaitMetricLabels[deviation.metric]} differs by ${deviation.percent.toStringAsFixed(1)}%.',
                ),
            ],
            for (final entry
                in (walking ? gait.metrics : summary!.metrics).values.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(gaitMetricLabels[entry.key]!)),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        walking &&
                                const {
                                  'speed_mps',
                                  'average_step_length_m',
                                  'average_stride_length_m',
                                }.contains(entry.key)
                            ? 'After Stop'
                            : entry.value == null
                            ? '—'
                            : entry.value is int
                            ? '${entry.value}'
                            : entry.value!.toStringAsFixed(2),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 12),
          const Text(
            'Timing uses forefoot loading events, not heel strikes. Forefoot loaded/unloaded durations are local contact proxies, not exact toe-off. True stance, swing and double support are unavailable with forefoot-only FSRs. Lengths are distance-derived averages. Right-leg excursion is a prototype estimate, not a validated knee angle.',
          ),
        ],
      );
    },
  );

  Widget _axis(
    String label,
    int? value,
    bool enabled,
    ValueChanged<int?> change,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<int>(
      isExpanded: true,
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [
        for (var i = 0; i < 3; i++)
          DropdownMenuItem(value: i, child: Text(['X', 'Y', 'Z'][i])),
      ],
      onChanged: enabled ? change : null,
    ),
  );

  Widget _direction(
    String label,
    int? value,
    bool enabled,
    ValueChanged<int?> change,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<int>(
      isExpanded: true,
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: const [
        DropdownMenuItem(value: 1, child: Text('Positive (+)')),
        DropdownMenuItem(value: -1, child: Text('Negative (−)')),
      ],
      onChanged: enabled ? change : null,
    ),
  );

  Widget _check(
    String label,
    bool value,
    bool enabled,
    ValueChanged<bool> change,
  ) => CheckboxListTile(
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
    title: Text(label),
    value: value,
    onChanged: enabled ? (v) => change(v ?? false) : null,
  );

  String _comparisonText(String? value) => switch (value) {
    'within_reference' => 'Within reference',
    'outside_reference' => 'Outside reference',
    'insufficient_data' =>
      'Insufficient data — repeat the walk after checking setup and complete strides.',
    _ => 'Reference walk captured; no comparison made.',
  };
}
