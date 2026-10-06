import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/exercise_reference.dart';

Map<String, dynamic> referenceJson() => {
  'exercise_id': 'squat',
  'measurement_version': 'thigh_tilt_v1',
  'reference_peak_deg': 70.0,
  'bend_threshold_deg': 42.0,
  'upright_band_deg': 10.0,
  'placement': 'front_thigh',
  'recorded_at': '2026-10-06T06:00:00Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('reference round trips and rejects invalid targets', () {
    expect(
      ExerciseReference.fromJson(referenceJson()).toJson(),
      referenceJson(),
    );
    for (final edit in [
      {'exercise_id': 'unknown'},
      {'reference_peak_deg': double.nan},
      {'upright_band_deg': 50},
      {'measurement_version': 'unknown'},
      {'recorded_at': 'bad'},
    ]) {
      expect(
        () => ExerciseReference.fromJson({...referenceJson(), ...edit}),
        throwsFormatException,
      );
    }
  });
  test('native store loads, saves and preserves write errors', () async {
    const channel = MethodChannel('rehab/reference/test');
    final store = ExerciseReferenceStore(channel: channel);
    final reference = ExerciseReference.fromJson(referenceJson());
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getExerciseReferences') return [referenceJson()];
      expect(call.method, 'saveExerciseReference');
      expect(call.arguments, referenceJson());
      return referenceJson();
    });
    expect((await store.load()).single.peakDeg, 70);
    expect((await store.save(reference)).exerciseId, 'squat');
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'storage_failed');
    });
    await expectLater(store.save(reference), throwsA(isA<PlatformException>()));
    messenger.setMockMethodCallHandler(channel, null);
  });
  test(
    'thigh metrics validate countdown and clear live values on interruption',
    () {
      final payload = <String, dynamic>{
        'state': 'active',
        'exercise_id': 'squat',
        'reason': null,
        'zero_progress': 1.0,
        'tilt_deg': 42.0,
        'reference_peak_deg': 70.0,
        'recorded_peak_deg': null,
        'latest_peak_deg': 65.0,
        'difference_deg': -5.0,
        'repetitions': 2,
      };
      final live = ThighAnalytics.fromJson(payload);
      expect(live.differenceDeg, -5);
      final interrupted = live.unavailable('Disconnected');
      expect(interrupted.tiltDeg, isNull);
      expect(interrupted.referencePeakDeg, 70);
      expect(interrupted.repetitions, 2);
      for (final edit in [
        {'zero_progress': 2},
        {'tilt_deg': double.nan},
        {'repetitions': -1},
        {'exercise_id': 'other'},
        {'state': 'other'},
      ]) {
        expect(
          () => ThighAnalytics.fromJson({...payload, ...edit}),
          throwsFormatException,
        );
      }
    },
  );
}
