import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'android/app/src/main/python'))
from thigh_session import ThighProcessor, _display_tenths
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
    def test_observed_full_depth_survives_short_loss_and_counts_fresh_return_once(self):
        for parent in (False, True):
            for missing in (False, True):
                with self.subTest(parent=parent, missing=missing):
                    rig = ThighRig()
                    if parent:
                        rig.processor = SessionProcessor()
                    rig.processor.command('thigh_session_begin',
                                          {'exercise_id': 'squat', 'reference': reference(83.663)})
                    rig.feed(seconds=3.1)
                    rig.ramp(85.17)
                    detector = rig.processor.thigh if parent else rig.processor
                    self.assertEqual(detector.snapshot()['rep_phase'], 'depth_reached')
                    if missing:
                        for _ in range(5):
                            sample = rig.sample(85.17)
                            sample['thigh_accel'] = sample['thigh_gyro'] = None
                            result = rig.processor.process(sample)
                            self.assertEqual(detector.repetitions, 0)
                    rig.t = detector.last_t + 2_300_000
                    sample = rig.sample()
                    sample['thigh_gyro'] = [0, 0, 0]
                    rig.processor.process(sample)
                    self.assertEqual(detector.repetitions, 1)
                    self.assertAlmostEqual(detector.latest_peak, 85.17, delta=0.01)
                    rig.feed(seconds=1)
                    self.assertEqual(detector.repetitions, 1)

    def test_observed_reference_excursion_survives_missing_return(self):
        rig = ThighRig()
        rig.begin()
        rig.ramp(20)
        for _ in range(3):
            sample = rig.sample(20)
            sample['thigh_accel'] = sample['thigh_gyro'] = None
            rig.processor.process(sample)
        sample = rig.sample()
        sample['thigh_gyro'] = [0, 0, 0]
        result = rig.processor.process(sample)
        self.assertAlmostEqual(result['recorded_peak_deg'], 20, delta=0.01)
        self.assertEqual(rig.processor.command('thigh_reference_finish')['state'], 'reference_ready')

    def test_depth_precision_matches_dart_positive_half_rounding(self):
        for angle, tenths in ((57.15, 571), (57.25, 573), (57.45, 575),
                               (57.51, 575), (57.54, 575)):
            self.assertEqual(_display_tenths(angle), tenths)

    def test_initial_accel_clip_and_any_gyro_clip_still_interrupt(self):
        for recording in (False, True):
            for initial_zero in (False, True):
                for field in ('thigh_accel', 'thigh_gyro'):
                    if not initial_zero and field == 'thigh_accel':
                        continue
                    rig = ThighRig()
                    if initial_zero:
                        rig.processor.command('thigh_reference_begin', {'exercise_id': 'squat'})
                    else:
                        rig.begin(recording)
                    sample = rig.sample()
                    sample[field][0] = 32767 / (16384 if field == 'thigh_accel' else 131)
                    result = rig.processor.process(sample)
                    self.assertEqual(result['state'], 'interrupted')
                    self.assertIsNone(result['tilt_deg'])

    def test_accel_rail_fallback_does_not_accept_out_of_range_vectors(self):
        for field, value in (('thigh_accel', 2), ('thigh_accel', -2.01),
                              ('thigh_gyro', 251), ('thigh_gyro', -251)):
            rig = ThighRig()
            rig.begin(False)
            sample = rig.sample()
            sample[field][0] = value
            result = rig.processor.process(sample)
            self.assertEqual(result['state'], 'interrupted')
            self.assertIn('outside configured ranges', result['reason'])

    def test_raw_and_scaled_negative_accel_rail_keep_gyro_estimate(self):
        for raw in (False, True):
            rig = ThighRig()
            rig.begin(False)
            sample = rig.sample(1)
            sample['thigh_accel'][0] = -2
            if raw:
                sample['scaled'] = False
                for field, divisor in (('thigh_accel', 16384), ('thigh_gyro', 131)):
                    sample[field] = [round(value * divisor) for value in sample[field]]
            result = rig.processor.process(sample)
            self.assertEqual(result['state'], 'active')
            self.assertAlmostEqual(result['tilt_deg'], 1, delta=0.01)
            self.assertIn('using gyro', result['reason'])

    def test_clipped_accel_wait_after_gap_cannot_extend_deadline(self):
        rig = ThighRig()
        rig.begin(False)
        rig.cycle()
        last_fresh = rig.processor.last_t
        rig.t += 2_000_000
        sample = rig.sample()
        sample['thigh_accel'][2] = 32767 / 16384
        result = rig.processor.process(sample)
        self.assertEqual(result['state'], 'active')
        self.assertEqual(rig.processor.last_t, last_fresh)
        sample['time_us'] = last_fresh + 10_000_000
        result = rig.processor.process(sample)
        self.assertEqual(result['state'], 'interrupted')
        self.assertEqual(result['result']['repetitions'], 1)

    def test_acceleration_only_clip_uses_gyro_and_keeps_completed_rep(self):
        for recording in (False, True):
            rig = ThighRig()
            rig.begin(recording)
            for angle in range(1, 61):
                sample = rig.sample(angle)
                sample['thigh_accel'][2] = 32767 / 16384
                result = rig.processor.process(sample)
                self.assertEqual(result['state'], 'recording' if recording else 'active')
                self.assertAlmostEqual(result['tilt_deg'], angle, delta=0.01)
            result = rig.ramp(0)
            if recording:
                self.assertAlmostEqual(result['recorded_peak_deg'], 60, delta=0.01)
            else:
                self.assertEqual(result['repetitions'], 1)

    def test_clipped_acceleration_after_gap_waits_for_valid_pose(self):
        rig = ThighRig()
        rig.begin(False)
        rig.ramp(60)
        last_fresh = rig.processor.last_t
        rig.t += 2_000_000
        sample = rig.sample(60)
        sample['thigh_accel'][2] = 32767 / 16384
        result = rig.processor.process(sample)
        self.assertEqual(result['state'], 'active')
        self.assertIsNone(result['tilt_deg'])
        self.assertEqual(rig.processor.last_t, last_fresh)
        result = rig.processor.process(rig.sample(60))
        self.assertAlmostEqual(result['tilt_deg'], 60, delta=0.01)
        self.assertEqual(result['rep_phase'], 'depth_reached')
        self.assertEqual(rig.ramp(0)['repetitions'], 1)
        self.assertEqual(rig.cycle()['repetitions'], 2)

    def test_depth_comparison_matches_displayed_angle_precision(self):
        for saved, peak, expected in ((57.54, 57.51, 1), (57.5, 57.4, 0),
                                      (57.5, 57.46, 1), (57.5, 57.44, 0), (57.2, 57.15, 0)):
            with self.subTest(saved=saved, peak=peak):
                rig = ThighRig()
                rig.processor.command('thigh_session_begin',
                                      {'exercise_id': 'squat', 'reference': reference(saved)})
                rig.feed(seconds=3.1)
                self.assertEqual(rig.cycle(peak)['repetitions'], expected)

    def test_cycle_diagnostics_remember_peak_until_return_and_report_rejection(self):
        rig = ThighRig()
        rig.begin(False)
        self.assertEqual(rig.processor.snapshot()['rep_phase'], 'standing')
        result = rig.ramp(45)
        self.assertEqual(result['rep_phase'], 'moving')
        result = rig.ramp(0)
        self.assertEqual(result['rep_phase'], 'standing')
        self.assertAlmostEqual(result['last_completed_cycle_peak_deg'], 45, delta=0.01)
        self.assertIsNone(result['latest_peak_deg'])
        self.assertEqual(result['repetitions'], 0)
        self.assertEqual(rig.ramp(60)['rep_phase'], 'depth_reached')
        self.assertEqual(rig.ramp(30)['rep_phase'], 'depth_reached')
        result = rig.ramp(0)
        self.assertEqual(result['repetitions'], 1)
        self.assertAlmostEqual(result['last_completed_cycle_peak_deg'], 60, delta=0.01)

    def test_motion_without_trusted_gravity_keeps_visible_tilt(self):
        for recording in (True, False):
            rig = ThighRig()
            rig.begin(recording)
            for step in range(1, 81):
                angle = min(60, step * 1.5)
                sample = rig.sample(angle)
                sample['thigh_accel'] = [value * 1.2 for value in sample['thigh_accel']]
                result = rig.processor.process(sample)
                self.assertIsNotNone(result['tilt_deg'])
                self.assertAlmostEqual(result['tilt_deg'], angle, delta=0.01)
                self.assertIsNone(result['reason'])

    def test_reference_records_bend_return_without_minimum_depth_or_holds(self):
        rig = ThighRig()
        rig.begin()
        rig.ramp(20, seconds=0.15)
        result = rig.ramp(0, seconds=0.15)
        self.assertAlmostEqual(result['recorded_peak_deg'], 20, delta=0.01)
        rig.ramp(20)
        self.assertEqual(rig.processor.command('thigh_reference_finish')['state'], 'reference_ready')

    def test_session_requires_full_saved_depth_and_return_without_holds(self):
        rig = ThighRig()
        rig.begin(False)
        self.assertEqual(rig.cycle(59)['repetitions'], 0)
        rig.ramp(60, seconds=0.3)
        self.assertEqual(rig.processor.snapshot()['repetitions'], 0)
        result = rig.ramp(0, seconds=0.3)
        self.assertEqual(result['repetitions'], 1)

    def test_gap_and_missing_resume_visible_seated_pose_without_lost_rep(self):
        for missing in (False, True):
            rig = ThighRig()
            rig.begin(False)
            rig.ramp(60)
            if missing:
                sample = rig.sample(60)
                sample['thigh_accel'] = sample['thigh_gyro'] = None
                self.assertIsNone(rig.processor.process(sample)['tilt_deg'])
            else:
                rig.t += 2_000_000
            result = rig.processor.process(rig.sample(60))
            self.assertAlmostEqual(result['tilt_deg'], 60, delta=0.01)
            self.assertIsNone(result['reason'])
            self.assertEqual(rig.ramp(0)['repetitions'], 1)
            self.assertEqual(rig.cycle()['repetitions'], 2)

    def test_zero_acceleration_after_gap_waits_for_pose_and_cannot_extend_deadline(self):
        for recover in (False, True):
            rig = ThighRig()
            rig.begin(False)
            rig.ramp(60)
            last_fresh = rig.processor.last_t
            rig.t += 2_000_000
            sample = rig.sample(60)
            sample['thigh_accel'] = [0, 0, 0]
            sample['thigh_gyro'] = [0, 1, 0]
            result = rig.processor.process(sample)
            self.assertEqual(result['state'], 'active')
            self.assertIsNone(result['tilt_deg'])
            self.assertIn('valid thigh acceleration', result['reason'])
            self.assertEqual(rig.processor.last_t, last_fresh)
            if recover:
                result = rig.processor.process(rig.sample(60))
                self.assertAlmostEqual(result['tilt_deg'], 60, delta=0.01)
                self.assertIsNone(result['reason'])
                self.assertEqual(rig.ramp(0)['repetitions'], 1)
                self.assertEqual(rig.cycle()['repetitions'], 2)
            else:
                sample['time_us'] = last_fresh + 10_000_000
                result = rig.processor.process(sample)
                self.assertEqual(result['state'], 'interrupted')
                self.assertEqual(result['result']['repetitions'], 0)

    def test_contiguous_zero_acceleration_uses_calibrated_gyro(self):
        rig = ThighRig()
        rig.begin()
        for step in range(1, 41):
            sample = rig.sample(step)
            sample['thigh_accel'] = [0, 0, 0]
            result = rig.processor.process(sample)
            self.assertAlmostEqual(result['tilt_deg'], step, delta=0.01)
            self.assertIsNone(result['reason'])

    def test_gap_under_ten_seconds_recovers_all_modes(self):
        for parent in (False, True):
            for mode in ('zeroing', 'recording', 'active'):
                for gap_us in (1_352_000, 9_999_999):
                    with self.subTest(parent=parent, mode=mode, gap_us=gap_us):
                        rig = ThighRig()
                        if parent:
                            rig.processor = SessionProcessor()
                        rig.processor.command(
                            'thigh_session_begin' if mode == 'active' else 'thigh_reference_begin',
                            {'exercise_id': 'squat', 'reference': reference(), 'rep_target': 3})
                        rig.feed(seconds=1 if mode == 'zeroing' else 3.1)
                        detector = rig.processor.thigh if parent else rig.processor
                        if mode == 'active':
                            rig.cycle(70)
                        completed = detector.repetitions
                        # Replace the next frame interval, not its elapsed arrival time.
                        rig.t = detector.last_t + gap_us
                        snapshot = rig.feed(seconds=0.05)
                        thigh = snapshot['thigh'] if parent else snapshot
                        self.assertEqual(thigh['state'], mode)
                        self.assertIsNone(thigh['result'])
                        self.assertEqual(thigh['repetitions'], completed)
                        if mode == 'zeroing':
                            self.assertEqual(thigh['zero_progress'], 0)
                            rig.feed(seconds=3.1)
                            self.assertEqual(detector.state, 'recording')
                        else:
                            rig.feed(seconds=0.5)
                            self.assertIsNone(detector.reason)
                            rig.cycle(70)
                            if mode == 'active':
                                self.assertEqual(detector.repetitions, completed + 1)
                            else:
                                self.assertIsNotNone(detector.recorded_peak)

    def test_missing_readings_wait_then_resume_from_fresh_values(self):
        for mode in ('zeroing', 'recording', 'active'):
            with self.subTest(mode=mode):
                rig = ThighRig()
                rig.processor.command(
                    'thigh_session_begin' if mode == 'active' else 'thigh_reference_begin',
                    {'exercise_id': 'squat', 'reference': reference()})
                rig.feed(seconds=1 if mode == 'zeroing' else 3.1)
                if mode == 'active':
                    rig.cycle(70)
                completed = rig.processor.repetitions
                if mode != 'zeroing':
                    rig.ramp(45)
                for _ in range(160):
                    sample = rig.sample(45 if mode != 'zeroing' else 0)
                    sample['thigh_accel'] = sample['thigh_gyro'] = None
                    result = rig.processor.process(sample)
                    self.assertEqual(result['state'], mode)
                    self.assertIsNone(result['tilt_deg'])
                    self.assertIsNone(result['result'])
                    self.assertIn('10 seconds', result['reason'])
                if mode == 'zeroing':
                    rig.feed(seconds=3.1)
                    self.assertEqual(rig.processor.state, 'recording')
                else:
                    rig.ramp(0)
                    rig.feed(seconds=0.5)
                    self.assertIsNone(rig.processor.reason)
                    self.assertEqual(rig.processor.repetitions, completed)
                    if mode == 'recording':
                        self.assertAlmostEqual(rig.processor.recorded_peak, 45, delta=0.01)
                    else:
                        self.assertIsNone(rig.processor.recorded_peak)
                    rig.cycle(70)
                    self.assertEqual(rig.processor.repetitions, completed + (mode == 'active'))

    def test_ten_second_loss_interrupts_and_keeps_completed_reps(self):
        for missing in (False, True):
            with self.subTest(missing=missing):
                rig = ThighRig()
                rig.begin(False)
                rig.cycle(70)
                duration = (rig.processor.last_t - rig.processor.active_start) / 1e6
                sample = rig.sample()
                sample['time_us'] = rig.processor.last_t + 10_000_000
                if missing:
                    sample['thigh_accel'] = sample['thigh_gyro'] = None
                result = rig.processor.process(sample)
                self.assertEqual(result['state'], 'interrupted')
                self.assertEqual(result['result']['repetitions'], 1)
                self.assertEqual(result['result']['active_s'], duration)

    def test_missing_from_first_zero_sample_has_bounded_wait(self):
        rig = ThighRig()
        rig.processor.command('thigh_reference_begin', {'exercise_id': 'squat'})
        for _ in range(200):
            sample = rig.sample()
            sample['thigh_accel'] = sample['thigh_gyro'] = None
            result = rig.processor.process(sample)
            self.assertEqual(result['state'], 'zeroing')
            self.assertEqual(result['zero_progress'], 0)
        sample = rig.sample()
        sample['thigh_accel'] = sample['thigh_gyro'] = None
        self.assertEqual(rig.processor.process(sample)['state'], 'interrupted')

    def test_complete_short_cycle_counts_without_one_second_minimum(self):
        for recording in (True, False):
            with self.subTest(recording=recording):
                rig = ThighRig()
                rig.begin(recording)
                rig.ramp(60, seconds=0.3)
                rig.feed(60, seconds=0.35)
                rig.ramp(0, seconds=0.3)
                result = rig.feed(seconds=0.4)
                if recording:
                    self.assertIsNotNone(result['recorded_peak_deg'])
                else:
                    self.assertEqual(result['repetitions'], 1)

    def test_dynamic_gravity_does_not_pause_or_discard_contiguous_movement(self):
        for recording in (True, False):
            rig = ThighRig()
            rig.begin(recording)
            zero, bias = list(rig.processor.zero_gravity), list(rig.processor.bias)
            rig.ramp(70)
            for _ in range(62):
                sample = rig.sample(70)
                sample['thigh_accel'] = [value * 1.2 for value in sample['thigh_accel']]
                result = rig.processor.process(sample)
                self.assertAlmostEqual(result['tilt_deg'], 70, delta=0.01)
                self.assertIsNone(result['reason'])
            result = rig.ramp(0)
            self.assertEqual(rig.processor.zero_gravity, zero)
            self.assertEqual(rig.processor.bias, bias)
            if recording:
                self.assertAlmostEqual(result['recorded_peak_deg'], 70, delta=0.01)
            else:
                self.assertEqual(result['repetitions'], 1)

    def test_451ms_gap_recovers_all_thigh_modes_without_lost_partial_rep(self):
        for parent in (False, True):
            for exercise_id in ('squat', 'sit_to_stand'):
                for state in ('zeroing', 'recording', 'active'):
                    with self.subTest(parent=parent, exercise_id=exercise_id, state=state):
                        rig = ThighRig()
                        if parent:
                            rig.processor = SessionProcessor()
                        saved = reference(30)
                        saved['exercise_id'] = exercise_id
                        rig.processor.command(
                            'thigh_session_begin' if state == 'active' else 'thigh_reference_begin',
                            {'exercise_id': exercise_id, 'reference': saved, 'rep_target': 3})
                        rig.feed(seconds=1 if state == 'zeroing' else 3.1)
                        detector = rig.processor.thigh if parent else rig.processor
                        if state == 'active':
                            rig.cycle(70)
                        completed_reps = detector.repetitions
                        if state != 'zeroing':
                            rig.ramp(50)
                            rig.feed(50)
                        rig.t += 401_000
                        snapshot = rig.feed(0 if state == 'zeroing' else 50, seconds=0.05)
                        thigh = snapshot['thigh'] if parent else snapshot
                        self.assertEqual(thigh['state'], state)
                        self.assertIsNone(thigh['reason'])
                        self.assertIsNone(thigh['result'])
                        self.assertEqual(detector.repetitions, completed_reps)
                        if state == 'zeroing':
                            self.assertEqual(thigh['zero_progress'], 0)
                            snapshot = rig.feed(seconds=3.1)
                            thigh = snapshot['thigh'] if parent else snapshot
                            self.assertEqual(thigh['state'], 'recording')
                            continue
                        self.assertAlmostEqual(thigh['tilt_deg'], 50, delta=0.01)
                        self.assertIsNotNone(detector.departure)
                        # Eight degrees is within the reference recorder's band,
                        # but outside this active exercise's saved 5-degree band.
                        if state == 'active':
                            rig.ramp(8)
                            rig.feed(8, seconds=0.5)
                            self.assertAlmostEqual(detector.snapshot()['tilt_deg'], 8, delta=0.1)
                            self.assertEqual(detector.reference, saved)
                            self.assertEqual(detector.rep_target, 3)
                        rig.ramp(0)
                        rig.feed(seconds=0.5)
                        self.assertEqual(detector.repetitions, completed_reps + (state == 'active'))
                        if state == 'recording':
                            self.assertAlmostEqual(detector.recorded_peak, 50, delta=0.01)
                        rig.cycle(70)
                        if state == 'recording':
                            self.assertAlmostEqual(detector.recorded_peak, 50, delta=1)
                        else:
                            self.assertEqual(detector.repetitions, 3)
                            self.assertEqual(detector.result['repetitions'], 3)
                            self.assertEqual(detector.result['outcome'], 'target_reached')
                            self.assertEqual(detector.result['active_s'],
                                             (detector.last_t - detector.active_start) / 1e6)

    def test_active_one_second_gap_recovers_without_integrating_missing_time(self):
        rig = ThighRig()
        rig.begin(False)
        rig.t += 950_000
        sample = rig.sample()
        sample['thigh_gyro'] = [0, 100, 0]
        snapshot = rig.processor.process(sample)
        self.assertEqual(snapshot['state'], 'active')
        self.assertIsNone(snapshot['result'])
        self.assertAlmostEqual(snapshot['tilt_deg'], 0)
        self.assertAlmostEqual(rig.processor.tilt, 0)
        rig.feed(seconds=0.5)
        self.assertTrue(rig.processor.cycle_armed)
        self.assertEqual(rig.cycle()['repetitions'], 1)

    def test_fresh_thigh_begin_ignores_precommand_gap_or_reset(self):
        for parent in (False, True):
            for recording in (False, True):
                for exercise_id in ('squat', 'sit_to_stand'):
                    for reset in (False, True):
                        with self.subTest(parent=parent, recording=recording,
                                          exercise_id=exercise_id, reset=reset):
                            rig = ThighRig()
                            if parent:
                                rig.processor = SessionProcessor()
                            rig.t = 1_000_000
                            rig.processor.process(rig.sample())
                            rig.t = 1 if reset else 3_702_000
                            saved_reference = reference()
                            saved_reference['exercise_id'] = exercise_id
                            rig.processor.command(
                                'thigh_reference_begin' if recording else 'thigh_session_begin',
                                {'exercise_id': exercise_id, 'reference': saved_reference,
                                 'rep_target': 10})
                            snapshot = rig.processor.process(rig.sample())
                            thigh = snapshot['thigh'] if parent else snapshot
                            self.assertEqual(thigh['state'], 'zeroing')
                            self.assertIsNone(thigh['reason'])
                            snapshot = rig.feed(seconds=3.1)
                            thigh = snapshot['thigh'] if parent else snapshot
                            self.assertEqual(thigh['state'], 'recording' if recording else 'active')

    def test_parent_long_gap_freezes_real_active_result(self):
        rig = ThighRig()
        rig.processor = SessionProcessor()
        rig.processor.command('thigh_session_begin',
                              {'exercise_id': 'squat', 'reference': reference(), 'rep_target': 10})
        rig.feed(seconds=3.1)
        rig.cycle(70)
        duration = (rig.processor.thigh.last_t - rig.processor.thigh.active_start) / 1e6
        rig.t += 10_000_000
        snapshot = rig.processor.process(rig.sample())['thigh']
        self.assertEqual(snapshot['state'], 'interrupted')
        self.assertIn('10.1 seconds', snapshot['reason'])
        frozen = snapshot['result']
        self.assertEqual(frozen['repetitions'], 1)
        self.assertEqual(frozen['outcome'], 'interrupted')
        self.assertEqual(frozen['active_s'], duration)
        self.assertEqual(rig.cycle(70)['thigh']['result'], frozen)

    def test_reference_short_gap_shows_pose_and_retains_observed_bend(self):
        for exercise_id in ('squat', 'sit_to_stand'):
            for parent in (False, True):
                with self.subTest(exercise_id=exercise_id, parent=parent):
                    rig = ThighRig()
                    if parent:
                        rig.processor = SessionProcessor()
                    def thigh(snapshot):
                        return snapshot['thigh'] if parent else snapshot
                    rig.processor.command('thigh_reference_begin', {'exercise_id': exercise_id})
                    rig.feed(seconds=3.1)
                    detector = rig.processor.thigh if parent else rig.processor
                    zero, bias = list(detector.zero_gravity), list(detector.bias)
                    rig.ramp(60)
                    rig.feed(60)
                    rig.t += 300_000
                    resumed = thigh(rig.feed(60, seconds=0.05))
                    self.assertEqual(resumed['state'], 'recording')
                    self.assertIsNone(resumed['reason'])
                    self.assertAlmostEqual(resumed['tilt_deg'], 60, delta=0.01)
                    self.assertIsNone(resumed['recorded_peak_deg'])
                    self.assertEqual(detector.zero_gravity, zero)
                    self.assertEqual(detector.bias, bias)
                    self.assertIsNotNone(detector.departure)
                    # Fresh standing completes the already observed bend.
                    rig.ramp(0)
                    rig.feed(seconds=0.5)
                    self.assertAlmostEqual(thigh(rig.processor.snapshot())['recorded_peak_deg'], 60, delta=0.01)
                    completed = thigh(rig.cycle(70))
                    self.assertAlmostEqual(completed['recorded_peak_deg'], 60, delta=1)
                    self.assertEqual(thigh(rig.processor.command('thigh_reference_finish'))['state'], 'reference_ready')

    def test_reference_reset_long_gap_and_active_gap_still_interrupt(self):
        for parent in (False, True):
            for failure in ('reset', 'long_gap', 'active'):
                with self.subTest(parent=parent, failure=failure):
                    rig = ThighRig()
                    if parent:
                        rig.processor = SessionProcessor()
                    action = 'thigh_session_begin' if failure == 'active' else 'thigh_reference_begin'
                    rig.processor.command(action, {'exercise_id': 'squat', 'reference': reference()})
                    rig.feed(seconds=3.1)
                    if failure == 'active':
                        rig.cycle(70)
                    sample = rig.sample()
                    sample['time_us'] = 1 if failure == 'reset' else sample['time_us'] + 10_000_000
                    snapshot = rig.processor.process(sample)
                    result = snapshot['thigh'] if parent else snapshot
                    self.assertEqual(result['state'], 'interrupted')
                    self.assertIn('reset' if failure == 'reset' else 'seconds', result['reason'])
                    if failure == 'active':
                        self.assertEqual(result['result']['repetitions'], 1)
                        self.assertEqual(result['result']['outcome'], 'interrupted')

    def test_fresh_gap_pose_rearms_without_stillness_or_gyro_hold(self):
        rig = ThighRig()
        rig.begin()
        rig.ramp(60)
        rig.t += 950_000
        sample = rig.sample(60)
        sample['thigh_gyro'] = [0, 100, 0]
        result = rig.processor.process(sample)
        self.assertAlmostEqual(result['tilt_deg'], 60, delta=0.01)
        self.assertTrue(rig.processor.cycle_armed)
        self.assertIsNone(result['recorded_peak_deg'])
        result = rig.ramp(0)
        self.assertTrue(rig.processor.cycle_armed)
        self.assertAlmostEqual(result['recorded_peak_deg'], 60, delta=0.01)
        self.assertAlmostEqual(rig.cycle()['recorded_peak_deg'], 60, delta=0.01)

    def test_completed_reference_can_finish_after_gap_or_new_bend(self):
        for gap in (False, True):
            rig = ThighRig()
            rig.begin()
            rig.cycle()
            rig.ramp(45)
            if gap:
                rig.t += 300_000
                rig.feed(45, seconds=0.05)
            result = rig.processor.command('thigh_reference_finish')
            self.assertEqual(result['state'], 'reference_ready')
            self.assertAlmostEqual(result['recorded_peak_deg'], 60, delta=0.01)

    def test_cancel_after_zero_finishes_preserves_active_result(self):
        for completed_rep in (False, True):
            with self.subTest(completed_rep=completed_rep):
                rig = ThighRig()
                rig.begin(False)
                if completed_rep:
                    rig.cycle(70)
                result = rig.processor.command('thigh_cancel')
                self.assertEqual(result['state'], 'ended')
                self.assertEqual(result['result']['outcome'], 'ended_early')
                self.assertEqual(result['result']['repetitions'], int(completed_rep))
                frozen = result['result'].copy()
                self.assertEqual(rig.cycle()['result'], frozen)
        rig = ThighRig()
        rig.processor.command('thigh_session_begin', {'exercise_id': 'squat', 'reference': reference()})
        rig.feed(seconds=2.9)
        cancelled = rig.processor.command('thigh_cancel')
        self.assertEqual(cancelled['state'], 'idle')
        self.assertIsNone(cancelled['result'])

    def test_target_ends_at_two_and_freezes_after_further_cycles(self):
        rig = ThighRig()
        rig.processor.command('thigh_session_begin', {'exercise_id': 'squat',
                              'reference': reference(), 'rep_target': 2})
        rig.feed(seconds=3.1)
        active_start = rig.processor.last_t - 50_000
        self.assertEqual(rig.cycle()['state'], 'active')
        result = rig.cycle(70)
        self.assertEqual(result['state'], 'ended')
        frozen = result['result'].copy()
        self.assertEqual((frozen['repetitions'], frozen['rep_target'], frozen['outcome']),
                         (2, 2, 'target_reached'))
        self.assertAlmostEqual(frozen['active_s'], (rig.processor.last_t-active_start)/1e6)
        self.assertAlmostEqual(frozen['latest_peak_deg'], 70, delta=1)
        self.assertAlmostEqual(frozen['difference_deg'], 10, delta=1)
        self.assertEqual(rig.cycle()['result'], frozen)
        self.assertEqual(rig.processor.interrupt('Disconnected')['result'], frozen)

    def test_early_end_and_interrupt_keep_completed_reps_and_exclude_zero(self):
        for interrupted in (False, True):
            with self.subTest(interrupted=interrupted):
                rig = ThighRig()
                rig.begin(False)
                rig.cycle(70)
                result = (rig.processor.interrupt('Disconnected') if interrupted
                          else rig.processor.command('thigh_session_end'))['result']
                self.assertEqual(result['repetitions'], 1)
                self.assertIsNone(result['rep_target'])
                self.assertEqual(result['outcome'], 'interrupted' if interrupted else 'ended_early')
                self.assertLess(result['active_s'], rig.t/1e6-2.9)
                self.assertAlmostEqual(result['latest_peak_deg'], 70, delta=1)
                self.assertEqual(rig.processor.interrupt('Again')['result'], result)
        rig = ThighRig()
        rig.begin(False)
        result = rig.processor.command('thigh_session_end')['result']
        self.assertEqual(result['repetitions'], 0)
        self.assertIsNone(result['latest_peak_deg'])
        self.assertIsNone(result['difference_deg'])

    def test_targets_are_optional_strict_and_new_begin_clears_old_result(self):
        for target in (None, True, 1.0, 0, -1, 1001, '2'):
            processor = ThighProcessor()
            result = processor.command('thigh_session_begin', {'exercise_id': 'squat',
                                       'reference': reference(), 'rep_target': target})
            self.assertEqual(result['state'], 'idle')
            self.assertIsNotNone(result['reason'])
        for target in (1, 1000):
            processor = ThighProcessor()
            self.assertEqual(processor.command('thigh_session_begin', {'exercise_id': 'squat',
                             'reference': reference(), 'rep_target': target})['state'], 'zeroing')
        rig = ThighRig()
        rig.begin(False)
        rig.processor.command('thigh_session_end')
        self.assertIsNotNone(rig.processor.snapshot()['result'])
        rig.processor.command('thigh_session_begin', {'exercise_id': 'squat', 'reference': reference()})
        self.assertIsNone(rig.processor.snapshot()['result'])
        self.assertIsNone(rig.processor.interrupt('During zero')['result'])

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
        result = rig.cycle(70)
        self.assertEqual(result['repetitions'], 1)
        self.assertAlmostEqual(result['latest_peak_deg'], 70, delta=1)
        self.assertAlmostEqual(result['difference_deg'], 10, delta=1)
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
                        sample['time_us'] += 10_000_000
                    elif failure == 'clipped':
                        sample['thigh_gyro'][0] = 32767/131
                    else:
                        sample['time_us'] += 10_000_000
                    result = rig.processor.process(sample)
                self.assertEqual(result['state'], 'interrupted')
                self.assertIsNone(result['tilt_deg'])
                self.assertEqual(result['reference_peak_deg'], 60)

    def test_genuine_sensor_faults_still_interrupt_during_continuous_motion(self):
        for recording in (True, False):
            for failure in ('missing', 'nonfinite', 'clipped', 'reset', 'long_gap'):
                with self.subTest(recording=recording, failure=failure):
                    rig = ThighRig()
                    rig.begin(recording)
                    for _ in range(22):
                        sample = rig.sample()
                        sample['thigh_accel'] = [0, 0, 1.2]
                        rig.processor.process(sample)
                    self.assertIsNotNone(rig.processor.snapshot()['tilt_deg'])
                    sample = rig.sample()
                    if failure == 'missing':
                        sample['thigh_accel'] = None
                        sample['time_us'] += 10_000_000
                    elif failure == 'nonfinite':
                        sample['thigh_accel'][0] = float('nan')
                    elif failure == 'clipped':
                        sample['thigh_gyro'][0] = 32767/131
                    elif failure == 'reset':
                        sample['time_us'] = 1
                    else:
                        sample['time_us'] += 10_000_000
                    result = rig.processor.process(sample)
                    self.assertEqual(result['state'], 'interrupted')
                    self.assertIsNone(result['tilt_deg'])

    def test_payloads_reject_wrong_exercise_or_reference(self):
        processor = ThighProcessor()
        for payload in ({'exercise_id': 'unknown'}, {'exercise_id': 'squat'},
                        {'exercise_id': 'sit_to_stand', 'reference': reference()}):
            result = processor.command('thigh_session_begin', payload)
            self.assertEqual(result['state'], 'idle')
            self.assertIsNotNone(result['reason'])

    def test_invalid_reference_numbers_cancel_and_gravity_recovery(self):
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
        self.assertEqual(result['state'], 'active')
        self.assertIsNotNone(rig.processor.snapshot()['tilt_deg'])
        self.assertAlmostEqual(result['tilt_deg'], 0)
        result = rig.processor.command('thigh_cancel')
        self.assertEqual(result['state'], 'ended')
        self.assertEqual(result['result']['outcome'], 'ended_early')
        self.assertEqual(result['reference_peak_deg'], 60)

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
