import 'package:flutter/material.dart';
import 'grain_surface.dart';

const ink = Color(0xFF252B29);
const muted = Color(0xFF656C68);
const line = Color(0xFFE8EBE8);
const sage = Color(0xFF47664F);
const lilac = Color(0xFF78658C);

const exercises = <Exercise>[
  Exercise('Seated Knee Extension', 'Strength · 2 sets', 16, 20, sage),
  Exercise('Supported Sit to Stand', 'Mobility · 2 sets', 12, 16, lilac),
];
final _correctReps = exercises.fold(
  0,
  (sum, exercise) => sum + exercise.correct,
);
final _totalReps = exercises.fold(0, (sum, exercise) => sum + exercise.total);

void main() => runApp(const MyApp());

class Exercise {
  const Exercise(this.name, this.detail, this.correct, this.total, this.accent);
  final String name;
  final String detail;
  final int correct;
  final int total;
  final Color accent;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Rehab · Your session',
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'Manrope',
      scaffoldBackgroundColor: Colors.white,
      colorScheme: const ColorScheme.light(
        primary: ink,
        onPrimary: Colors.white,
        secondary: sage,
        surface: Colors.white,
        onSurface: ink,
        outline: muted,
      ),
      dividerColor: line,
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: ink,
        contentTextStyle: TextStyle(fontFamily: 'Manrope', color: Colors.white),
        behavior: SnackBarBehavior.floating,
      ),
    ),
    home: const HomeScreen(),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scrollController = ScrollController();

  void _reviewSession() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    bottomNavigationBar: Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
          child: FilledButton(
            onPressed: _reviewSession,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            child: const Row(
              children: [
                Expanded(
                  child: Text(
                    'Review session',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                SizedBox(width: 12),
                Icon(Icons.arrow_forward_rounded, size: 20),
              ],
            ),
          ),
        ),
      ),
    ),
    body: SafeArea(
      bottom: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            children: [
              const _BrandHeader(),
              const SizedBox(height: 24),
              const Text(
                'Today’s session',
                style: TextStyle(
                  fontSize: 34,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -1.1,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Good morning, Praveen',
                style: TextStyle(color: muted, fontSize: 15),
              ),
              const SizedBox(height: 24),
              const _SessionSummary(),
              const SizedBox(height: 24),
              const Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    'Session overview',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -.4,
                    ),
                  ),
                  Text(
                    '2 exercises',
                    style: TextStyle(color: muted, fontSize: 13),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (final exercise in exercises) _ExerciseRow(exercise),
              const SizedBox(height: 20),
              const Text(
                'Sample session · Sensors are not connected',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: muted, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) => const Row(
    children: [
      ExcludeSemantics(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CustomPaint(painter: _RehabMark()),
        ),
      ),
      SizedBox(width: 8),
      Text(
        'rehab',
        style: TextStyle(
          fontSize: 23,
          fontWeight: FontWeight.w800,
          letterSpacing: -1,
        ),
      ),
      Spacer(),
      Flexible(
        child: Text(
          'Completed today',
          textAlign: TextAlign.end,
          style: TextStyle(fontSize: 12, color: muted),
        ),
      ),
    ],
  );
}

class _RehabMark extends CustomPainter {
  const _RehabMark();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 32, size.height / 32);
    final paint = Paint()
      ..color = sage
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;
    // Open r: supported movement, with a detached sensor node.
    // Keep geometry in sync with assets/brand/rehab-mark.svg.
    final shoulder = Path()
      ..moveTo(7, 26)
      ..lineTo(7, 15)
      ..cubicTo(7, 9, 11, 6, 17, 6)
      ..lineTo(23, 6);
    final stride = Path()
      ..moveTo(14, 17)
      ..quadraticBezierTo(18, 20, 24, 26);
    canvas.drawPath(shoulder, paint);
    canvas.drawPath(stride, paint);
    canvas.drawCircle(const Offset(24, 14), 2.5, Paint()..color = sage);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RehabMark oldDelegate) => false;
}

class _SessionSummary extends StatelessWidget {
  const _SessionSummary();

  @override
  Widget build(BuildContext context) {
    final percent = (100 * _correctReps / _totalReps).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: GrainSurface(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(
                width: double.infinity,
                child: Wrap(
                  spacing: 20,
                  runSpacing: 4,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    Text(
                      'Today’s progress',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text('~12 min', style: TextStyle(fontSize: 13)),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Semantics(
                container: true,
                label: '$_correctReps of $_totalReps correct repetitions',
                excludeSemantics: true,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$_correctReps',
                        style: const TextStyle(
                          fontSize: 64,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -2.5,
                          height: 1,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      TextSpan(
                        text: ' / $_totalReps',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w400,
                          letterSpacing: -1,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$percent% accuracy · ${_totalReps - _correctReps} reps to improve',
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 20),
              Semantics(
                container: true,
                label: 'Overall progress',
                value: '$percent%',
                child: ExcludeSemantics(
                  child: Column(
                    children: [
                      SizedBox(
                        height: 18,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: _RepMarks(_correctReps, _totalReps),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Session accuracy',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          Text(
                            '$percent%',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RepMarks extends CustomPainter {
  const _RepMarks(this.correct, this.total);
  final int correct;
  final int total;

  @override
  void paint(Canvas canvas, Size size) {
    final step = size.width / total;
    final completedPaint = Paint()..color = ink;
    final remainingPaint = Paint()..color = ink.withValues(alpha: .18);
    for (var i = 0; i < total; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * step, 0, step * .48, size.height),
          const Radius.circular(2),
        ),
        i < correct ? completedPaint : remainingPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_RepMarks oldDelegate) =>
      oldDelegate.correct != correct || oldDelegate.total != total;
}

class _ExerciseRow extends StatelessWidget {
  const _ExerciseRow(this.exercise);
  final Exercise exercise;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: exercise.accent.withValues(alpha: .065),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stacked =
                constraints.maxWidth < 260 ||
                MediaQuery.textScalerOf(context).scale(16) > 22;
            final title = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        exercise.name,
                        style: const TextStyle(
                          fontSize: 16,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        exercise.detail,
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Semantics(
                  container: true,
                  excludeSemantics: true,
                  label: '${exercise.name}: completed',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_circle_outline_rounded,
                        color: exercise.accent,
                        size: 18,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'Completed',
                        style: TextStyle(
                          color: exercise.accent,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
            final score = Column(
              crossAxisAlignment: stacked
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.end,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${exercise.correct}',
                        style: TextStyle(
                          fontSize: 32,
                          height: 1.1,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -1,
                          color: exercise.accent,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      TextSpan(
                        text: ' / ${exercise.total}',
                        style: const TextStyle(
                          fontSize: 15,
                          color: muted,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'correct reps',
                  style: TextStyle(fontSize: 11, color: muted),
                ),
              ],
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (stacked) ...[
                  title,
                  const SizedBox(height: 12),
                  score,
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: title),
                      const SizedBox(width: 16),
                      score,
                    ],
                  ),
                const SizedBox(height: 14),
                Semantics(
                  container: true,
                  child: LinearProgressIndicator(
                    value: exercise.correct / exercise.total,
                    color: exercise.accent,
                    backgroundColor: exercise.accent.withValues(alpha: .12),
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(2),
                    semanticsLabel:
                        '${exercise.name}: ${exercise.correct} of ${exercise.total} correct repetitions',
                    semanticsValue:
                        '${(exercise.correct / exercise.total * 100).round()}%',
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
