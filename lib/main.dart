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
        primary: sage,
        onPrimary: Colors.white,
        primaryContainer: Color(0xFFEAF1EB),
        onPrimaryContainer: ink,
        secondary: sage,
        secondaryContainer: Color(0xFFEAF1EB),
        onSecondaryContainer: ink,
        surface: Colors.white,
        onSurface: ink,
        onSurfaceVariant: muted,
        outline: muted,
        outlineVariant: line,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: 'Manrope',
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 56),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          textStyle: const TextStyle(
            fontFamily: 'Manrope',
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 56)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: Color(0xFFEAF1EB),
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(
            fontFamily: 'Manrope',
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      dividerColor: line,
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
  int _selected = 0;
  static const _labels = ['Exercises', 'Register', 'Sensors'];
  static const _icons = [
    Icons.directions_walk_rounded,
    Icons.bookmark_outline_rounded,
    Icons.sensors_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    final page = switch (_selected) {
      1 => const ExerciseReferenceScreen(),
      2 => const LiveSensorScreen(),
      _ => const _Exercises(),
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 600;
        return Scaffold(
          body: Row(
            children: [
              if (wide)
                NavigationRail(
                  selectedIndex: _selected,
                  onDestinationSelected: (value) =>
                      setState(() => _selected = value),
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (var i = 0; i < _labels.length; i++)
                      NavigationRailDestination(
                        icon: Icon(_icons[i]),
                        label: Text(_labels[i]),
                      ),
                  ],
                )
              else
                const SizedBox.shrink(),
              if (wide)
                const VerticalDivider(width: 1)
              else
                const SizedBox.shrink(),
              Expanded(child: page),
            ],
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _selected,
                  onDestinationSelected: (value) =>
                      setState(() => _selected = value),
                  destinations: [
                    for (var i = 0; i < _labels.length; i++)
                      NavigationDestination(
                        icon: Icon(_icons[i]),
                        label: _labels[i],
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class _Exercises extends StatelessWidget {
  const _Exercises();
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
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Tap to begin.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 32),
              for (final exercise in exerciseNames.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(96),
                      padding: const EdgeInsets.all(24),
                      alignment: Alignment.centerLeft,
                    ),
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            LiveSensorScreen(exerciseId: exercise.key),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            exercise.value,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 16),
                        const Icon(Icons.arrow_forward_rounded),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
