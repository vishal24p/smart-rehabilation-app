import 'dart:async';

import 'package:flutter/material.dart';
import 'wearable_connection.dart';
import 'rehab_session_panel.dart';
import 'thigh_session_panel.dart';
import 'exercise_reference.dart';
import 'gait_session_panel.dart';

class LiveSensorScreen extends StatefulWidget {
  const LiveSensorScreen({this.connection, this.exerciseId, super.key});
  final WearableConnection? connection;
  final String? exerciseId;

  @override
  State<LiveSensorScreen> createState() => _LiveSensorScreenState();
}

class _LiveSensorScreenState extends State<LiveSensorScreen>
    with WidgetsBindingObserver {
  late final WearableConnection _connection;
  var _confirmedRanges = false;

  @override
  void initState() {
    super.initState();
    _connection = widget.connection ?? WearableConnection();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(_connection.disconnect());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.connection == null) {
      _connection.dispose();
    } else {
      unawaited(_connection.disconnect());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.exerciseId == 'gait'
            ? 'Gait analysis'
            : exerciseNames[widget.exerciseId] ?? 'Live sensors',
      ),
      backgroundColor: Colors.white,
    ),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: AnimatedBuilder(
            animation: _connection,
            builder: (context, _) {
              final gaitMode = widget.exerciseId == 'gait';
              final contactName = gaitMode ? 'forefoot' : 'heel';
              final contactTitle = gaitMode ? 'Forefoot' : 'Heel';
              final readings = _connection.latest;
              final analytics = _connection.analytics;
              final rawLeft = readings?.fsrLeft;
              final rawRight = readings?.fsr;
              final uncalibrated =
                  analytics?.heelShareLeft == null &&
                  (analytics?.heelShareReason == null ||
                      analytics?.heelShareReason == 'Heel ADC saturated' ||
                      analytics?.heelShareReason ==
                          'Capture unloaded and loaded heels first');
              final rawTotal = (rawLeft ?? 0) + (rawRight ?? 0);
              final rawValid =
                  rawLeft != null &&
                  rawRight != null &&
                  rawLeft < 4095 &&
                  rawRight < 4095 &&
                  rawTotal > 0;
              final leftShare =
                  analytics?.heelShareLeft?.round() ??
                  (uncalibrated && rawValid
                      ? (100 * rawLeft / rawTotal).round()
                      : null);
              final active = _connection.active;
              final status = switch (_connection.status) {
                WearableStatus.idle => 'Ready to connect',
                WearableStatus.connecting => 'Connecting',
                WearableStatus.receiving => 'Waiting for readings',
                WearableStatus.live => 'Live',
                WearableStatus.reconnecting => 'Reconnecting',
                WearableStatus.disconnected => 'Disconnected',
                WearableStatus.error => 'Connection needs attention',
                WearableStatus.unsupported => 'Android app required',
              };
              return ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            status,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        flex: 2,
                        child: FilledButton.icon(
                          onPressed:
                              _connection.status == WearableStatus.unsupported
                              ? null
                              : () {
                                  if (active) {
                                    unawaited(_connection.disconnect());
                                  } else {
                                    unawaited(
                                      _connection.connect(
                                        scaleConfirmed:
                                            widget.exerciseId != null ||
                                            _confirmedRanges,
                                      ),
                                    );
                                  }
                                },
                          icon: Icon(
                            active
                                ? Icons.link_off_rounded
                                : Icons.wifi_rounded,
                          ),
                          label: Text(
                            active
                                ? 'Disconnect'
                                : _connection.status == WearableStatus.idle
                                ? 'Connect wearable'
                                : 'Retry connection',
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_connection.status != WearableStatus.live) ...[
                    const SizedBox(height: 12),
                    Text(_connection.message),
                  ],
                  if (!active)
                    ExpansionTile(
                      key: const PageStorageKey('connection-help'),
                      title: const Text('Connection help'),
                      tilePadding: EdgeInsets.zero,
                      children: [
                        TextButton(
                          onPressed: active
                              ? null
                              : () => unawaited(_connection.openWifiSettings()),
                          child: const Text('Open Wi-Fi settings'),
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  if (widget.exerciseId == 'gait')
                    GaitSessionPanel(connection: _connection)
                  else if (widget.exerciseId != null)
                    ThighSessionPanel(
                      connection: _connection,
                      exerciseId: widget.exerciseId!,
                    )
                  else
                    ExpansionTile(
                      key: const PageStorageKey('calibration-setup'),
                      title: const Text('Calibration & setup'),
                      tilePadding: EdgeInsets.zero,
                      maintainState: true,
                      children: [
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _confirmedRanges,
                          onChanged: active
                              ? null
                              : (value) => setState(
                                  () => _confirmedRanges = value ?? false,
                                ),
                          title: const Text('IMU ranges confirmed'),
                          subtitle: const Text(
                            'Enable only if both MPUs use ±2g and ±250°/s. Otherwise readings stay in raw counts.',
                          ),
                        ),
                        RehabSessionPanel(
                          connection: _connection,
                          rangesConfirmed: _confirmedRanges,
                        ),
                      ],
                    ),
                  const SizedBox(height: 16),
                  ExpansionTile(
                    key: const PageStorageKey('sensor-details'),
                    title: const Text('Sensor details'),
                    tilePadding: EdgeInsets.zero,
                    maintainState: true,
                    expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (readings == null) const Text('No readings yet'),
                      if (readings != null) ...[
                        _MotionReadings(
                          title: 'Thigh · MPU 0x69',
                          accel: readings.thighAccel,
                          gyro: readings.thighGyro,
                          scaled: readings.scaled,
                        ),
                        const SizedBox(height: 20),
                        _MotionReadings(
                          title: 'Shin · MPU 0x68',
                          accel: readings.shinAccel,
                          gyro: readings.shinGyro,
                          scaled: readings.scaled,
                        ),
                        const SizedBox(height: 24),
                      ],
                      Text(
                        '$contactTitle ADC · last 10 seconds',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text('Right $contactName'),
                      const SizedBox(height: 12),
                      Semantics(
                        label: _connection.history.isEmpty
                            ? '$contactTitle ADC graph has no live readings.'
                            : '$contactTitle ADC graph. ${_connection.history.length} recent readings; latest ${_connection.history.last.adc} out of 4095.',
                        child: SizedBox(
                          height: 140,
                          child: _connection.history.isEmpty
                              ? const Center(
                                  child: Text(
                                    'Graph starts when readings arrive',
                                  ),
                                )
                              : CustomPaint(
                                  painter: _HeelGraph(
                                    _connection.history,
                                    Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                        ),
                      ),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(child: Text('10 seconds ago')),
                          Text('Now'),
                        ],
                      ),
                      if (readings?.fsrLeft != null) ...[
                        const SizedBox(height: 20),
                        Text(
                          'Left $contactName ADC · last 10 seconds',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        Semantics(
                          label:
                              'Left $contactName ADC graph. Latest ${readings!.fsrLeft} out of 4095.',
                          child: SizedBox(
                            height: 140,
                            child: CustomPaint(
                              painter: _HeelGraph(
                                _connection.history,
                                Theme.of(context).colorScheme.primary,
                                left: true,
                              ),
                            ),
                          ),
                        ),
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(child: Text('10 seconds ago')),
                            Text('Now'),
                          ],
                        ),
                      ],
                      const SizedBox(height: 24),
                      const Text(
                        'Local Wi-Fi · keep this screen open during your session.',
                        style: TextStyle(height: 1.5),
                      ),
                    ],
                  ),
                  if (!gaitMode) ...[
                    const SizedBox(height: 24),
                    Text(
                      'Heel signal share',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final side in [
                          ('Left', readings == null ? null : leftShare),
                          (
                            'Right',
                            readings == null || leftShare == null
                                ? null
                                : 100 - leftShare,
                          ),
                        ])
                          Expanded(
                            child: Semantics(
                              container: true,
                              label:
                                  '${side.$1} ${side.$2 == null ? 'unavailable' : '${side.$2}%'}',
                              excludeSemantics: true,
                              child: Column(
                                key: ValueKey(
                                  'heel-${side.$1.toLowerCase()}-share',
                                ),
                                children: [
                                  Text(
                                    side.$1,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.headlineSmall,
                                  ),
                                  const SizedBox(height: 8),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      side.$2 == null ? '—' : '${side.$2}%',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.displayMedium,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (readings != null && leftShare != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        leftShare == 50
                            ? 'Equal shares'
                            : '${uncalibrated ? 'Higher signal' : 'Higher estimate'}: ${leftShare > 50 ? 'left' : 'right'}',
                      ),
                    ] else
                      Text(
                        readings == null
                            ? 'No sensors connected'
                            : uncalibrated
                            ? rawLeft == null
                                  ? 'Left sensor unavailable'
                                  : rawLeft == 4095 || rawRight == 4095
                                  ? 'Sensor limit reached'
                                  : 'No heel signal'
                            : analytics?.heelShareReason ??
                                  'Heel comparison unavailable',
                      ),
                    const SizedBox(height: 8),
                    Text(
                      uncalibrated
                          ? 'Sensor signal share'
                          : 'Baseline-adjusted signal share',
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

class _MotionReadings extends StatelessWidget {
  const _MotionReadings({
    required this.title,
    required this.accel,
    required this.gyro,
    required this.scaled,
  });
  final String title;
  final List<double>? accel, gyro;
  final bool scaled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      if (accel == null || gyro == null)
        const Text('Sensor readings unavailable in this stream')
      else ...[
        Text('Acceleration · ${scaled ? 'g' : 'raw counts'}'),
        _vector(accel!),
        const SizedBox(height: 12),
        Text('Angular velocity · ${scaled ? '°/s' : 'raw counts'}'),
        _vector(gyro!),
      ],
    ],
  );

  Widget _vector(List<double> values) => Wrap(
    spacing: 20,
    runSpacing: 6,
    children: [
      for (var i = 0; i < 3; i++)
        Semantics(
          label: '${['X', 'Y', 'Z'][i]} ${values[i]}',
          child: Text(
            '${['X', 'Y', 'Z'][i]}  ${scaled ? values[i].toStringAsFixed(2) : values[i].toStringAsFixed(0)}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
    ],
  );
}

class _HeelGraph extends CustomPainter {
  const _HeelGraph(this.points, this.color, {this.left = false});
  final List<HeelPoint> points;
  final Color color;
  final bool left;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0xFFE8EBE8)
      ..strokeWidth = 1;
    canvas.drawLine(Offset.zero, Offset(size.width, 0), grid);
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      grid,
    );
    if (points.isEmpty) return;
    final end = points.last.receivedAt;
    final path = Path();
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    var connected = false;
    for (var i = 0; i < points.length; i++) {
      final adc = left ? points[i].leftAdc : points[i].adc;
      if (adc == null) {
        connected = false;
        continue;
      }
      final x =
          (1 - (end - points[i].receivedAt).inMilliseconds / 10000).clamp(
            0.0,
            1.0,
          ) *
          size.width;
      final y = (1 - adc / 4095) * size.height;
      if (!connected) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      connected = true;
    }
    canvas.drawPath(path, stroke);
    final latest = left ? points.last.leftAdc : points.last.adc;
    if (latest != null) {
      canvas.drawCircle(
        Offset(size.width, (1 - latest / 4095) * size.height),
        3,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HeelGraph oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.color != color ||
      oldDelegate.left != left;
}
