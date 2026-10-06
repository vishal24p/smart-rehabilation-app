import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'android/app/src/main/python'))
from rehab_sensor import SensorParser
from rehab_session import SessionProcessor

HEADER = 'time_us,thigh_ax,thigh_ay,thigh_az,thigh_gx,thigh_gy,thigh_gz,shin_ax,shin_ay,shin_az,shin_gx,shin_gy,shin_gz,fsr'


def frame(timestamp=100, fsr=500, acceleration=16384):
    return ','.join(map(str, [timestamp, acceleration, 0, -16384, 131, 0, -131,
                             0, 16384, 0, 0, 131, 0, fsr]))


class SensorParserTest(unittest.TestCase):
    def test_named_one_and_two_imu_headers_map_heels_without_faking_shin(self):
        headers = (HEADER.split(',')[:7], HEADER.split(',')[:13])
        for motion_header in headers:
            with self.subTest(motion_fields=len(motion_header)):
                parser = SensorParser(True)
                parser.process_line(','.join(motion_header + ['fsr_left', 'fsr_right']))
                motion = frame().split(',')[:len(motion_header)]
                sample = json.loads(parser.process_line(','.join(motion + ['200', '800'])))
                self.assertEqual((sample['fsr_left'], sample['fsr']), (800, 200))
                self.assertEqual(sample['thigh_gyro'], [1, 0, -1])
                if len(motion_header) == 7:
                    self.assertIsNone(sample['shin_accel'])
                    self.assertIsNone(sample['shin_gyro'])
                    self.assertIn('Missing shin', sample['analytics']['reason'])
                else:
                    self.assertEqual(sample['shin_gyro'], [0, 1, 0])
                self.assertIsNone(parser.process_line(','.join(motion + ['4096', '800'])))
                self.assertIsNone(parser.process_line(','.join(motion + ['200', '-1'])))

    def test_thigh_only_failure_placeholder_keeps_heels_and_full_stream_restores(self):
        parser = SensorParser()
        parser.process_line(','.join(HEADER.split(',')[:7] + ['fsr_left', 'fsr_right']))
        sample = json.loads(parser.process_line('100,0,0,0,0,0,0,200,800'))
        self.assertIsNone(sample['thigh_accel'])
        self.assertIsNone(sample['thigh_gyro'])
        self.assertEqual((sample['fsr_left'], sample['fsr']), (800, 200))
        self.assertFalse(parser.processor.motion_available)
        parser.process_line(HEADER)
        sample = json.loads(parser.process_line(frame(200)))
        self.assertTrue(parser.processor.motion_available)
        self.assertEqual(sample['shin_accel'], [0, 16384, 0])

    def test_dual_header_preserves_motion_and_validates_each_adc(self):
        parser = SensorParser(True)
        parser.process_line(HEADER + ',fsr_left')
        sample = json.loads(parser.process_line(frame(fsr=750) + ',250'))
        self.assertEqual((sample['fsr'], sample['fsr_left']), (250, 750))
        self.assertEqual(sample['shin_gyro'], [0, 1, 0])
        for right, left in ((-1, 100), (4096, 100), (100, -1), (100, 4096)):
            self.assertIsNone(parser.process_line(frame(200, fsr=right) + ',' + str(left)))
        self.assertIsNone(parser.process_line(frame(200)))
        parser.process_line(HEADER)
        self.assertNotIn('fsr_left', json.loads(parser.process_line(frame(200))))

    def parser(self, scaled=False):
        parser = SensorParser(scaled)
        self.assertIsNone(parser.process_line(HEADER + '\r\n'))
        return parser

    def test_requires_supported_header(self):
        parser = SensorParser()
        self.assertIsNone(parser.process_line(frame()))
        for header in ('time_us,fsr', HEADER.replace('thigh_ax', 'thigh_bad'),
                       HEADER.replace('thigh_ax,thigh_ay', 'thigh_ay,thigh_ax'),
                       HEADER.replace('time_us', 'time_ms')):
            with self.subTest(header=header), self.assertRaises(ValueError):
                parser.process_line(header)
        self.assertIsNone(parser.process_line(HEADER))
        self.assertIsNotNone(parser.process_line(frame()))

    def test_raw_units_until_confirmed(self):
        sample = json.loads(self.parser().process_line(frame()))
        self.assertEqual(sample['type'], 'sample')
        self.assertFalse(sample['scaled'])
        self.assertEqual(sample['thigh_accel'], [16384, 0, -16384])
        self.assertEqual(sample['thigh_gyro'], [131, 0, -131])
        self.assertEqual(sample['fsr'], 500)

    def test_unsupported_header_invalidates_previous_header(self):
        for header in (HEADER.split(',', 1)[1], HEADER.replace('time_us', 'timestamp-us')):
            with self.subTest(header=header):
                parser = self.parser()
                self.assertIsNotNone(parser.process_line(frame()))
                with self.assertRaises(ValueError):
                    parser.process_line(header)
                self.assertIsNone(parser.process_line(frame(101)))

    def test_default_range_conversion(self):
        sample = json.loads(self.parser(True).process_line(frame()))
        self.assertTrue(sample['scaled'])
        self.assertEqual(sample['thigh_accel'], [1, 0, -1])
        self.assertEqual(sample['thigh_gyro'], [1, 0, -1])
        self.assertEqual(sample['shin_accel'], [0, 1, 0])
        self.assertEqual(sample['shin_gyro'], [0, 1, 0])

    def test_rejects_wrong_field_count_and_out_of_range(self):
        parser = self.parser()
        invalid = [frame(fsr=4096), frame(fsr=-1), frame(acceleration=32768),
                   frame(acceleration=-32769), frame(timestamp=-1),
                   frame(timestamp=2**32), frame() + ',1', '1,2',
                   frame().replace('16384', '1.5'), '', 'not,a,sample',
                   frame().replace('16384', 'thigh_ax'),
                   frame().replace('16384', '16_384'),
                   ' ' * 513 + frame()]
        for line in invalid:
            with self.subTest(line=line):
                self.assertIsNone(parser.process_line(line))
        self.assertIsNotNone(parser.process_line(frame(fsr=4095, acceleration=-32768)))

    def test_timestamp_rollback_resets_stream(self):
        parser = self.parser()
        self.assertFalse(json.loads(parser.process_line(frame(200)))['restart'])
        self.assertTrue(json.loads(parser.process_line(frame(100)))['restart'])
        self.assertFalse(json.loads(parser.process_line(frame(101)))['restart'])

    def test_duplicate_timestamp_ignored(self):
        parser = self.parser()
        self.assertIsNotNone(parser.process_line(frame()))
        self.assertIsNone(parser.process_line(frame()))
        parser.process_line(HEADER)
        self.assertIsNotNone(parser.process_line(frame()))


class ParserAnalyticsTest(unittest.TestCase):
    def test_invalid_required_frames_interrupt_gait_but_leave_legacy_parser_behavior(self):
        from test_gait_session import GaitRig
        edits = ('negative_timestamp', 'large_timestamp', 'missing_channel', 'extra_channel',
                 'invalid_number', 'negative_fsr', 'large_fsr', 'clipped_raw_imu', 'oversized')
        for action in ('gait_reference_begin', 'gait_session_begin', 'gait_forefoot_unloaded', 'gait_forefoot_loaded', 'gait_standing'):
            for edit in edits:
                with self.subTest(action=action, edit=edit):
                    processor = SessionProcessor()
                    parser = SensorParser(True, processor)
                    parser.process_line(HEADER + ',fsr_left')
                    rig = GaitRig(processor)
                    rig.calibrate()
                    if action == 'gait_session_begin':
                        rig.begin()
                        rig.walk()
                        reference = rig.finish()['reference_preview']
                        rig.begin(reference)
                        rig.walk()
                    elif action == 'gait_reference_begin':
                        rig.begin()
                        rig.walk()
                    else:
                        rig.command(action)
                    values = [str(value) for value in [rig.t, 0, 0, 16384, 0, 0, 0,
                                                       0, 0, 16384, 0, 0, 0, 100, 100]]
                    if edit == 'negative_timestamp': values[0] = '-1'
                    elif edit == 'large_timestamp': values[0] = str(0x100000000)
                    elif edit == 'missing_channel': values.pop()
                    elif edit == 'extra_channel': values.append('100')
                    elif edit == 'invalid_number': values[8] = 'missing'
                    elif edit == 'negative_fsr': values[-1] = '-1'
                    elif edit == 'large_fsr': values[-1] = '4096'
                    elif edit == 'clipped_raw_imu': values[1] = '32768'
                    elif edit == 'oversized': values[1] = '1' * 513
                    legacy_state = processor.snapshot()['state']
                    self.assertIsNone(parser.process_line(','.join(values)))
                    result = processor.snapshot()['gait']
                    self.assertEqual(result['state'], 'interrupted')
                    self.assertIsNone(result['reference_preview'])
                    if action in ('gait_reference_begin', 'gait_session_begin'):
                        self.assertEqual(result['comparison'], 'insufficient_data')
                        self.assertTrue(result['summary']['interrupted'])
                    self.assertEqual(processor.snapshot()['state'], legacy_state)

    def test_gait_physical_sides_and_header_restart_preserve_interrupted_summary(self):
        from test_gait_session import GaitRig
        processor = SessionProcessor()
        parser = SensorParser(True, processor)
        parser.process_line(HEADER + ',fsr_left')
        rig = GaitRig(processor)
        rig.calibrate()
        rig.begin()

        def feed(right, left):
            for _ in range(5):
                # Legacy fsr is physical left; parser's established correction remains.
                values = [rig.t, 0, 0, 16384, 0, 0, 0, 0, 0, 16384, 0, 0, 0, left, right]
                sample = json.loads(parser.process_line(','.join(map(str, values))))
                rig.t += 20_000
            return sample['analytics']['gait']

        feed(100, 100)
        result = feed(900, 100)
        self.assertEqual(result['metrics']['right_steps'], 1)
        self.assertEqual(result['metrics']['left_steps'], 0)
        parser.process_line(HEADER + ',fsr_left')
        result = processor.snapshot()['gait']
        self.assertTrue(result['summary']['interrupted'])
        self.assertEqual(result['comparison'], 'insufficient_data')
        self.assertEqual(result['summary']['metrics']['right_steps'], 1)

    def test_physical_heel_mapping_reaches_processor_and_calibrated_shares(self):
        full_motion = HEADER.split(',')[:13]
        for header in (HEADER.split(',')[:7] + ['fsr_left', 'fsr_right'],
                       full_motion + ['fsr_left', 'fsr_right'],
                       HEADER.split(',') + ['fsr_left']):
            with self.subTest(header=header):
                processor = SessionProcessor()
                parser = SensorParser(processor=processor)
                parser.process_line(','.join(header))
                timestamp = 100

                def feed(wire_left, wire_right):
                    nonlocal timestamp
                    motion_count = 7 if len(header) == 9 else 13
                    motion = frame(timestamp).split(',')[:motion_count]
                    heels = ([wire_right, wire_left] if header[-2:] == ['fsr', 'fsr_left']
                             else [wire_left, wire_right])
                    timestamp += 50_000
                    return json.loads(parser.process_line(','.join(motion + list(map(str, heels)))))

                processor.command('heel_unloaded')
                for _ in range(42):
                    feed(100, 100)
                processor.command('heel_loaded')
                for _ in range(42):
                    feed(900, 900)
                with patch.object(processor, 'process', wraps=processor.process) as processing:
                    sample = feed(800, 200)
                    received = processing.call_args.args[0]
                    self.assertEqual((received['fsr_left'], received['fsr']), (200, 800))
                self.assertEqual((sample['fsr_left'], sample['fsr']), (200, 800))
                self.assertEqual(sample['analytics']['heel_share_left'], 12.5)
                self.assertEqual(sample['analytics']['heel_share_right'], 87.5)

    def test_every_sample_has_analytics_without_changing_raw_fields(self):
        processor = SessionProcessor()
        parser = SensorParser(processor=processor)
        parser.process_line(HEADER)
        for timestamp in range(100, 1100, 100):
            sample = json.loads(parser.process_line(frame(timestamp)))
            self.assertEqual(sample['analytics'], processor.snapshot())
            self.assertEqual(sample['thigh_accel'], [16384, 0, -16384])
            self.assertEqual(sample['fsr'], 500)

    def test_headers_replacement_gap_and_rollback_interrupt_processor(self):
        for event in ('header', 'invalid', 'replacement', 'gap', 'rollback'):
            processor = SessionProcessor()
            parser = SensorParser(processor=processor)
            parser.process_line(HEADER)
            parser.process_line(frame(1000))
            processor.command('heel_unloaded')
            self.assertEqual(processor.snapshot()['state'], 'heel_unloaded')
            if event == 'header':
                parser.process_line(HEADER)
            elif event == 'invalid':
                with self.assertRaises(ValueError):
                    parser.process_line('time_us,fsr')
            elif event == 'replacement':
                SensorParser(processor=processor)
            else:
                parser.process_line(frame(300000 if event == 'gap' else 100))
            self.assertEqual(processor.snapshot()['state'], 'needs_calibration')
            self.assertIsNotNone(processor.snapshot()['reason'])

    def test_malformed_duplicate_frames_do_not_advance_capture(self):
        processor = SessionProcessor()
        parser = SensorParser(processor=processor)
        parser.process_line(HEADER)
        processor.command('heel_unloaded')
        parser.process_line(frame())
        self.assertEqual(len(processor.capture), 1)
        self.assertIsNone(parser.process_line(frame()))
        self.assertIsNone(parser.process_line('invalid'))
        self.assertEqual(len(processor.capture), 1)


if __name__ == '__main__':
    unittest.main()
