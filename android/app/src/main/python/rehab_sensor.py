"""Validate the wearable CSV stream before exposing readings to Flutter."""

import json
import re

HEADER = (
    'time_us', 'thigh_ax', 'thigh_ay', 'thigh_az',
    'thigh_gx', 'thigh_gy', 'thigh_gz',
    'shin_ax', 'shin_ay', 'shin_az', 'shin_gx', 'shin_gy', 'shin_gz', 'fsr',
)
ACCEL_DIVISOR = 16384
GYRO_DIVISOR = 131
MAX_FRAME_BYTES = 512


class SensorParser:
    def __init__(self, scale_confirmed: bool = False):
        self.scale_confirmed = scale_confirmed
        self._header_received = False
        self._last_timestamp = None

    def process_line(self, line: str) -> str | None:
        line = line.rstrip('\r\n')
        if len(line.encode('utf-8')) > MAX_FRAME_BYTES:
            return None
        fields = tuple(field.strip() for field in line.split(','))
        if fields == HEADER:
            self._header_received = True
            self._last_timestamp = None
            return None
        if (re.fullmatch(r'[+-]?[0-9]+', fields[0]) is None
                and any(field in HEADER for field in fields)) or (
            len(fields) == len(HEADER) and all(field.isidentifier() for field in fields)
        ):
            self._header_received = False
            raise ValueError('Unsupported sensor CSV header')
        if not self._header_received:
            return None
        if len(fields) != len(HEADER):
            return None
        if any(re.fullmatch(r'[+-]?[0-9]+', field) is None for field in fields):
            return None
        try:
            values = [int(field) for field in fields]
        except ValueError:
            return None
        timestamp, fsr = values[0], values[-1]
        if not 0 <= timestamp <= 0xFFFFFFFF or not 0 <= fsr <= 4095:
            return None
        if any(not -32768 <= value <= 32767 for value in values[1:-1]):
            return None
        if timestamp == self._last_timestamp:
            return None
        restart = self._last_timestamp is not None and timestamp < self._last_timestamp
        self._last_timestamp = timestamp
        acceleration = ACCEL_DIVISOR if self.scale_confirmed else 1
        gyro = GYRO_DIVISOR if self.scale_confirmed else 1
        return json.dumps({
            'type': 'sample', 'time_us': timestamp, 'restart': restart,
            'thigh_accel': [value / acceleration for value in values[1:4]],
            'thigh_gyro': [value / gyro for value in values[4:7]],
            'shin_accel': [value / acceleration for value in values[7:10]],
            'shin_gyro': [value / gyro for value in values[10:13]],
            'fsr': fsr, 'scaled': self.scale_confirmed,
        }, separators=(',', ':'))
