import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'android/app/src/main/python'))
from rehab_session import SessionProcessor


def config(axis=1, sign=1):
    return {'ranges_confirmed': True, 'mounting_confirmed': True,
            'thigh_axis': {'index': axis, 'sign': sign},
            'shin_axis': {'index': axis, 'sign': sign}}


class Rig:
    # Independent Cartesian rotations: inverse board rotation acts on gravity.
    def __init__(self, axis=1, sign=1, offsets=(0, 0), dt=50_000):
        self.processor = SessionProcessor()
        self.processor.command('configure', config(axis, sign))
        self.axis, self.sign, self.offsets, self.dt = axis, sign, offsets, dt
        self.t = 0
        self.previous = (0, 0)

    def sample(self, thigh=0, shin=0, fsr=100, bias=0):
        sample = {'time_us': self.t, 'fsr': fsr, 'scaled': True}
        for name, angle, last, offset in zip(('thigh', 'shin'), (thigh, shin),
                                            self.previous, self.offsets):
            a = math.radians(-(angle + offset) * self.sign)
            # Neutral gravity perpendicular to each tested hinge.
            if self.axis == 0:
                gravity = [0, -math.sin(a), math.cos(a)]
            elif self.axis == 1:
                gravity = [math.sin(a), 0, math.cos(a)]
            else:
                gravity = [math.cos(a), math.sin(a), 0]
            gyro = [0.0] * 3
            gyro[self.axis] = self.sign * (angle - last) / (self.dt / 1e6) + bias
            sample[name + '_accel'] = gravity
            sample[name + '_gyro'] = gyro
        self.previous = (thigh, shin)
        self.t += self.dt
        return sample

    def feed(self, thigh=0, shin=0, seconds=0.5, fsr=100, bias=0):
        result = None
        for _ in range(round(seconds * 1e6 / self.dt)):
            result = self.processor.process(self.sample(thigh, shin, fsr, bias))
        return result

    def ramp(self, target, seconds=1, shin=0):
        start = self.previous[0]
        count = round(seconds * 1e6 / self.dt)
        for i in range(1, count + 1):
            result = self.processor.process(self.sample(start + (target-start)*i/count, shin))
        return result

    def standing(self, bias=0):
        self.processor.command('standing')
        self.feed(seconds=max(3.1, 61*self.dt/1e6), bias=bias)
        assert self.processor.snapshot()['state'] == 'movement_ready'

    def calibration(self, peak=60):
        self.standing()
        self.processor.command('movement')
        self.feed(seconds=0.35)
        for _ in range(2):
            self.ramp(peak)
            self.feed(peak)
            self.ramp(0)
            self.feed(seconds=0.5)
        result = self.processor.command('finish_movement')
        assert result['state'] == 'ready', result

    def cycle(self, peak=60):
        self.ramp(peak)
        self.feed(peak)
        self.ramp(0)
        return self.feed(seconds=0.5)


class DualHeelTest(unittest.TestCase):
    def setUp(self):
        self.processor = SessionProcessor()
        self.t = 0

    def feed(self, right, left=None, count=1):
        for _ in range(count):
            sample = {'time_us': self.t, 'fsr': right}
            if left is not None:
                sample['fsr_left'] = left
            result = self.processor.process(sample)
            self.t += 50_000
        return result

    def calibrate(self, unloaded=(100, 100), loaded=(900, 900)):
        self.processor.command('heel_unloaded')
        self.feed(*unloaded, count=42)
        self.processor.command('heel_loaded')
        self.feed(*loaded, count=42)

    def test_equal_skew_negative_and_no_load(self):
        # Different loaded peaks must not normalize equal ADC excursions.
        self.calibrate(loaded=(900, 500))
        result = self.feed(300, 300)
        self.assertEqual((result['heel_share_right'], result['heel_share_left']), (50, 50))
        result = self.feed(700, 300)
        self.assertEqual((result['heel_share_right'], result['heel_share_left']), (75, 25))
        result = self.feed(90, 300)
        self.assertEqual((result['heel_share_right'], result['heel_share_left']), (0, 100))
        result = self.feed(104, 102)
        self.assertIsNone(result['heel_share_right'])
        self.assertEqual(result['heel_share_reason'], 'No load detected')

    def test_opposite_polarity_and_independent_contact(self):
        self.calibrate(unloaded=(100, 1000), loaded=(900, 200))
        result = self.feed(900, 200, count=4)
        self.assertTrue(result['heel_contact'])
        self.assertTrue(result['left_heel_contact'])
        self.assertEqual(result['heel_share_right'], 50)
        result = self.feed(900, 1000, count=4)
        self.assertTrue(result['heel_contact'])
        self.assertFalse(result['left_heel_contact'])
        self.assertEqual(result['heel_share_right'], 100)

    def test_absent_saturated_retry_and_reset_are_unavailable(self):
        self.calibrate()
        for right, left in ((0, 300), (300, 4095)):
            result = self.feed(right, left)
            self.assertIsNone(result['heel_share_left'])
            self.assertEqual(result['heel_share_reason'], 'Heel ADC saturated')
        result = self.feed(300)
        self.assertEqual(result['heel_share_reason'], 'Left heel reading unavailable')
        result = self.feed(300, 300)
        self.assertIsNone(result['heel_share_left'])
        self.calibrate()
        result = self.processor.command('retry')
        self.assertIsNone(result['heel_share_right'])
        self.calibrate()
        self.t = 0
        result = self.feed(300, 300)
        self.assertIsNone(result['heel_share_right'])
        self.assertEqual(result['state'], 'needs_calibration')

    def test_missing_or_invalid_per_side_calibration(self):
        self.calibrate(loaded=(900, 110))
        result = self.feed(500, 300)
        self.assertIsNone(result['heel_share_left'])
        self.assertEqual(result['heel_share_reason'], 'Capture unloaded and loaded heels first')
        self.processor.command('heel_unloaded')
        self.feed(100, count=42)
        self.processor.command('heel_loaded')
        self.feed(900, 900, count=42)
        self.assertIsNone(self.feed(500, 500)['heel_share_right'])

    def test_capture_noise_sets_deadband_and_disconnect_clears(self):
        for action, center in (('heel_unloaded', 100), ('heel_loaded', 900)):
            self.processor.command(action)
            for index in range(42):
                reading = center + (-4, 0, 4)[index % 3]
                self.feed(reading, reading)
        # MAD=4 => deadband=12, rather than the minimum 5 ADC.
        result = self.feed(110, 110)
        self.assertEqual(result['heel_share_reason'], 'No load detected')
        self.assertEqual(self.feed(120, 120)['heel_share_left'], 50)
        result = self.processor.interrupt('Device disconnected')
        self.assertIsNone(result['heel_share_right'])
        self.assertIsNone(result['left_heel_contact'])

    def test_unloaded_endpoint_is_zero_load_for_each_polarity(self):
        for unloaded, loaded in ((0, 900), (4095, 3200)):
            with self.subTest(unloaded=unloaded):
                self.calibrate((unloaded, unloaded), (loaded, loaded))
                result = self.feed(loaded, unloaded)
                self.assertEqual((result['heel_share_right'], result['heel_share_left']), (100, 0))
                self.assertFalse(result['left_heel_saturated'])
                self.assertIsNone(result['heel_share_reason'])
                result = self.feed(unloaded, loaded)
                self.assertEqual((result['heel_share_right'], result['heel_share_left']), (0, 100))
                self.assertFalse(result['heel_saturated'])
                result = self.feed(unloaded, unloaded)
                self.assertIsNone(result['heel_share_right'])
                self.assertEqual(result['heel_share_reason'], 'No load detected')
                opposite = 4095 if unloaded == 0 else 0
                result = self.feed(loaded, opposite)
                self.assertIsNone(result['heel_share_right'])
                self.assertEqual(result['heel_share_reason'], 'Heel ADC saturated')

    def test_loaded_endpoint_calibration_is_unavailable(self):
        for unloaded, loaded in ((100, 4095), (4000, 0)):
            with self.subTest(loaded=loaded):
                self.calibrate((unloaded, unloaded), (loaded, loaded))
                self.assertIn('saturate', self.processor.reason)
                result = self.feed(300, 300)
                self.assertIsNone(result['heel_share_right'])
                self.assertEqual(result['heel_share_reason'], 'Capture unloaded and loaded heels first')

    def test_heel_only_calibrates_but_motion_commands_require_both_imus(self):
        self.calibrate()
        self.assertEqual(self.feed(500, 500)['heel_share_left'], 50)
        for action in ('configure', 'standing', 'movement', 'finish_movement', 'start'):
            result = self.processor.command(action, config())
            self.assertIn('Missing thigh and shin', result['reason'])
            self.assertIsNone(result['angle_deg'])
            self.assertIsNone(result['cycles'])
        self.assertEqual(self.processor.command('heel_unloaded')['state'], 'heel_unloaded')


class MissingMotionTest(unittest.TestCase):
    def test_missing_shin_interrupts_active_motion_preserves_heels_then_restores(self):
        rig = Rig()
        rig.processor.command('heel_unloaded')
        rig.feed(seconds=2.1, fsr=100)
        rig.processor.command('heel_loaded')
        rig.feed(seconds=2.1, fsr=900)
        rig.calibration()
        rig.processor.command('start')
        rig.feed(seconds=0.5)
        sample = rig.sample()
        sample['shin_accel'] = sample['shin_gyro'] = None
        result = rig.processor.process(sample)
        self.assertEqual(result['state'], 'interrupted')
        self.assertTrue(result['summary']['interrupted'])
        self.assertIsNone(result['angle_deg'])
        self.assertIsNone(result['rom_deg'])
        self.assertIsNone(result['cycles'])
        self.assertIsNotNone(rig.processor.heel_thresholds)
        self.assertIn('Missing shin', result['reason'])
        rig.feed()
        self.assertTrue(rig.processor.motion_available)
        result = rig.processor.command('standing')
        self.assertEqual(result['state'], 'standing')


class GeometryTest(unittest.TestCase):
    def test_signed_cartesian_axes_and_mounting_offsets(self):
        for axis in (0, 1, 2):
            for sign in (-1, 1):
                with self.subTest(axis=axis, sign=sign):
                    rig = Rig(axis, sign, offsets=(173, -37))
                    rig.standing()
                    rig.processor.command('movement')
                    result = rig.ramp(60)
                    self.assertAlmostEqual(result['angle_deg'], 60, delta=1)

    def test_common_rotation_and_irregular_valid_dt(self):
        for dt in (20_000, 100_000):
            rig = Rig(dt=dt)
            rig.standing()
            rig.processor.command('movement')
            for angle in range(1, 61):
                result = rig.processor.process(rig.sample(angle, angle))
            self.assertAlmostEqual(result['angle_deg'], 0, delta=1)

    def test_standing_duration_count_motion_reset_and_bias(self):
        rig = Rig()
        rig.processor.command('standing')
        rig.feed(seconds=2.9, bias=2)
        self.assertEqual(rig.processor.snapshot()['state'], 'standing')
        rig.ramp(20, seconds=0.5)
        rig.feed(20, seconds=3.1, bias=2)
        self.assertEqual(rig.processor.snapshot()['state'], 'movement_ready')
        rig.processor.command('movement')
        self.assertAlmostEqual(rig.feed(20, seconds=1, bias=2)['angle_deg'], 0, delta=1)
        slow = Rig(dt=200_000)
        slow.processor.command('standing')
        self.assertEqual(slow.feed(seconds=4)['state'], 'standing')

    def test_setup_validation_and_finish_require_two_returned_trials(self):
        p = SessionProcessor()
        self.assertEqual(p.command('standing')['state'], 'setup')
        bad = config()
        bad['thigh_axis']['sign'] = True
        self.assertEqual(p.command('configure', bad)['state'], 'setup')
        rig = Rig()
        rig.standing()
        rig.processor.command('movement')
        rig.feed(seconds=0.35)
        rig.ramp(60)
        self.assertEqual(rig.processor.command('finish_movement')['state'], 'movement')
        rig.ramp(0)
        rig.feed(seconds=0.5)
        self.assertEqual(rig.processor.command('finish_movement')['state'], 'movement')

    def test_movement_started_bent_requires_upright_then_two_complete_trials(self):
        for sign in (1, -1):
            with self.subTest(sign=sign):
                rig = Rig()
                rig.standing()
                rig.ramp(sign * 50)
                rig.processor.command('movement')
                rig.feed(sign * 50, seconds=0.5)
                rig.ramp(0)
                rig.feed(seconds=0.5)
                self.assertEqual(rig.processor.trials, [])
                self.assertIsNone(rig.processor.polarity)
                rig.cycle(sign * 60)
                self.assertEqual(len(rig.processor.trials), 1)
                self.assertEqual(rig.processor.command('finish_movement')['state'], 'movement')
                rig.cycle(sign * 60)
                result = rig.processor.command('finish_movement')
                self.assertEqual(result['state'], 'ready')
                self.assertAlmostEqual(rig.processor.bend_threshold, 36, delta=1)

    def test_movement_before_first_post_command_sample_does_not_count(self):
        rig = Rig()
        rig.standing()
        rig.processor.command('movement')
        # This bend leaves upright before a 250ms confirmation is possible.
        rig.ramp(60, seconds=0.5)
        rig.feed(60)
        rig.ramp(0)
        rig.feed(seconds=0.5)
        self.assertEqual(rig.processor.trials, [])
        rig.cycle()
        rig.cycle()
        self.assertEqual(rig.processor.command('finish_movement')['state'], 'ready')

    def test_clipping_and_lost_gravity_invalidate_motion(self):
        for failure in ('clipped', 'projection', 'off_axis'):
            rig = Rig()
            rig.calibration()
            rig.processor.command('start')
            for _ in range(24):
                sample = rig.sample()
                if failure == 'clipped':
                    sample['thigh_accel'][0] = 32767/16384
                elif failure == 'projection':
                    sample['thigh_accel'] = [0, 1, 0]
                else:
                    sample['thigh_gyro'][0] = 30
                result = rig.processor.process(sample)
                if result['state'] == 'interrupted':
                    break
            self.assertEqual(result['state'], 'interrupted', failure)
            self.assertIsNone(result['angle_deg'])
            self.assertTrue(result['summary']['interrupted'])


class SessionTest(unittest.TestCase):
    def active(self):
        rig = Rig()
        rig.calibration()
        result = rig.processor.command('start')
        self.assertEqual(result['cycles'], 0)
        self.assertEqual(result['rom_deg'], 0)
        return rig

    def test_two_complete_cycles_duration_rom_and_no_double_count(self):
        rig = self.active()
        rig.cycle()
        result = rig.cycle()
        self.assertEqual(result['cycles'], 2)
        # Departure at 12 degrees; first return at 9 degrees: 2.15 seconds.
        self.assertAlmostEqual(result['last_cycle_s'], 2.15, delta=0.001)
        self.assertAlmostEqual(result['rom_deg'], 60, delta=1)
        self.assertEqual(rig.feed(seconds=1)['cycles'], 2)
        ended = rig.processor.command('end')
        self.assertEqual(ended['summary']['cycles'], 2)
        self.assertFalse(ended['summary']['interrupted'])
        self.assertEqual(len(ended['summary']['cycle_times_s']), 2)
        frozen = ended['summary']
        rig.feed(seconds=1)
        rig.processor.interrupt('Disconnected')
        self.assertEqual(rig.processor.snapshot()['summary'], frozen)
        self.assertEqual(rig.processor.command('retry')['summary'], frozen)

    def test_half_cycle_short_return_and_minimum_cycle_time(self):
        rig = self.active()
        rig.ramp(60)
        rig.feed(60)
        self.assertEqual(rig.processor.snapshot()['cycles'], 0)
        rig.ramp(0)
        self.assertEqual(rig.feed(seconds=0.05)['cycles'], 0)
        rig.ramp(60, seconds=0.3)
        self.assertEqual(rig.processor.snapshot()['cycles'], 0)
        ended = rig.processor.command('end')
        self.assertEqual(ended['summary']['cycles'], 0)
        quick = self.active()
        quick.ramp(60, seconds=0.3)
        quick.feed(60, seconds=0.3)
        quick.ramp(0, seconds=0.3)
        self.assertEqual(quick.feed(seconds=0.5)['cycles'], 0)

    def test_start_bent_waits_upright_interruption_discards_partial_cycle(self):
        rig = Rig()
        rig.calibration()
        rig.ramp(60)
        rig.processor.command('start')
        rig.ramp(0)
        self.assertEqual(rig.feed(seconds=0.5)['cycles'], 0)
        rig.cycle()
        rig.ramp(60)
        result = rig.processor.interrupt('TCP retry')
        self.assertEqual(result['state'], 'interrupted')
        self.assertIsNone(result['cycles'])
        self.assertEqual(result['summary']['cycles'], 1)
        self.assertTrue(result['summary']['interrupted'])
        self.assertIsNone(result['angle_deg'])
        self.assertEqual(rig.processor.command('start')['state'], 'interrupted')

    def test_duplicate_gap_rollback_and_negative_polarity(self):
        rig = self.active()
        sample = rig.sample()
        first = rig.processor.process(sample)
        self.assertEqual(rig.processor.process(sample), first)
        sample['time_us'] += 300_000
        self.assertEqual(rig.processor.process(sample)['state'], 'interrupted')
        rig = self.active()
        sample = rig.sample()
        sample['time_us'] = 0
        self.assertEqual(rig.processor.process(sample)['state'], 'interrupted')
        reverse = Rig()
        reverse.calibration(-60)
        reverse.processor.command('start')
        result = reverse.cycle(-60)
        self.assertEqual(result['cycles'], 1)
        self.assertAlmostEqual(result['rom_deg'], 60, delta=1)

    def test_inconsistent_trials_and_opposite_bend_rejected(self):
        rig = Rig()
        rig.standing()
        rig.processor.command('movement')
        rig.feed(seconds=0.35)
        rig.cycle(35)
        rig.cycle(60)
        self.assertEqual(rig.processor.command('finish_movement')['state'], 'movement')
        self.assertIsNotNone(rig.processor.snapshot()['reason'])
        rig = Rig()
        rig.standing()
        rig.processor.command('movement')
        rig.feed(seconds=0.35)
        rig.cycle(60)
        rig.ramp(-30)
        self.assertEqual(rig.processor.snapshot()['state'], 'needs_calibration')


class HeelTest(unittest.TestCase):
    def calibrate(self, unloaded=100, loaded=1000):
        rig = Rig()
        rig.processor.command('heel_unloaded')
        rig.feed(seconds=2.1, fsr=unloaded)
        self.assertIsNone(rig.processor.snapshot()['heel_contact'])
        rig.processor.command('heel_loaded')
        rig.feed(seconds=2.05, fsr=loaded)
        return rig

    def test_thresholds_hysteresis_dwell_and_reversed_signal(self):
        for unloaded, loaded, on, off, direction in ((100, 1000, 685, 415, 1),
                                                    (1000, 100, 415, 685, -1)):
            rig = self.calibrate(unloaded, loaded)
            self.assertEqual(rig.processor.heel_thresholds, (on, off, direction))
            self.assertIsNone(rig.feed(seconds=0.1, fsr=loaded)['heel_contact'])
            self.assertTrue(rig.feed(seconds=0.05, fsr=loaded)['heel_contact'])
            self.assertTrue(rig.feed(seconds=0.3, fsr=550)['heel_contact'])
            self.assertTrue(rig.feed(seconds=0.1, fsr=unloaded)['heel_contact'])
            self.assertFalse(rig.feed(seconds=0.05, fsr=unloaded)['heel_contact'])
            self.assertIsNone(rig.processor.snapshot()['cycles'])

    def test_overlap_can_skip_and_saturation_retains_contact(self):
        rig = self.calibrate(100, 120)
        self.assertIsNone(rig.processor.heel_thresholds)
        self.assertIsNone(rig.processor.snapshot()['heel_contact'])
        self.assertEqual(rig.processor.command('standing')['state'], 'standing')
        rig = self.calibrate(100, 4095)
        result = rig.feed(seconds=0.2, fsr=4095)
        self.assertTrue(result['heel_contact'])
        self.assertTrue(result['heel_saturated'])

    def test_loaded_recapture_clears_contact_and_failed_capture_stays_unknown(self):
        for unloaded, loaded, overlap in ((100, 1000, 120), (1000, 100, 980)):
            for stage in ('start', 'failed'):
                with self.subTest(unloaded=unloaded, stage=stage):
                    rig = self.calibrate(unloaded, loaded)
                    self.assertTrue(rig.feed(seconds=0.2, fsr=loaded)['heel_contact'])
                    rig.feed(seconds=0.05, fsr=unloaded)
                    self.assertFalse(rig.processor.contact_candidate)
                    result = rig.processor.command('heel_loaded')
                    if stage == 'failed':
                        result = rig.feed(seconds=2.1, fsr=overlap)
                        self.assertEqual(result['state'], 'setup')
                        self.assertIsNotNone(result['reason'])
                    self.assertIsNone(rig.processor.heel_thresholds)
                    self.assertIsNone(result['heel_contact'])
                    self.assertIsNone(rig.processor.contact_candidate)
                    self.assertIsNone(rig.processor.contact_since)
                    if stage == 'failed':
                        self.assertIsNone(rig.feed(seconds=0.3, fsr=loaded)['heel_contact'])
                        self.assertEqual(rig.processor.command('standing')['state'], 'standing')
                        result = rig.feed(seconds=3.1, fsr=loaded)
                        self.assertEqual(result['state'], 'movement_ready')
                        self.assertIsNone(result['heel_contact'])

    def test_capture_requires_duration_and_count(self):
        rig = Rig(dt=200_000)
        rig.processor.command('heel_unloaded')
        rig.feed(seconds=3, fsr=100)
        self.assertIsNone(rig.processor.heel_baseline)


class QualityBoundaryTest(unittest.TestCase):
    def test_quality_failure_keeps_independent_heel_contact(self):
        rig = HeelTest().calibrate()
        rig.feed(seconds=0.2, fsr=1000)
        rig.calibration()
        rig.feed(seconds=0.2, fsr=1000)
        rig.processor.command('start')
        sample = rig.sample(fsr=1000)
        sample['thigh_accel'][0] = 32767/16384
        result = rig.processor.process(sample)
        self.assertEqual(result['state'], 'interrupted')
        self.assertTrue(result['heel_contact'])

    def test_gravity_timeout_boundary_and_recovery(self):
        rig = Rig()
        rig.calibration()
        rig.processor.command('start')
        for _ in range(20):
            sample = rig.sample()
            sample['thigh_accel'] = [0, 1, 0]
            self.assertEqual(rig.processor.process(sample)['state'], 'active')
        sample = rig.sample()
        sample['thigh_accel'] = [0, 1, 0]
        self.assertEqual(rig.processor.process(sample)['state'], 'interrupted')

    def test_raw_and_scaled_equivalence_and_independent_board_mapping(self):
        rig = Rig()
        rig.processor.command('configure', {'ranges_confirmed': True, 'mounting_confirmed': True,
            'thigh_axis': {'index': 1, 'sign': 1}, 'shin_axis': {'index': 0, 'sign': -1}})
        rig.processor.command('standing')
        def mapped(thigh, shin):
            sample = rig.sample(thigh, shin)
            # Y inverse rotation: (-sin(theta),0,cos(theta)); flipped X:
            # (0,-sin(theta),cos(theta)). Physical angular velocity is -X.
            sample['shin_accel'] = [0, sample['shin_accel'][0], sample['shin_accel'][2]]
            sample['shin_gyro'] = [-sample['shin_gyro'][1], 0, 0]
            return sample
        for _ in range(62):
            rig.processor.process(mapped(0, 0))
        self.assertEqual(rig.processor.snapshot()['state'], 'movement_ready')
        rig.processor.command('movement')
        for angle in range(1, 61):
            sample = mapped(angle, angle/3)
            # Convert back to native counts; parser's raw fields can stay raw.
            sample['scaled'] = False
            for board in ('thigh', 'shin'):
                sample[board+'_accel'] = [x*16384 for x in sample[board+'_accel']]
                sample[board+'_gyro'] = [x*131 for x in sample[board+'_gyro']]
            result = rig.processor.process(sample)
        self.assertAlmostEqual(result['angle_deg'], 40, delta=1)


class CommandTest(unittest.TestCase):
    def test_rejected_commands_preserve_calibrated_active_state(self):
        rig = Rig()
        rig.calibration()
        rig.processor.command('start')
        rig.cycle()
        for action in ('configure', 'standing', 'movement', 'finish_movement', 'start',
                       'heel_unloaded', 'heel_loaded', 'retry', 'unknown'):
            before = rig.processor.snapshot()
            result = rig.processor.command(action, config())
            self.assertEqual(result['state'], 'active', action)
            self.assertEqual(result['cycles'], before['cycles'], action)
            self.assertEqual(result['rom_deg'], before['rom_deg'], action)
            self.assertIsNotNone(result['reason'], action)

    def test_frozen_summary_clears_only_after_successful_start(self):
        rig = Rig()
        rig.calibration()
        rig.processor.command('start')
        rig.cycle()
        summary = rig.processor.command('end')['summary']
        self.assertEqual(rig.processor.command('finish_movement')['summary'], summary)
        self.assertIsNone(rig.processor.command('start')['summary'])
        self.assertEqual(rig.processor.snapshot()['cycles'], 0)

    def test_configuration_requires_exact_boolean_and_integer_types(self):
        for field, value in (('ranges_confirmed', 1), ('mounting_confirmed', 'true'),
                             ('thigh_axis', {'index': True, 'sign': 1}),
                             ('shin_axis', {'index': 0, 'sign': 1.0})):
            p = SessionProcessor()
            setup = config()
            setup[field] = value
            self.assertEqual(p.command('configure', setup)['state'], 'setup')
            self.assertIsNone(p.config)
            self.assertIsNotNone(p.snapshot()['reason'])


if __name__ == '__main__':
    unittest.main()
