"""Validate the wearable CSV stream before exposing readings to Flutter."""

import json
import re

from rehab_session import SessionProcessor

HEADER = (
    'time_us', 'thigh_ax', 'thigh_ay', 'thigh_az',
    'thigh_gx', 'thigh_gy', 'thigh_gz',
    'shin_ax', 'shin_ay', 'shin_az', 'shin_gx', 'shin_gy', 'shin_gz', 'fsr',
)
DUAL_HEADER = HEADER + ('fsr_left',)
THIGH_HEADER = HEADER[:7] + ('fsr_left', 'fsr_right')
NAMED_DUAL_HEADER = HEADER[:13] + ('fsr_left', 'fsr_right')
ACCEL_DIVISOR = 16384
GYRO_DIVISOR = 131
MAX_FRAME_BYTES = 512


class SensorParser:
    def __init__(self, scale_confirmed: bool = False, processor: SessionProcessor | None = None):
        self.processor = processor if processor is not None else SessionProcessor()
        if processor is not None:
            self.processor.interrupt('New sensor connection; repeat calibration.')
        self.scale_confirmed = scale_confirmed
        self._header_received = False
        self._header = HEADER
        self._last_timestamp = None

    def process_line(self, line: str) -> str | None:
        line = line.rstrip('\r\n')
        if len(line.encode('utf-8')) > MAX_FRAME_BYTES:
            return None
        fields = tuple(field.strip() for field in line.split(','))
        if fields in (HEADER, DUAL_HEADER, THIGH_HEADER, NAMED_DUAL_HEADER):
            if self._header_received:
                self.processor.interrupt('Repeated sensor header; repeat calibration.')
            self._header_received = True
            self._header = fields
            self._last_timestamp = None
            return None
        if (re.fullmatch(r'[+-]?[0-9]+', fields[0]) is None
                and any(field in NAMED_DUAL_HEADER + HEADER for field in fields)) or (
            len(fields) in (9, 14, 15) and all(field.isidentifier() for field in fields)
        ):
            self._header_received = False
            self.processor.interrupt('Unsupported sensor CSV header; check the device stream.')
            raise ValueError('Unsupported sensor CSV header')
        if not self._header_received:
            return None
        if len(fields) != len(self._header):
            return None
        if any(re.fullmatch(r'[+-]?[0-9]+', field) is None for field in fields):
            return None
        try:
            values = [int(field) for field in fields]
        except ValueError:
            return None
        thigh_only = self._header == THIGH_HEADER
        motion_end = 7 if thigh_only else 13
        named_heels = self._header in (THIGH_HEADER, NAMED_DUAL_HEADER)
        timestamp = values[0]
        fsr = values[motion_end + 1] if named_heels else values[motion_end]
        if not 0 <= timestamp <= 0xFFFFFFFF or any(not 0 <= value <= 4095 for value in values[motion_end:]):
            return None
        if any(not -32768 <= value <= 32767 for value in values[1:motion_end]):
            return None
        if timestamp == self._last_timestamp:
            return None
        restart = self._last_timestamp is not None and timestamp < self._last_timestamp
        self._last_timestamp = timestamp
        acceleration = ACCEL_DIVISOR if self.scale_confirmed else 1
        gyro = GYRO_DIVISOR if self.scale_confirmed else 1
        sample = {
            'type': 'sample', 'time_us': timestamp, 'restart': restart,
            'thigh_accel': [value / acceleration for value in values[1:4]],
            'thigh_gyro': [value / gyro for value in values[4:7]],
            'shin_accel': None if thigh_only else [value / acceleration for value in values[7:10]],
            'shin_gyro': None if thigh_only else [value / gyro for value in values[10:13]],
            'fsr': fsr, 'scaled': self.scale_confirmed,
        }
        # Supplied firmware emits six zeros when an IMU read fails.
        if named_heels and all(value == 0 for value in values[1:7]):
            sample['thigh_accel'] = sample['thigh_gyro'] = None
        if self._header == NAMED_DUAL_HEADER and all(value == 0 for value in values[7:13]):
            sample['shin_accel'] = sample['shin_gyro'] = None
        if named_heels:
            sample['fsr_left'] = values[motion_end]
        elif self._header == DUAL_HEADER:
            sample['fsr_left'] = values[14]
        if 'fsr_left' in sample:
            # This wearable's physical heel sides are opposite its CSV labels.
            sample['fsr'], sample['fsr_left'] = sample['fsr_left'], sample['fsr']
        sample['analytics'] = self.processor.process(sample)
        return json.dumps(sample, separators=(',', ':'))
