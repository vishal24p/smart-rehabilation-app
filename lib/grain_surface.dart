import 'dart:ui' as ui;

import 'package:flutter/material.dart';

const _fallbackSurface = Color(0xFFE5E4DE);
Future<ui.FragmentProgram>? _grainProgram;

Future<ui.FragmentProgram> _loadGrainProgram() =>
    _grainProgram ??= ui.FragmentProgram.fromAsset('shaders/rehab.frag');

class GrainSurface extends StatefulWidget {
  const GrainSurface({required this.child, super.key});

  final Widget child;

  @override
  State<GrainSurface> createState() => _GrainSurfaceState();
}

class _GrainSurfaceState extends State<GrainSurface> {
  ui.FragmentShader? _shader;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final program = await _loadGrainProgram();
      final shader = program.fragmentShader();
      if (!mounted) {
        shader.dispose();
        return;
      }
      setState(() => _shader = shader);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    _shader = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    if (_failed || shader == null) {
      return ColoredBox(color: _fallbackSurface, child: widget.child);
    }

    return RepaintBoundary(
      child: CustomPaint(painter: _GrainPainter(shader), child: widget.child),
    );
  }
}

class _GrainPainter extends CustomPainter {
  const _GrainPainter(this.shader);

  final ui.FragmentShader shader;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _GrainPainter oldDelegate) =>
      oldDelegate.shader != shader;
}
