import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'android/app/src/main/python'))
from thigh_session import ThighProcessor
from rehab_session import SessionProcessor


def reference(peak=60):
    return {'exercise_id': 'squat', 'measurement_version': 'thigh_tilt_v1',
            'reference_peak_deg': peak, 'bend_threshold_deg': peak*0.6,
            'upright_band_deg': min(10, max(5, peak*0.15)),
            'placement': 'front_thigh', 'recorded_at': '2026-10-06T00:00:00Z'}


class ThighRig:
    def __init__(self):
        self.processor = ThighProcessor()
        self.t, self.previous = 0, 0

    def sample(self, angle=0):
        radians = math.radians(angle)
        sample = {'time_us': self.t, 'scaled': True, 'fsr': 100, 'fsr_left': 100,
                  'thigh_accel': [math.sin(radians), 0, math.cos(radians)],
                  'thigh_gyro': [0, -(angle-self.previous)/0.05, 0],
                  'shin_accel': None, 'shin_gyro': None}
        self.t += 50_000
        self.previous = angle
        return sample

    def feed(self, angle=0, seconds=0.5):
        for _ in range(round(seconds/0.05)):
            result = self.processor.process(self.sample(angle))
        return result

    def ramp(self, angle, seconds=1):
        start = self.previous
        for i in range(1, round(seconds/0.05)+1):
            result = self.processor.process(self.sample(start+(angle-start)*i/round(seconds/0.05)))
        return result

    def begin(self, recording=True):
        action = 'thigh_reference_begin' if recording else 'thigh_session_begin'
        self.processor.command(action, {'exercise_id': 'squat', 'reference': reference()})
        return self.feed(seconds=3.1)

    def cycle(self, peak=60):
        self.ramp(peak)
        self.feed(peak)
        self.ramp(0)
        return self.feed(seconds=0.5)


class ThighProcessorTest(unittest.TestCase):
    def test_stable_zero_requires_duration_and_samples(self):
        rig = ThighRig()
        result = rig.processor.command('thigh_reference_begin', {'exercise_id': 'squat'})
        self.assertEqual(result['state'], 'zeroing')
        self.assertIsNone(result['tilt_deg'])
        self.assertEqual(rig.feed(seconds=2.9)['state'], 'zeroing')
        self.assertEqual(rig.feed(seconds=0.25)['state'], 'recording')
        self.assertAlmostEqual(rig.processor.snapshot()['tilt_deg'], 0)

    def test_elapsed_time_alone_cannot_finish_zero(self):
        rig = ThighRig()
        rig.processor.command('thigh_reference_begin', {'exercise_id': 'squat'})
        for _ in range(17):
            sample = rig.sample()
            sample['time_us'] *= 4
            result = rig.processor.process(sample)
        self.assertEqual(result['state'], 'zeroing')
        self.assertLess(result['zero_progress'], 1)

    def test_movement_resets_zero_and_valid_still_window_recovers(self):
        rig = ThighRig()
        rig.processor.command('thigh_reference_begin', {'exercise_id': 'squat'})
        rig.feed(seconds=2)
        rig.ramp(20)
        result = rig.feed(20, seconds=0.5)
        self.assertEqual(result['state'], 'zeroing')
        self.assertEqual(rig.feed(20, seconds=3.1)['state'], 'recording')

    def test_still_gyro_bias_above_three_dps_can_set_zero(self):
        rig = ThighRig()
        rig.processor.command('thigh_reference_begin', {'exercise_id': 'squat'})
        bias = [4, -2, 1]
        for _ in range(63):
            sample = rig.sample()
            sample['thigh_gyro'] = bias.copy()
            result = rig.processor.process(sample)
        self.assertEqual(result['state'], 'recording')
        self.assertEqual(rig.processor.bias, bias)
        self.assertAlmostEqual(result['tilt_deg'], 0)

    def test_stable_bias_with_typical_jitter_sets_zero(self):
        rig = ThighRig()
        rig.processor.command('thigh_session_begin', {'exercise_id': 'squat', 'reference': reference()})
        for index in range(61):
            sample = rig.sample()
            jitter = (-0.2, 0, 0.2)[index % 3]
            sample['thigh_gyro'] = [4+jitter, -2-jitter, 1]
            sample['thigh_accel'] = [jitter/40, 0, 1]
            result = rig.processor.process(sample)
        self.assertEqual(result['state'], 'active')
        self.assertAlmostEqual(rig.processor.bias[0], 4, delta=0.01)

    def test_continuous_rotation_with_changing_gravity_cannot_set_zero(self):
        rig = ThighRig()
        rig.processor.command('thigh_reference_begin', {'exercise_id': 'squat'})
        # Constant angular velocity has zero gyro variance, but gravity changes.
        for index in range(100):
            result = rig.processor.process(rig.sample(index*0.5))
        self.assertEqual(result['state'], 'zeroing')
        self.assertLess(result['zero_progress'], 1)
        self.assertIsNone(result['tilt_deg'])

    def test_one_returned_reference_and_no_timing_target(self):
        rig = ThighRig()
        rig.begin()
        rig.ramp(60)
        result = rig.processor.command('thigh_reference_finish')
        self.assertEqual(result['state'], 'recording')
        self.assertIsNone(result['recorded_peak_deg'])
        rig.feed(60)
        rig.ramp(0)
        rig.feed(seconds=0.5)
        result = rig.processor.command('thigh_reference_finish')
        self.assertEqual(result['state'], 'reference_ready')
        self.assertAlmostEqual(result['recorded_peak_deg'], 60, delta=1)

    def test_session_counts_once_and_compares_peak(self):
        rig = ThighRig()
        self.assertEqual(rig.begin(False)['state'], 'active')
        self.assertEqual(rig.feed(0, seconds=0.5)['repetitions'], 0)
        result = rig.cycle(50)
        self.assertEqual(result['repetitions'], 1)
        self.assertAlmostEqual(result['latest_peak_deg'], 50, delta=1)
        self.assertAlmostEqual(result['difference_deg'], -10, delta=1)
        self.assertEqual(rig.feed(seconds=1)['repetitions'], 1)
        self.assertEqual(rig.cycle()['repetitions'], 2)
        self.assertEqual(rig.processor.command('thigh_session_end')['state'], 'ended')

    def test_axis_free_estimate_handles_other_mounting_and_raw_scaling(self):
        for raw in (False, True):
            with self.subTest(raw=raw):
                rig = ThighRig()
                rig.processor.command('thigh_session_begin', {'exercise_id': 'squat', 'reference': reference()})
                samples = []
                for _ in range(63):
                    samples.append(rig.sample())
                for step in range(1, 21):
                    samples.append(rig.sample(step*3))
                for _ in range(10):
                    samples.append(rig.sample(60))
                for sample in samples:
                    for field, divisor in (('thigh_accel', 16384), ('thigh_gyro', 131)):
                        x, y, z = sample[field]
                        sample[field] = [z, x, y]
                        if raw:
                            sample[field] = [round(value*divisor) for value in sample[field]]
                    sample['scaled'] = not raw
                    result = rig.processor.process(sample)
                self.assertEqual(result['state'], 'active')
                self.assertAlmostEqual(result['tilt_deg'], 60, delta=1)

    def test_jitter_shallow_and_incomplete_movements_do_not_count(self):
        rig = ThighRig()
        rig.begin(False)
        for peak in (3, 15, 25):
            self.assertEqual(rig.cycle(peak)['repetitions'], 0)
        rig.ramp(60)
        rig.feed(60)
        self.assertEqual(rig.processor.snapshot()['repetitions'], 0)

    def test_missing_clipped_gap_and_disconnect_interrupt(self):
        for failure in ('missing', 'clipped', 'gap', 'disconnect'):
            with self.subTest(failure=failure):
                rig = ThighRig()
                rig.begin(False)
                if failure == 'disconnect':
                    result = rig.processor.interrupt('Disconnected')
                else:
                    sample = rig.sample()
                    if failure == 'missing':
                        sample['thigh_accel'] = sample['thigh_gyro'] = None
                    elif failure == 'clipped':
                        sample['thigh_gyro'][0] = 32767/131
                    else:
                        sample['time_us'] += 300_000
                    result = rig.processor.process(sample)
                self.assertEqual(result['state'], 'interrupted')
                self.assertIsNone(result['tilt_deg'])
                self.assertEqual(result['reference_peak_deg'], 60)

    def test_payloads_reject_wrong_exercise_or_reference(self):
        processor = ThighProcessor()
        for payload in ({'exercise_id': 'unknown'}, {'exercise_id': 'squat'},
                        {'exercise_id': 'sit_to_stand', 'reference': reference()}):
            result = processor.command('thigh_session_begin', payload)
            self.assertEqual(result['state'], 'idle')
            self.assertIsNotNone(result['reason'])

    def test_invalid_reference_numbers_cancel_and_gravity_timeout(self):
        for value in (float('nan'), float('inf'), True, -1, 181):
            rig = ThighRig()
            target = reference()
            target['reference_peak_deg'] = value
            result = rig.processor.command('thigh_session_begin', {'exercise_id': 'squat', 'reference': target})
            self.assertEqual(result['state'], 'idle')
        rig = ThighRig()
        rig.begin(False)
        for _ in range(22):
            sample = rig.sample()
            sample['thigh_accel'] = [0, 0, 0]
            result = rig.processor.process(sample)
        self.assertEqual(result['state'], 'interrupted')
        self.assertIsNone(result['tilt_deg'])
        result = rig.processor.command('thigh_cancel')
        self.assertEqual(result['state'], 'idle')
        self.assertIsNone(result['reference_peak_deg'])

    def test_independent_routing_no_shin_and_interrupt(self):
        rig = ThighRig()
        processor = SessionProcessor()
        # A previously ready dual-IMU mode must not interrupt the new thigh mode.
        processor.state, processor.motion_ready = 'ready', True
        processor.command('thigh_session_begin', {'exercise_id': 'squat', 'reference': reference()})
        for _ in range(63):
            result = processor.process(rig.sample())
        self.assertEqual(result['thigh']['state'], 'active')
        self.assertIsNone(result['angle_deg'])
        self.assertEqual(processor.interrupt('Disconnected')['thigh']['state'], 'interrupted')


if __name__ == '__main__':
    unittest.main()
