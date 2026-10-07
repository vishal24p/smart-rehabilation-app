import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'exercise_reference.dart';
import 'wearable_connection.dart';
import 'workout_session.dart';
import 'workout_session_screen.dart';
import 'live_sensor_screen.dart';

class SessionHomeScreen extends StatefulWidget {
  const SessionHomeScreen({
    this.store,
    this.settingsStore,
    this.today,
    super.key,
  });
  final WorkoutSessionStore? store;
  final AppSettingsStore? settingsStore;
  final DateTime? today;

  @override
  State<SessionHomeScreen> createState() => _SessionHomeScreenState();
}

class _SessionHomeScreenState extends State<SessionHomeScreen> {
  late final WorkoutSessionStore _store;
  late DateTime _day, _month;
  List<WorkoutSession> _sessions = [];
  bool _loading = true, _starting = false;
  String? _historyError, _startError;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? const WorkoutSessionStore();
    _day = DateUtils.dateOnly((widget.today ?? DateTime.now()).toLocal());
    _month = DateTime(_day.year, _day.month);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _historyError = null;
    });
    try {
      final sessions = await _store.load();
      sessions.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      if (mounted) setState(() => _sessions = sessions);
    } catch (_) {
      if (mounted) {
        setState(() => _historyError = 'History unavailable. Retry loading.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _startError = null;
    });
    WorkoutSessionController? controller;
    try {
      final settings = await (widget.settingsStore ?? const AppSettingsStore())
          .load();
      if (!mounted) return;
      controller = WorkoutSessionController(
        connection: WearableConnection(),
        targets: settings.repTargets,
        store: _store,
      );
      await controller.start();
      if (!mounted) {
        controller.connection.dispose();
        controller.dispose();
        return;
      }
      final owner = controller;
      controller = null;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => WorkoutSessionScreen(controller: owner),
        ),
      );
      if (mounted) await _load();
    } catch (_) {
      controller?.connection.dispose();
      controller?.dispose();
      if (mounted) {
        setState(
          () => _startError =
              'Could not start session. Check saved settings and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  int _count(DateTime date) => _sessions
      .where(
        (session) => DateUtils.isSameDay(session.startedAt.toLocal(), date),
      )
      .length;

  void _changeMonth(int offset) => setState(() {
    _month = DateTime(_month.year, _month.month + offset);
    _day = _month;
  });

  Future<void> _chooseDate() async {
    final earliest = _sessions.fold<DateTime>(
      DateTime(2000),
      (date, session) => session.startedAt.toLocal().isBefore(date)
          ? session.startedAt.toLocal()
          : date,
    );
    final selected = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(
        (_day.year < earliest.year ? _day.year : earliest.year) - 1,
      ),
      lastDate: DateTime(_day.year + 20, 12, 31),
    );
    if (selected != null && mounted) {
      setState(() {
        _day = selected;
        _month = DateTime(selected.year, selected.month);
      });
    }
  }

  Widget _calendar(MaterialLocalizations labels) => LayoutBuilder(
    builder: (context, constraints) {
      final grid = constraints.maxWidth >= 336;
      final offset =
          (DateTime(_month.year, _month.month).weekday % 7 -
              labels.firstDayOfWeekIndex +
              7) %
          7;
      final days = DateUtils.getDaysInMonth(_month.year, _month.month);
      return Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Previous month',
                onPressed: () => _changeMonth(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  labels.formatMonthYear(_month),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Next month',
                onPressed: () => _changeMonth(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          if (grid) ...[
            Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        labels.narrowWeekdays[(col +
                                labels.firstDayOfWeekIndex) %
                            7],
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
            for (var week = 0; week < (offset + days + 6) ~/ 7; week++)
              Row(
                children: [
                  for (var col = 0; col < 7; col++)
                    Expanded(
                      child: _calendarDay(
                        week * 7 + col - offset + 1,
                        days,
                        labels,
                      ),
                    ),
                ],
              ),
          ] else
            OutlinedButton.icon(
              onPressed: _chooseDate,
              icon: const Icon(Icons.calendar_month_outlined),
              label: const Text('Choose date'),
            ),
        ],
      );
    },
  );

  Widget _calendarDay(int day, int days, MaterialLocalizations labels) {
    if (day < 1 || day > days) return const SizedBox(height: 56);
    final date = DateTime(_month.year, _month.month, day),
        count = _count(DateTime(_month.year, _month.month, day));
    final selected = DateUtils.isSameDay(_day, date);
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label:
          '${labels.formatFullDate(date)}, $count ${count == 1 ? 'session' : 'sessions'}',
      button: true,
      selected: selected,
      onTap: () => setState(() => _day = date),
      child: ExcludeSemantics(
        child: TextButton(
          key: ValueKey('calendar-${date.year}-${date.month}-$day'),
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 56),
            padding: EdgeInsets.zero,
            backgroundColor: selected ? colors.primaryContainer : null,
          ),
          onPressed: () => setState(() => _day = date),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$day'),
              SizedBox(
                height: 10,
                child: count > 0 ? const Icon(Icons.circle, size: 5) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final labels = MaterialLocalizations.of(context);
    final selected = _sessions
        .where(
          (session) => DateUtils.isSameDay(session.startedAt.toLocal(), _day),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('rehab')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Your session',
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Choose your exercises, one at a time. Your results are saved here.',
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _starting ? null : _start,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(
                          _starting ? 'Starting session…' : 'Start session',
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonalIcon(
                        onPressed: _starting
                            ? null
                            : () => Navigator.of(context).push<void>(
                                MaterialPageRoute(
                                  builder: (_) => const LiveSensorScreen(
                                    exerciseId: 'gait',
                                  ),
                                ),
                              ),
                        icon: const Icon(Icons.directions_walk_rounded),
                        label: const Text('Gait analysis'),
                      ),
                      if (_startError != null) ...[
                        const SizedBox(height: 12),
                        Text(_startError!),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'Session history',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                const SizedBox(height: 12),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_historyError != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_historyError!),
                        TextButton(
                          onPressed: _load,
                          child: const Text('Retry history'),
                        ),
                      ],
                    ),
                  )
                else ...[
                  _calendar(labels),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      labels.formatFullDate(_day),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      selected.isEmpty
                          ? 'No sessions on this day.'
                          : '${selected.length} ${selected.length == 1 ? 'session' : 'sessions'}',
                    ),
                  ),
                  for (final session in selected)
                    ListTile(
                      key: ValueKey('session-${session.id}'),
                      title: Text(
                        labels.formatTimeOfDay(
                          TimeOfDay.fromDateTime(session.startedAt.toLocal()),
                        ),
                      ),
                      subtitle: Text(
                        '${session.totalReps} repetitions · ${session.exercises.length} exercises${session.status == 'active' ? ' · Unfinished' : ''}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        await Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => _SessionDetailScreen(
                              session: session,
                              store: _store,
                            ),
                          ),
                        );
                        if (mounted) await _load();
                      },
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionDetailScreen extends StatefulWidget {
  const _SessionDetailScreen({required this.session, required this.store});
  final WorkoutSession session;
  final WorkoutSessionStore store;
  @override
  State<_SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<_SessionDetailScreen> {
  late WorkoutSession _session = widget.session;
  bool _saving = false;
  String? _error;
  Future<void> _close() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.store.save(
        _session.ended(DateTime.now().toUtc()),
      );
      if (mounted) setState(() => _session = saved);
    } catch (_) {
      if (mounted) setState(() => _error = 'Session not closed. Retry saving.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _angle(double? value) =>
      value == null ? '—' : '${value.toStringAsFixed(1)}°';
  Widget _metric(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        Text(label),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Scaffold(
      appBar: AppBar(title: const Text('Session results')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              MaterialLocalizations.of(
                context,
              ).formatFullDate(_session.startedAt.toLocal()),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text('${_session.totalReps} completed repetitions'),
            if (_session.status == 'active') ...[
              const SizedBox(height: 16),
              const Text(
                'Unfinished session. Saved exercises are shown below; sensor counting will not resume.',
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _saving ? null : _close,
                child: Text(
                  _saving
                      ? 'Saving…'
                      : _error != null
                      ? 'Retry saving'
                      : 'Close session',
                ),
              ),
            ],
            if (_error != null) Text(_error!),
            if (_session.exercises.isEmpty) ...[
              const SizedBox(height: 24),
              const Text('No completed exercises saved.'),
            ],
            for (final attempt in _session.exercises) ...[
              const Divider(height: 40),
              Text(
                exerciseNames[attempt.exerciseId]!,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(switch (attempt.result.outcome) {
                'target_reached' => 'Exercise completed',
                'ended_early' => 'Ended early',
                _ => 'Interrupted',
              }),
              _metric(
                'Repetitions',
                '${attempt.result.repetitions} / ${attempt.result.repTarget ?? '—'}',
              ),
              _metric(
                'Active duration',
                '${attempt.result.activeS.toStringAsFixed(1)} s',
              ),
              _metric(
                'Final thigh range',
                _angle(attempt.result.latestPeakDeg),
              ),
              _metric(
                'Saved reference',
                _angle(attempt.result.referencePeakDeg),
              ),
              _metric(
                'Reference difference',
                _angle(attempt.result.differenceDeg),
              ),
            ],
            const SizedBox(height: 24),
            const Text('Thigh movement measurements, not knee angle.'),
          ],
        ),
      ),
    ),
  );
}
