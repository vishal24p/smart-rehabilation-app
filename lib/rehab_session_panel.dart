import 'dart:async';

import 'package:flutter/material.dart';
import 'wearable_connection.dart';

class RehabSessionPanel extends StatefulWidget {
  const RehabSessionPanel({
    required this.connection,
    required this.rangesConfirmed,
    super.key,
  });
  final WearableConnection connection;
  final bool rangesConfirmed;

  @override
  State<RehabSessionPanel> createState() => _RehabSessionPanelState();
}

class _RehabSessionPanelState extends State<RehabSessionPanel> {
  int? _thighAxis, _shinAxis, _thighSign, _shinSign;
  var _mountingConfirmed = false;
  var _configured = false;
  var _setupRequest = 0;

  @override
  void initState() {
    super.initState();
    widget.connection.addListener(_connectionChanged);
  }

  @override
  void didUpdateWidget(covariant RehabSessionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connection != widget.connection) {
      oldWidget.connection.removeListener(_connectionChanged);
      widget.connection.addListener(_connectionChanged);
      _configured = false;
      _setupRequest++;
    }
  }

  void _connectionChanged() {
    final state = widget.connection.analytics?.state;
    if (widget.connection.status != WearableStatus.live ||
        state == RehabState.interrupted ||
        state == RehabState.needsCalibration) {
      _configured = false;
      _setupRequest++;
    }
  }

  @override
  void dispose() {
    widget.connection.removeListener(_connectionChanged);
    super.dispose();
  }

  bool get _setupValid =>
      widget.rangesConfirmed &&
      _mountingConfirmed &&
      _thighAxis != null &&
      _shinAxis != null &&
      _thighSign != null &&
      _shinSign != null;

  Future<void> _configure() async {
    final request = ++_setupRequest;
    await widget.connection.sendSessionCommand(
      'configure',
      config: {
        'ranges_confirmed': widget.rangesConfirmed,
        'mounting_confirmed': _mountingConfirmed,
        'thigh_axis': {'index': _thighAxis, 'sign': _thighSign},
        'shin_axis': {'index': _shinAxis, 'sign': _shinSign},
      },
    );
    if (mounted &&
        request == _setupRequest &&
        widget.connection.commandError == null &&
        widget.connection.status == WearableStatus.live) {
      setState(() => _configured = true);
    }
  }

  void _editSetup(VoidCallback change) => setState(() {
    change();
    _configured = false;
    _mountingConfirmed = false;
    _setupRequest++;
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.connection,
    builder: (context, _) {
      final connection = widget.connection;
      final analytics = connection.analytics;
      final state = analytics?.state ?? RehabState.setup;
      final enabled =
          connection.status == WearableStatus.live &&
          !connection.commandPending;
      final setup =
          state == RehabState.setup ||
          state == RehabState.interrupted ||
          state == RehabState.needsCalibration;
      final summary = analytics?.summary;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Sit-to-stand session',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Knee bend and detected cycles are prototype estimates. Use only the instructed stand → sit → stand exercise; they are not a clinical assessment.',
          ),
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Text(
              _instructions(state),
              style: const TextStyle(height: 1.5),
            ),
          ),
          if (analytics?.reason != null) ...[
            const SizedBox(height: 8),
            Semantics(liveRegion: true, child: Text(analytics!.reason!)),
          ],
          if (connection.commandError != null) ...[
            const SizedBox(height: 8),
            Semantics(liveRegion: true, child: Text(connection.commandError!)),
          ],
          if (connection.commandPending) ...[
            const SizedBox(height: 8),
            const Text('Sending session command…'),
          ],
          if ({
            RehabState.heelUnloaded,
            RehabState.heelLoaded,
            RehabState.standing,
            RehabState.movement,
          }.contains(state)) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: analytics?.progress ?? 0,
              semanticsLabel: 'Calibration progress',
            ),
          ],
          if (setup) ...[
            const SizedBox(height: 16),
            const _BoardAxisGuide(),
            const SizedBox(height: 12),
            Text(
              widget.rangesConfirmed
                  ? 'IMU ranges confirmed: ±2g and ±250°/s.'
                  : 'Confirm ±2g and ±250°/s IMU ranges before connecting. Reconnect if needed.',
            ),
            const SizedBox(height: 12),
            _selector(
              'Thigh hinge axis',
              _thighAxis,
              const {0: 'X', 1: 'Y', 2: 'Z'},
              enabled,
              (value) => _editSetup(() => _thighAxis = value),
            ),
            _selector(
              'Thigh axis direction',
              _thighSign,
              const {1: 'Positive (+)', -1: 'Negative (−)'},
              enabled,
              (value) => _editSetup(() => _thighSign = value),
            ),
            _selector(
              'Shin hinge axis',
              _shinAxis,
              const {0: 'X', 1: 'Y', 2: 'Z'},
              enabled,
              (value) => _editSetup(() => _shinAxis = value),
            ),
            _selector(
              'Shin axis direction',
              _shinSign,
              const {1: 'Positive (+)', -1: 'Negative (−)'},
              enabled,
              (value) => _editSetup(() => _shinSign = value),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Mounting and signed axes verified'),
              subtitle: const Text(
                'Both selected axes are parallel to the knee hinge and point to the same physical side. Check each board’s markings; matching letters alone do not prove alignment.',
              ),
              value: _mountingConfirmed,
              onChanged: enabled
                  ? (value) => setState(() {
                      _mountingConfirmed = value ?? false;
                      _configured = false;
                      _setupRequest++;
                    })
                  : null,
            ),
            FilledButton(
              onPressed: enabled && _setupValid
                  ? () => unawaited(_configure())
                  : null,
              child: const Text('Confirm setup'),
            ),
            const SizedBox(height: 8),
            _action(
              'Capture unloaded heel',
              'heel_unloaded',
              enabled && _configured,
            ),
            _action(
              'Capture loaded heel',
              'heel_loaded',
              enabled && _configured,
            ),
            const Text(
              'Capture unloaded first, then loaded, for two stable seconds each. Heel contact can remain unavailable while motion calibration continues.',
            ),
            const SizedBox(height: 8),
            _action(
              'Ready for standing reference',
              'standing',
              enabled && _configured && _setupValid,
            ),
          ],
          if (state == RehabState.movementReady)
            _action('Ready for movement check', 'movement', enabled),
          if (state == RehabState.movement)
            _action('Finish movement check', 'finish_movement', enabled),
          const SizedBox(height: 12),
          _action(
            'Start session',
            'start',
            enabled &&
                _configured &&
                _setupValid &&
                (state == RehabState.ready || state == RehabState.ended),
          ),
          if (state == RehabState.active)
            _action('End session', 'end', enabled),
          if (state != RehabState.setup && state != RehabState.active)
            OutlinedButton(
              onPressed: enabled
                  ? () => unawaited(connection.sendSessionCommand('retry'))
                  : null,
              child: const Text('Retry calibration'),
            ),
          const SizedBox(height: 20),
          Text(
            'Current metrics',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          _metric(
            'Estimated knee bend from standing',
            _number(analytics?.angleDeg, '°'),
          ),
          _metric(
            'Detected sit-to-stand cycles',
            analytics?.cycles?.toString(),
          ),
          _metric('Heel sensor contact', switch (analytics?.heelContact) {
            true => 'Pressed',
            false => 'Not pressed',
            _ => null,
          }),
          if (analytics?.heelSaturated ?? false)
            const Text(
              'Heel ADC is saturated; changing load magnitude is unavailable.',
            ),
          _metric('Session ROM', _number(analytics?.romDeg, '°')),
          _metric('Last cycle duration', _number(analytics?.lastCycleS, ' s')),
          if (summary != null) ...[
            const Divider(height: 32),
            Text(
              summary.interrupted
                  ? 'Interrupted session summary'
                  : 'Session summary',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text('${summary.cycles} completed cycles'),
            _metric('Summary ROM', _number(summary.romDeg, '°')),
            _metric('Active time', _number(summary.activeS, ' s')),
            if (summary.cycleTimesS.isNotEmpty)
              Text(
                'Completed cycle durations: ${summary.cycleTimesS.map((s) => '${s.toStringAsFixed(1)} s').join(', ')}',
              ),
            const Text(
              'Partial cycles are excluded. Summary stays in memory on this screen; leaving it loses the result.',
            ),
          ],
        ],
      );
    },
  );

  Widget _selector(
    String label,
    int? value,
    Map<int, String> choices,
    bool enabled,
    ValueChanged<int?> onChanged,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<int>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: choices.entries
          .map(
            (entry) =>
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          )
          .toList(),
      onChanged: enabled ? onChanged : null,
    ),
  );

  Widget _action(String label, String action, bool enabled) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: FilledButton(
      onPressed: enabled
          ? () => unawaited(widget.connection.sendSessionCommand(action))
          : null,
      child: Text(label, textAlign: TextAlign.center),
    ),
  );

  Widget _metric(String label, String? value) => Semantics(
    label: '$label: ${value ?? 'unavailable'}',
    excludeSemantics: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          Text(
            value ?? '—',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    ),
  );

  String? _number(double? value, String unit) =>
      value == null ? null : '${value.toStringAsFixed(1)}$unit';

  String _instructions(RehabState state) => switch (state) {
    RehabState.setup =>
      'Verify setup, capture the heel baselines, then prepare your comfortable upright standing reference.',
    RehabState.heelUnloaded =>
      'Keep the heel sensor unloaded and still for two seconds.',
    RehabState.heelLoaded => 'Press the heel sensor steadily for two seconds.',
    RehabState.standing =>
      'Hold your comfortable upright standing pose still for three consecutive seconds. Movement restarts this window.',
    RehabState.movementReady =>
      'Standing reference captured. Get ready for two slow movement trials, starting upright.',
    RehabState.movement =>
      'Hold upright briefly, then perform two slow stand → sit → stand cycles at your own pace. Finish while upright. Calibration cycles do not count.',
    RehabState.ready =>
      'Calibration ready. Start when you are comfortable and ready to exercise.',
    RehabState.active =>
      'Session active. Move at your own pace: stand → sit → stand. Only completed returns count.',
    RehabState.ended =>
      'Session ended. Review the completed cycles below, or start another session with this calibration.',
    RehabState.interrupted || RehabState.needsCalibration =>
      'Readings or calibration were interrupted. Check connection and mounting, then repeat calibration before starting.',
  };
}

class _BoardAxisGuide extends StatelessWidget {
  const _BoardAxisGuide();

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        'Board axis direction guide. Example board face: positive X right, positive Y up, positive Z out of the face. Negative reverses each arrow. Actual board markings determine axes. Both signed hinge axes must point to the same physical side.',
    excludeSemantics: true,
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFCCD2CC)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            const Text('Board axes · example face'),
            const SizedBox(height: 8),
            const SizedBox(
              height: 112,
              width: 160,
              child: CustomPaint(painter: _AxisPainter()),
            ),
            const Text(
              'Positive follows the marked arrow; negative reverses it. Use your board’s markings and verify the physical hinge direction.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}

class _AxisPainter extends CustomPainter {
  const _AxisPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF263A32)
      ..strokeWidth = 2;
    const origin = Offset(48, 78);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(25, 40, 48, 48),
        const Radius.circular(6),
      ),
      Paint()..color = const Color(0xFFE8EFEA),
    );
    void arrow(
      Offset end,
      Offset tip1,
      Offset tip2,
      String label,
      Offset text,
    ) {
      canvas.drawLine(origin, end, paint);
      canvas.drawLine(end, tip1, paint);
      canvas.drawLine(end, tip2, paint);
      final caption = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(color: Color(0xFF263A32), fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      caption.paint(canvas, text);
    }

    arrow(
      const Offset(132, 78),
      const Offset(124, 72),
      const Offset(124, 84),
      '+X',
      const Offset(134, 68),
    );
    arrow(
      const Offset(48, 18),
      const Offset(42, 26),
      const Offset(54, 26),
      '+Y',
      const Offset(58, 14),
    );
    canvas.drawCircle(
      origin,
      6,
      Paint()
        ..color = const Color(0xFF263A32)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(origin, 2, paint);
    final caption = TextPainter(
      text: const TextSpan(
        text: '+Z out',
        style: TextStyle(color: Color(0xFF263A32), fontSize: 14),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    caption.paint(canvas, const Offset(22, 94));
  }

  @override
  bool shouldRepaint(covariant _AxisPainter oldDelegate) => false;
}
