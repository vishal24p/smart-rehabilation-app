import 'package:flutter/material.dart';

const teal = Color(0xFF00796B);
const lavender = Color(0xFF6750A4);

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
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: teal),
      useMaterial3: true,
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

  void _selectDestination(int index) {
    setState(() => _selectedIndex = index);
    if (index != 0) {
      final section = index == 1 ? 'Progress' : 'Profile';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$section is coming in the next mock iteration.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _selectDestination,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
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
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Good morning, Maya', style: theme.textTheme.headlineSmall),
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
              onPressed: () {},
              icon: const Icon(Icons.play_arrow),
              label: const Text('Continue session'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
          ],
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
              Semantics(
                label: 'Overall progress: 78 percent',
                child: Text('78%', style: theme.textTheme.displaySmall),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const LinearProgressIndicator(value: 28 / 36),
          const SizedBox(height: 16),
          const Row(
            children: [
              Icon(Icons.schedule_outlined, size: 20),
              SizedBox(width: 8),
              Text('2 exercises · About 12 minutes'),
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: exercise.accent.withValues(alpha: .25)),
      ),
      child: Semantics(
        label:
            '${exercise.name}, ${exercise.correct} of ${exercise.total} correct repetitions',
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
              Semantics(
                label:
                    '${exercise.name} progress: ${exercise.correct} of ${exercise.total}',
                child: LinearProgressIndicator(
                  value: progress,
                  color: exercise.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
