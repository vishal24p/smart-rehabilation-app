import copy
import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'android/app/src/main/python'))
from gait_session import GaitProcessor, COMPARED_METRICS


CONFIG = {'ranges_confirmed': True, 'mounting_confirmed': True,
          'forefoot_mapping_confirmed': True,
          'thigh_axis': {'index': 1, 'sign': 1},
          'shin_axis': {'index': 1, 'sign': 1}}


class GaitRig:
    def __init__(self, processor=None, raw=False):
        self.processor = processor or GaitProcessor()
        self.t = 0
        self.raw = raw

    def feed(self, right=100, left=100, seconds=.1, **changes):
        for _ in range(round(seconds * 50)):
            scale = 16384 if self.raw else 1
            sample = {'time_us': self.t, 'fsr': right, 'fsr_left': left,
                      'scaled': not self.raw,
                      'thigh_accel': [0, 0, scale], 'thigh_gyro': [0, 0, 0],
                      'shin_accel': [0, 0, scale], 'shin_gyro': [0, 0, 0]}
            sample.update(changes)
            self.processor.process(sample)
            self.t += 20_000
        return self.snapshot()

    def snapshot(self):
        result = self.processor.snapshot()
        return result.get('gait', result)

    def command(self, action, config=None):
        result = self.processor.command(action, config)
        return result.get('gait', result)

    def calibrate(self, unloaded=(100, 100), loaded=(900, 900)):
        self.command('gait_configure', CONFIG)
        self.command('gait_forefoot_unloaded')
        self.feed(*unloaded, seconds=2.1)
        self.command('gait_forefoot_loaded')
        self.feed(*loaded, seconds=2.1)
        self.command('gait_standing')
        self.feed(*loaded, seconds=3.1)
        assert self.snapshot()['state'] == 'ready', self.snapshot()

    def begin(self, reference=None, distance=12):
        config = {'distance_m': distance, 'tolerance_pct': 20}
        if reference is not None:
            config['reference'] = reference
        result = self.command('gait_session_begin' if reference else 'gait_reference_begin', config)
        assert result['state'] in ('recording', 'active'), result

    def walk(self, pairs=12):
        self.feed(seconds=.1)
        for _ in range(pairs):
            self.feed(900, 100, seconds=.3)
            self.feed(seconds=.2)
            self.feed(100, 900, seconds=.3)
            self.feed(seconds=.2)

    def finish(self):
        action = 'gait_reference_finish' if self.snapshot()['state'] == 'recording' else 'gait_session_end'
        return self.command(action)


class GaitTest(unittest.TestCase):
    def baseline(self):
        rig = GaitRig()
        rig.calibrate()
        rig.begin()
        rig.walk()
        result = rig.finish()
        self.assertEqual(result['state'], 'reference_ready')
        return result['reference_preview']

    def test_counts_timing_formulas_and_forefoot_proxy(self):
        rig = GaitRig()
        rig.calibrate()
        rig.begin()
        rig.walk()
        result = rig.finish()
        metrics = result['metrics']
        self.assertEqual((metrics['right_steps'], metrics['left_steps']), (12, 12))
        self.assertEqual((metrics['right_strides'], metrics['left_strides']), (11, 11))
        self.assertAlmostEqual(metrics['cadence_spm'], 120)
        self.assertAlmostEqual(metrics['right_step_time_s'], .5)
        self.assertAlmostEqual(metrics['left_step_time_s'], .5)
        self.assertAlmostEqual(metrics['right_stride_time_s'], 1)
        self.assertAlmostEqual(metrics['timing_asymmetry_pct'], 0)
        self.assertAlmostEqual(metrics['right_forefoot_loaded_s'], .3)
        self.assertAlmostEqual(metrics['right_forefoot_unloaded_s'], .7)
        self.assertAlmostEqual(metrics['average_step_length_m'], .5)
        self.assertAlmostEqual(metrics['average_stride_length_m'], 1)
        self.assertAlmostEqual(metrics['speed_mps'], 12 / metrics['duration_s'])
        self.assertEqual(result['summary']['metrics'], metrics)

    def test_initial_loaded_and_chatter_do_not_count(self):
        rig = GaitRig()
        rig.calibrate()
        rig.begin()
        rig.feed(900, 900, seconds=.5)
        self.assertEqual(rig.snapshot()['metrics']['right_steps'], 0)
        for _ in range(10):
            rig.feed(seconds=.02)
            rig.feed(900, 900, seconds=.02)
        self.assertEqual(rig.snapshot()['metrics']['right_steps'], 0)
        self.assertEqual(rig.finish()['comparison'], 'insufficient_data')

    def test_forefoot_reference_contract_rejects_heel_baseline(self):
        baseline = self.baseline()
        self.assertEqual(baseline['measurement_version'], 'gait_forefoot_timing_v1')
        self.assertEqual(baseline['placement'], 'right_thigh_shin_bilateral_forefeet')
        heel_reference = {**baseline, 'measurement_version': 'gait_heel_timing_v1',
                          'placement': 'right_thigh_shin_bilateral_heels'}
        rig = GaitRig()
        rig.calibrate()
        result = rig.command('gait_session_begin',
                             {'distance_m': 12, 'tolerance_pct': 20, 'reference': heel_reference})
        self.assertEqual(result['state'], 'ready')
        self.assertIn('heel baselines cannot be compared', result['reason'])
        rig.begin()
        rig.walk()
        self.assertEqual(rig.finish()['reference_preview']['placement'], baseline['placement'])

    def test_legacy_heel_calibration_and_mapping_are_rejected(self):
        rig = GaitRig()
        legacy_config = {key: value for key, value in CONFIG.items()
                         if key != 'forefoot_mapping_confirmed'}
        legacy_config['heel_mapping_confirmed'] = True
        result = rig.command('gait_configure', legacy_config)
        self.assertEqual(result['state'], 'setup')
        self.assertIsNone(rig.processor.config)
        rig.command('gait_configure', CONFIG)
        for action in ('gait_heel_unloaded', 'gait_heel_loaded'):
            result = rig.command(action)
            self.assertEqual(result['state'], 'setup')
            self.assertEqual(result['reason'], 'Choose a supported gait action.')
            self.assertIsNone(rig.processor.baselines)

    def test_matching_reference_and_every_comparison_metric(self):
        baseline = self.baseline()
        for key in (None,) + COMPARED_METRICS:
            with self.subTest(key=key):
                reference = copy.deepcopy(baseline)
                if key:
                    reference['metrics'][key] *= .7
                rig = GaitRig()
                rig.calibrate()
                rig.begin(reference)
                rig.walk()
                result = rig.finish()
                self.assertEqual(result['comparison'], 'outside_reference' if key else 'within_reference')
                self.assertEqual([item['metric'] for item in result['deviations']], [key] if key else [])

    def test_exact_tolerance_is_within(self):
        baseline = self.baseline()
        baseline['metrics']['cadence_spm'] = 100
        rig = GaitRig()
        rig.calibrate()
        rig.begin(baseline)
        rig.walk()
        self.assertEqual(rig.finish()['comparison'], 'within_reference')

    def test_short_reference_and_comparison_are_insufficient(self):
        baseline = self.baseline()
        for reference in (None, baseline):
            rig = GaitRig()
            rig.calibrate()
            rig.begin(reference)
            rig.walk(10)
            result = rig.finish()
            self.assertEqual(result['comparison'], 'insufficient_data')
            self.assertIsNone(result['reference_preview'])

    def test_same_side_events_interrupt(self):
        rig = GaitRig()
        rig.calibrate()
        rig.begin()
        rig.feed()
        rig.feed(900, 100)
        rig.feed()
        result = rig.feed(900, 100)
        self.assertEqual(result['state'], 'interrupted')
        self.assertTrue(result['summary']['interrupted'])
        self.assertEqual(result['comparison'], 'insufficient_data')

    def test_missing_invalid_clipped_restart_gap_saturation_interrupt(self):
        changes = ({'fsr_left': None}, {'shin_accel': None}, {'thigh_gyro': [math.nan, 0, 0]},
                   {'thigh_accel': [2, 0, 0]}, {'fsr': 4095}, {'fsr': -1},
                   {'time_us': -1}, {'time_us': 0}, {'time_us': 0x100000000}, {'restart': True})
        for change in changes:
            with self.subTest(change=change):
                rig = GaitRig()
                rig.calibrate()
                rig.begin()
                rig.walk(2)
                result = rig.feed(**change)
                self.assertEqual(result['state'], 'interrupted')
                frozen = copy.deepcopy(result['summary'])
                rig.feed(seconds=1)
                self.assertEqual(rig.snapshot()['summary'], frozen)
        rig = GaitRig()
        rig.calibrate()
        rig.begin()
        rig.t += 300_000
        self.assertEqual(rig.feed()['state'], 'interrupted')

    def test_invalid_config_reference_and_begin_leave_state_unchanged(self):
        rig = GaitRig()
        for config in (None, {}, {**CONFIG, 'ranges_confirmed': 1},
                       {**CONFIG, 'thigh_axis': {'index': True, 'sign': 1}}):
            self.assertEqual(rig.command('gait_configure', config)['state'], 'setup')
        rig.calibrate()
        for distance in (None, 0, -1, math.nan, math.inf, True):
            result = rig.command('gait_reference_begin', {'distance_m': distance, 'tolerance_pct': 20})
            self.assertEqual(result['state'], 'ready')
        for tolerance in (0, -1, 101, math.nan, True):
            self.assertEqual(rig.command('gait_reference_begin', {'distance_m': 12, 'tolerance_pct': tolerance})['state'], 'ready')
        baseline = self.baseline()
        for key, value in (('recorded_at', 'bad'), ('right_strides', 9), ('left_strides', True),
                           ('measurement_version', 'unknown'), ('placement', 'left_leg')):
            reference = {**baseline, key: value}
            result = rig.command('gait_session_begin', {'distance_m': 12, 'tolerance_pct': 20, 'reference': reference})
            self.assertEqual(result['state'], 'ready')
        for value in (0, -1, math.inf, math.nan, True):
            reference = copy.deepcopy(baseline)
            reference['metrics']['cadence_spm'] = value
            self.assertEqual(rig.command('gait_session_begin', {'distance_m': 12, 'tolerance_pct': 20, 'reference': reference})['state'], 'ready')

    def test_raw_and_scaled_calibration_equivalent(self):
        for raw in (False, True):
            rig = GaitRig(raw=raw)
            rig.calibrate()
            rig.begin()
            rig.walk()
            self.assertAlmostEqual(rig.finish()['metrics']['right_leg_excursion_deg'], 0)

    def test_reversed_forefoot_polarity_and_failed_recalibration(self):
        rig = GaitRig()
        rig.calibrate((900, 900), (100, 100))
        rig.begin()
        rig.feed(900, 900)
        rig.feed(100, 900)
        self.assertEqual(rig.snapshot()['metrics']['right_steps'], 1)
        rig.command('gait_cancel')
        rig.command('gait_forefoot_unloaded')
        rig.feed(500, 500, seconds=2.1)
        rig.command('gait_forefoot_loaded')
        rig.feed(500, 500, seconds=2.1)
        self.assertEqual(rig.command('gait_standing')['state'], 'setup')

    def test_unloaded_adc_endpoint_is_valid_and_simultaneous_events_are_not(self):
        rig = GaitRig()
        rig.calibrate((0, 0), (900, 900))
        rig.begin()
        rig.feed(0, 0)
        result = rig.feed(900, 900)
        self.assertEqual(result['state'], 'interrupted')
        self.assertEqual(result['comparison'], 'insufficient_data')

    def test_parent_routes_gait_and_freezes_on_disconnect_before_knee_setup(self):
        from rehab_session import SessionProcessor
        rig = GaitRig(SessionProcessor())
        rig.calibrate()
        rig.begin()
        rig.walk()
        self.assertEqual(rig.snapshot()['metrics']['right_strides'], 11)
        result = rig.processor.interrupt('Disconnected')['gait']
        self.assertEqual(result['comparison'], 'insufficient_data')
        self.assertTrue(result['summary']['interrupted'])
        frozen = copy.deepcopy(result['summary'])
        rig.processor.interrupt('Disconnected again')
        self.assertEqual(rig.snapshot()['summary'], frozen)

    def test_asymmetry_angular_excursion_and_snapshot_isolation(self):
        rig = GaitRig()
        rig.calibrate()
        rig.begin()
        rig.feed()
        for _ in range(12):
            rig.feed(900, 100, seconds=.3)
            rig.feed(seconds=.3)
            rig.feed(100, 900, seconds=.3)
            rig.feed(seconds=.1)
        for index in range(1, 51):
            radians = math.radians(index*.8)
            rig.feed(seconds=.02, thigh_accel=[-math.sin(radians), 0, math.cos(radians)],
                     thigh_gyro=[0, 40, 0])
        result = rig.finish()
        self.assertAlmostEqual(result['metrics']['timing_asymmetry_pct'], 40)
        self.assertAlmostEqual(result['metrics']['right_leg_excursion_deg'], 40, delta=.6)
        result['summary']['metrics']['right_steps'] = 999
        result['reference_preview']['metrics']['cadence_spm'] = 999
        self.assertEqual(rig.snapshot()['summary']['metrics']['right_steps'], 12)
        self.assertNotEqual(rig.snapshot()['reference_preview']['metrics']['cadence_spm'], 999)

    def test_extreme_finite_inputs_never_emit_nonfinite_json(self):
        baseline = self.baseline()
        baseline['metrics']['cadence_spm'] = 5e-324
        rig = GaitRig()
        rig.calibrate()
        rig.begin(baseline, distance=1.7e308)
        rig.walk()
        import json
        json.dumps(rig.finish(), allow_nan=False)


if __name__ == '__main__':
    unittest.main()
