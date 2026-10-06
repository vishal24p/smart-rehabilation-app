import 'package:flutter/material.dart';
import 'exercise_reference.dart';
import 'exercise_reference_screen.dart';
import 'live_sensor_screen.dart';

const ink = Color(0xFF252B29);
const muted = Color(0xFF656C68);
const line = Color(0xFFE8EBE8);
const sage = Color(0xFF47664F);
const lilac = Color(0xFF78658C);

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Rehab',
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
    ),
    home: const HomeScreen(),
  );
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('rehab')),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Your exercises',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 8),
              const Text('Choose an exercise to begin.'),
              const SizedBox(height: 24),
              for (final exercise in exerciseNames.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(72),
                      padding: const EdgeInsets.all(20),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            LiveSensorScreen(exerciseId: exercise.key),
                      ),
                    ),
                    child: Text(
                      exercise.value,
                      style: const TextStyle(fontSize: 22),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => const ExerciseReferenceScreen(),
                  ),
                ),
                icon: const Icon(Icons.bookmark_outline),
                label: const Text('Exercise references'),
              ),
              TextButton.icon(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(builder: (_) => const LiveSensorScreen()),
                ),
                icon: const Icon(Icons.sensors),
                label: const Text('Live sensors'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
