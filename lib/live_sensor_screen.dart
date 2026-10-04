import 'dart:async';

import 'package:flutter/material.dart';
import 'wearable_connection.dart';

class LiveSensorScreen extends StatefulWidget {
  const LiveSensorScreen({this.connection, super.key});
  final WearableConnection? connection;

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
      title: const Text('Live sensors'),
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
              final readings = _connection.latest;
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
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      status,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _connection.message,
                    style: const TextStyle(height: 1.5),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _connection.status == WearableStatus.unsupported
                        ? null
                        : () {
                            if (active) {
                              unawaited(_connection.disconnect());
                            } else {
                              unawaited(
                                _connection.connect(
                                  scaleConfirmed: _confirmedRanges,
                                ),
                              );
                            }
                          },
                    icon: Icon(
                      active ? Icons.link_off_rounded : Icons.wifi_rounded,
                    ),
                    label: Text(
                      active
                          ? 'Disconnect'
                          : _connection.status == WearableStatus.idle
                          ? 'Connect wearable'
                          : 'Retry connection',
                    ),
                  ),
                  TextButton(
                    onPressed: active
                        ? null
                        : () => unawaited(_connection.openWifiSettings()),
                    child: const Text('Open Wi-Fi settings'),
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _confirmedRanges,
                    onChanged: active
                        ? null
                        : (value) =>
                              setState(() => _confirmedRanges = value ?? false),
                    title: const Text('IMU ranges confirmed'),
                    subtitle: const Text(
                      'Enable only if both MPUs use ±2g and ±250°/s. Otherwise readings stay in raw counts.',
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (readings == null) ...[
                    const Icon(Icons.sensors_outlined, size: 40),
                    const SizedBox(height: 12),
                    const Text('No readings yet', textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                  ] else ...[
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
                    Text(
                      'Heel pressure',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Semantics(
                      label:
                          'Heel pressure ADC reading ${readings.fsr} out of 4095',
                      excludeSemantics: true,
                      child: Text(
                        '${readings.fsr} / 4095',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ),
                    const Text('Raw ADC reading · not force in newtons'),
                    const SizedBox(height: 20),
                  ],
                  Text(
                    'Heel ADC · last 10 seconds',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Semantics(
                    label: _connection.history.isEmpty
                        ? 'Heel ADC graph has no live readings.'
                        : 'Heel ADC graph. ${_connection.history.length} recent readings; latest ${_connection.history.last.adc} out of 4095.',
                    child: SizedBox(
                      height: 140,
                      child: _connection.history.isEmpty
                          ? const Center(
                              child: Text('Graph starts when readings arrive'),
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
                    children: [Text('10 seconds ago'), Text('Now')],
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Local Wi-Fi · keep this screen open during your session.',
                    style: TextStyle(height: 1.5),
                  ),
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
  final List<double> accel, gyro;
  final bool scaled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      Text('Acceleration · ${scaled ? 'g' : 'raw counts'}'),
      _vector(accel),
      const SizedBox(height: 12),
      Text('Angular velocity · ${scaled ? '°/s' : 'raw counts'}'),
      _vector(gyro),
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
  const _HeelGraph(this.points, this.color);
  final List<HeelPoint> points;
  final Color color;

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
    for (var i = 0; i < points.length; i++) {
      final x =
          (1 - (end - points[i].receivedAt).inMilliseconds / 10000).clamp(
            0.0,
            1.0,
          ) *
          size.width;
      final y = (1 - points[i].adc / 4095) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, stroke);
    canvas.drawCircle(
      Offset(size.width, (1 - points.last.adc / 4095) * size.height),
      3,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _HeelGraph oldDelegate) =>
      oldDelegate.points != points || oldDelegate.color != color;
}
