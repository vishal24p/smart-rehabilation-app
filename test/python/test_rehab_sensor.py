import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'android/app/src/main/python'))
from rehab_sensor import SensorParser
from rehab_session import SessionProcessor

HEADER = 'time_us,thigh_ax,thigh_ay,thigh_az,thigh_gx,thigh_gy,thigh_gz,shin_ax,shin_ay,shin_az,shin_gx,shin_gy,shin_gz,fsr'


def frame(timestamp=100, fsr=500, acceleration=16384):
    return ','.join(map(str, [timestamp, acceleration, 0, -16384, 131, 0, -131,
                             0, 16384, 0, 0, 131, 0, fsr]))


class SensorParserTest(unittest.TestCase):
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
