import 'package:flutter/material.dart';

const ink = Color(0xFF101514);
const inkSurface = Color(0xFF19201E);
const inkRaised = Color(0xFF222B28);
const cloud = Color(0xFFF5F7F2);
const muted = Color(0xFFB5C0B9);
const lime = Color(0xFFD9FF4A);
const mint = Color(0xFF72F6C3);

const rehabColorScheme = ColorScheme.dark(
  primary: lime,
  onPrimary: ink,
  primaryContainer: inkRaised,
  onPrimaryContainer: cloud,
  secondary: mint,
  onSecondary: ink,
  secondaryContainer: inkRaised,
  onSecondaryContainer: cloud,
  surface: ink,
  onSurface: cloud,
  surfaceContainer: inkSurface,
  outline: Color(0xFF43504A),
);

const exercises = <Exercise>[
  Exercise(
    name: 'Seated Knee Extension',
    detail: 'Strength · 2 sets',
    correct: 16,
    total: 20,
    accent: mint,
  ),
  Exercise(
    name: 'Supported Sit to Stand',
    detail: 'Mobility · 2 sets',
    correct: 12,
    total: 16,
    accent: lime,
  ),
];

void main() => runApp(const MyApp());

class Exercise {
  const Exercise({
    required this.name,
    required this.detail,
    required this.correct,
    required this.total,
    required this.accent,
  });
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
    title: 'Rehab monitor',
    theme: ThemeData(
      colorScheme: rehabColorScheme,
      useMaterial3: true,
      scaffoldBackgroundColor: ink,
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: cloud,
        contentTextStyle: TextStyle(color: ink, fontWeight: FontWeight.w600),
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
  int _selectedIndex = 0;

  void _showMockFeedback(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  void _selectDestination(int index) {
    setState(() => _selectedIndex = index);
    if (index != 0) {
      final section = index == 1 ? 'Progress' : 'Profile';
      _showMockFeedback('$section is coming in the next mock iteration.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      bottomNavigationBar: Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: NavigationBar(
            backgroundColor: inkSurface,
            indicatorColor: mint,
            selectedIndex: _selectedIndex,
            onDestinationSelected: _selectDestination,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.insights_outlined),
                label: 'Progress',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                label: 'Profile',
              ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
              children: [
                const _Capsule(
                  icon: Icons.wb_sunny_outlined,
                  label: 'Today’s session',
                ),
                const SizedBox(height: 16),
                Text(
                  'Good morning, Maya',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: cloud,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.1,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Your rehabilitation session is ready.',
                  style: TextStyle(color: muted, fontSize: 16, height: 1.4),
                ),
                const SizedBox(height: 28),
                _OverallCard(theme: theme),
                const SizedBox(height: 32),
                Text(
                  'Session overview',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: cloud,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.4,
                  ),
                ),
                const SizedBox(height: 12),
                ...exercises.map(
                  (exercise) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _ExerciseCard(exercise: exercise),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => _showMockFeedback(
                    'Session continuation is coming in the next mock iteration.',
                  ),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Continue session'),
                  style: FilledButton.styleFrom(
                    backgroundColor: lime,
                    foregroundColor: ink,
                    minimumSize: const Size.fromHeight(56),
                    shape: const StadiumBorder(),
                    textStyle: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OverallCard extends StatelessWidget {
  const _OverallCard({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: const Color(0xFF465A45)),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF263A2C), inkSurface, Color(0xFF151B19)],
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Capsule(icon: Icons.bolt_outlined, label: 'Today’s progress'),
          const SizedBox(height: 28),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  '28 / 36',
                  style: theme.textTheme.displaySmall?.copyWith(
                    color: cloud,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.5,
                  ),
                ),
              ),
              ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [lime, mint],
                ).createShader(bounds),
                child: Text(
                  '78%',
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'correct repetitions',
            style: TextStyle(color: muted, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 20),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: const LinearProgressIndicator(
              value: 28 / 36,
              minHeight: 10,
              color: lime,
              backgroundColor: ink,
              semanticsLabel: 'Overall progress',
              semanticsValue: '78%',
            ),
          ),
          const SizedBox(height: 20),
          const _Capsule(
            icon: Icons.schedule_outlined,
            label: '2 exercises · About 12 minutes',
            dark: true,
          ),
        ],
      ),
    ),
  );
}

class _ExerciseCard extends StatelessWidget {
  const _ExerciseCard({required this.exercise});
  final Exercise exercise;

  @override
  Widget build(BuildContext context) {
    final progress = exercise.correct / exercise.total;
    return Card(
      color: inkSurface,
      elevation: 0,
      semanticContainer: false,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: Color(0xFF33413B)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: inkRaised,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.accessibility_new_outlined,
                    color: exercise.accent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    exercise.name,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: cloud,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Capsule(label: exercise.detail, dark: true),
            const SizedBox(height: 16),
            Text(
              '${exercise.correct} / ${exercise.total} correct',
              style: const TextStyle(color: cloud, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                color: exercise.accent,
                backgroundColor: ink,
                semanticsLabel:
                    '${exercise.name}: ${exercise.correct} of ${exercise.total} correct repetitions',
                semanticsValue: '${(progress * 100).round()}%',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Capsule extends StatelessWidget {
  const _Capsule({required this.label, this.icon, this.dark = false});
  final String label;
  final IconData? icon;
  final bool dark;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: ShapeDecoration(
      color: dark ? inkRaised : const Color(0x2AD9FF4A),
      shape: const StadiumBorder(),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon case final icon?) ...[
          Icon(icon, color: dark ? mint : lime, size: 16),
          const SizedBox(width: 6),
        ],
        Text(
          label,
          style: TextStyle(
            color: dark ? muted : lime,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: .2,
          ),
        ),
      ],
    ),
  );
}
