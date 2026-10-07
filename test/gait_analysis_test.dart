import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/gait_analysis.dart';
import 'package:rehab_monitor/wearable_connection.dart';

import 'wearable_connection_test.dart' as fixtures;

Map<String, dynamic> referenceJson({String date = '2026-10-06T12:00:00Z'}) => {
  'measurement_version': 'gait_forefoot_timing_v1',
  'placement': 'right_thigh_shin_bilateral_forefeet',
  'recorded_at': date,
  'right_strides': 10,
  'left_strides': 11,
  'metrics': <String, dynamic>{
    'cadence_spm': 120.0,
    'right_step_time_s': 0.5,
    'left_step_time_s': 0.5,
    'right_stride_time_s': 1.0,
    'left_stride_time_s': 1.0,
  },
};

Map<String, dynamic> metricsJson() => {
  for (final key in gaitMetricLabels.keys)
    key: key == 'duration_s'
        ? 20.0
        : key.endsWith('_steps')
        ? 12
        : key.endsWith('_strides')
        ? 10
        : null,
  'cadence_spm': 120.0,
  'right_step_time_s': 0.5,
  'left_step_time_s': 0.5,
  'right_stride_time_s': 1.0,
  'left_stride_time_s': 1.0,
  'distance_m': 10.0,
};

Map<String, dynamic> gaitJson({String state = 'ready'}) => {
  'state': state,
  'reason': null,
  'progress': 0.0,
  'metrics': metricsJson(),
  'comparison': null,
  'deviations': <Object?>[],
  'reference_preview': null,
  'summary': null,
};

Map<String, dynamic> summaryJson({bool interrupted = false}) => {
  'metrics': metricsJson(),
  'comparison': interrupted ? 'insufficient_data' : 'within_reference',
  'deviations': <Object?>[],
  'interrupted': interrupted,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('forefoot calibration and baseline reject legacy heel payloads', () {
    final heelReference = referenceJson()
      ..['measurement_version'] = 'gait_heel_timing_v1'
      ..['placement'] = 'right_thigh_shin_bilateral_heels';
    expect(() => GaitReference.fromJson(heelReference), throwsFormatException);
    for (final state in ['forefoot_unloaded', 'forefoot_loaded']) {
      expect(GaitAnalytics.fromJson(gaitJson(state: state)).state, state);
    }
    expect(
      () => GaitAnalytics.fromJson(gaitJson(state: 'heel_loaded')),
      throwsFormatException,
    );
    final metrics = metricsJson()
      ..['right_forefoot_loaded_s'] = 0.3
      ..['left_forefoot_unloaded_s'] = 0.7;
    expect(
      GaitMetrics.fromJson(metrics).values['right_forefoot_loaded_s'],
      0.3,
    );
    expect(gaitMetricLabels.keys.any((key) => key.contains('heel')), isFalse);
  });

  test('baseline round trip preserves version, side and timing contract', () {
    final reference = GaitReference.fromJson(referenceJson());
    expect(reference.toJson(), referenceJson());
    expect(() => reference.metrics['cadence_spm'] = 3, throwsUnsupportedError);
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (j) => j['right_strides'] = 9,
      (j) => j['left_strides'] = 10.0,
      (j) => j['placement'] = 'left',
      (j) => j['recorded_at'] = '2026-10-06',
      (j) => j['recorded_at'] = '2026-02-30T12:00:00Z',
      (j) => j['recorded_at'] = '0000-10-06T12:00:00Z',
      (j) => j['extra'] = true,
      (j) => (j['metrics'] as Map<String, dynamic>)['cadence_spm'] = double.nan,
      (j) => (j['metrics'] as Map<String, dynamic>)['left_step_time_s'] = 0,
      (j) => (j['metrics'] as Map<String, dynamic>)['unknown'] = 1,
    ]) {
      final json = referenceJson();
      mutate(json);
      expect(() => GaitReference.fromJson(json), throwsFormatException);
    }
  });

  test(
    'analytics retain nulls, reject malformed numbers and interrupted classification',
    () {
      final gait = GaitAnalytics.fromJson(gaitJson());
      expect(gait.metrics.values['speed_mps'], isNull);
      expect(gait.metrics.values['right_strides'], 10);
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (j) => j['state'] = 'normal',
        (j) => j['progress'] = 1.1,
        (j) => (j['metrics'] as Map<String, dynamic>).remove('speed_mps'),
        (j) => (j['metrics'] as Map<String, dynamic>)['right_steps'] = 1.5,
        (j) => (j['metrics'] as Map<String, dynamic>)['speed_mps'] =
            double.infinity,
        (j) => j['comparison'] = 'normal',
        (j) =>
            j['summary'] = (summaryJson(interrupted: true)
              ..['comparison'] = 'within_reference'),
      ]) {
        final json = gaitJson();
        mutate(json);
        expect(() => GaitAnalytics.fromJson(json), throwsFormatException);
      }
    },
  );

  test(
    'successful summaries require complete timing and consistent deviations',
    () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (j) => (j['metrics'] as Map<String, dynamic>)['right_strides'] = 9,
        (j) =>
            (j['metrics'] as Map<String, dynamic>)['left_step_time_s'] = null,
        (j) => (j['metrics'] as Map<String, dynamic>)['cadence_spm'] = 0,
        (j) => j['comparison'] = 'outside_reference',
        (j) => j['deviations'] = [
          {'metric': 'cadence_spm', 'deviation_pct': 25},
        ],
      ]) {
        final json = summaryJson();
        mutate(json);
        expect(() => GaitSummary.fromJson(json), throwsFormatException);
      }
    },
  );

  test(
    'storage uses gait methods and rejects invalid returned payload',
    () async {
      final calls = <String>[];
      const channel = MethodChannel('gait-test-storage');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'getGaitReference'
            ? referenceJson()
            : call.arguments;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final store = GaitReferenceStore(channel: channel);
      final reference = (await store.load())!;
      expect((await store.save(reference)).toJson(), reference.toJson());
      expect(calls, ['getGaitReference', 'saveGaitReference']);
      messenger.setMockMethodCallHandler(channel, (_) async => ['bad']);
      await expectLater(store.load(), throwsFormatException);
    },
  );

  test(
    'native disconnect freezes gait summary; a new walk clears it',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(fixtures.commands, (_) async => null);
      messenger.setMockMethodCallHandler(
        const MethodChannel('rehab/wearable/events'),
        (_) async => null,
      );
      final connection = WearableConnection(android: true);
      addTearDown(() {
        connection.dispose();
        messenger.setMockMethodCallHandler(fixtures.commands, null);
        messenger.setMockMethodCallHandler(
          const MethodChannel('rehab/wearable/events'),
          null,
        );
      });
      await connection.connect();
      await fixtures.emit(
        fixtures.sample()
          ..['analytics'] = (fixtures.analytics()
            ..['gait'] = (gaitJson(state: 'ended')
              ..['summary'] = summaryJson())),
      );
      expect(connection.gait!.summary!.metrics.values['duration_s'], 20);
      await connection.disconnect();
      expect(connection.gait!.state, 'interrupted');
      expect(connection.gait!.summary!.metrics.values['duration_s'], 20);
      await connection.connect();
      await fixtures.emit(
        fixtures.sample(time: 2)
          ..['analytics'] = (fixtures.analytics()
            ..['gait'] = gaitJson(state: 'recording')),
      );
      expect(connection.gait!.summary, isNull);
    },
  );
}
