import 'package:flutter/material.dart';

const white = Color(0xFFFFFFFF);
const paleMint = Color(0xFFE8F5F1);
const charcoal = Color(0xFF1B1B1F);
const teal = Color(0xFF00796B);
const lavender = Color(0xFF6750A4);

const rehabColorScheme = ColorScheme.light(
  primary: teal,
  onPrimary: white,
  primaryContainer: paleMint,
  onPrimaryContainer: charcoal,
  secondary: lavender,
  onSecondary: white,
  secondaryContainer: paleMint,
  onSecondaryContainer: charcoal,
  surface: white,
  onSurface: charcoal,
  surfaceContainer: paleMint,
);

const exercises = <Exercise>[
  Exercise(
    name: 'Seated Knee Extension',
    detail: 'Strength · 2 sets',
    correct: 16,
    total: 20,
    accent: teal,
  ),
  Exercise(
    name: 'Supported Sit to Stand',
    detail: 'Mobility · 2 sets',
    correct: 12,
    total: 16,
    accent: lavender,
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
    theme: ThemeData(colorScheme: rehabColorScheme, useMaterial3: true),
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
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Good morning, Maya',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Your rehabilitation session is ready.',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                _OverallCard(theme: theme),
                const SizedBox(height: 24),
                Text('Session overview', style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                ...exercises.map(
                  (exercise) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _ExerciseCard(exercise: exercise),
                  ),
                ),
                const SizedBox(height: 4),
                FilledButton.icon(
                  onPressed: () => _showMockFeedback(
                    'Session continuation is coming in the next mock iteration.',
                  ),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Continue session'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
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
  Widget build(BuildContext context) => Card(
    elevation: 1,
    semanticContainer: false,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: teal.withValues(alpha: .25)),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Today’s progress', style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  '28 / 36\ncorrect repetitions',
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              Text('78%', style: theme.textTheme.displaySmall),
            ],
          ),
          const SizedBox(height: 16),
          const LinearProgressIndicator(
            value: 28 / 36,
            semanticsLabel: 'Overall progress',
            semanticsValue: '78%',
          ),
          const SizedBox(height: 16),
          const Row(
            children: [
              Icon(Icons.schedule_outlined, size: 20),
              SizedBox(width: 8),
              Expanded(child: Text('2 exercises · About 12 minutes')),
            ],
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
      elevation: 1,
      semanticContainer: false,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: exercise.accent.withValues(alpha: .25)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.accessibility_new, color: exercise.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    exercise.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(exercise.detail),
            const SizedBox(height: 16),
            Text('${exercise.correct} / ${exercise.total} correct'),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: progress,
              color: exercise.accent,
              semanticsLabel:
                  '${exercise.name}: ${exercise.correct} of ${exercise.total} correct repetitions',
              semanticsValue: '${(progress * 100).round()}%',
            ),
          ],
        ),
      ),
    );
  }
}
