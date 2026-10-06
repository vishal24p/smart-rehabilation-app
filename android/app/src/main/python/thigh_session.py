"""Standing-relative thigh inclination; detector settings are not clinical targets."""

import math
from statistics import mean, pstdev

from rehab_session import (
    STANDING_S, STANDING_COUNT, MAX_GAP_S, GYRO_NOISE_DPS, ACCEL_NOISE_G,
    GRAVITY_MIN_G, GRAVITY_MAX_G, FILTER_TAU_S, GRAVITY_TIMEOUT_S,
    TRIAL_MIN_DEG, TRIAL_RETURN_DEG, HOLD_S, MIN_CYCLE_S,
    ACCEL_DIVISOR, GYRO_DIVISOR,
)

THIGH_ACTIONS = frozenset(('thigh_reference_begin', 'thigh_reference_finish',
                         'thigh_session_begin', 'thigh_session_end', 'thigh_cancel'))


def _unit(vector):
    magnitude = math.sqrt(sum(value*value for value in vector))
    return [value/magnitude for value in vector]


def _rotate_gravity(gravity, gyro, dt):
    # A stationary world vector rotates opposite the board's angular velocity.
    rotation = [-math.radians(value)*dt for value in gyro]
    angle = math.sqrt(sum(value*value for value in rotation))
    if angle == 0:
        return list(gravity)
    axis = [value/angle for value in rotation]
    cross = [axis[1]*gravity[2]-axis[2]*gravity[1],
             axis[2]*gravity[0]-axis[0]*gravity[2],
             axis[0]*gravity[1]-axis[1]*gravity[0]]
    dot = sum(a*g for a, g in zip(axis, gravity))
    return [g*math.cos(angle)+c*math.sin(angle)+a*dot*(1-math.cos(angle))
            for g, c, a in zip(gravity, cross, axis)]


class ThighProcessor:
    def __init__(self):
        self.state, self.exercise_id, self.reason = 'idle', None, None
        self.zero_progress = 0.0
        self.reference_peak = self.recorded_peak = self.latest_peak = None
        self.tilt = None
        self.repetitions = 0
        self.reference = None
        self.last_t = None
        self.capture = []
        self.gravity = self.zero_gravity = self.bias = None
        self.gravity_t = None
        self.recording = False
        self._clear_cycle()

    def _clear_cycle(self):
        self.departure = self.bend_since = self.return_since = None
        self.bend_confirmed = False
        self.cycle_peak = 0.0

    def snapshot(self):
        return {'state': self.state, 'exercise_id': self.exercise_id, 'reason': self.reason,
                'zero_progress': self.zero_progress, 'tilt_deg': self.tilt,
                'reference_peak_deg': self.reference_peak, 'recorded_peak_deg': self.recorded_peak,
                'latest_peak_deg': self.latest_peak,
                'difference_deg': None if self.latest_peak is None or self.reference_peak is None
                else self.latest_peak-self.reference_peak,
                'repetitions': self.repetitions}

    def _error(self, reason):
        self.reason = reason
        return self.snapshot()

    def command(self, action, config=None):
        if action in ('thigh_reference_begin', 'thigh_session_begin'):
            if self.state == 'active':
                return self._error('End the thigh session before starting another capture.')
            if not isinstance(config, dict) or config.get('exercise_id') not in ('squat', 'sit_to_stand'):
                return self._error('Choose Squat or Sit-to-stand.')
            reference = None
            if action == 'thigh_session_begin':
                reference = config.get('reference')
                if not self._valid_reference(reference, config['exercise_id']):
                    return self._error('Load a valid saved thigh reference for this exercise first.')
            self.exercise_id = config['exercise_id']
            self.reference = None if reference is None else dict(reference)
            self.reference_peak = None if reference is None else reference['reference_peak_deg']
            self.recorded_peak = self.latest_peak = self.tilt = None
            self.repetitions, self.zero_progress = 0, 0.0
            self.capture = []
            self.gravity = self.zero_gravity = self.bias = None
            self.last_t = self.gravity_t = None
            self.recording = action == 'thigh_reference_begin'
            self._clear_cycle()
            self.state = 'zeroing'
        elif action == 'thigh_reference_finish':
            if self.state != 'recording' or self.recorded_peak is None or self.tilt > TRIAL_RETURN_DEG:
                return self._error('Complete one bend of at least 30 degrees and return upright first.')
            self.state = 'reference_ready'
        elif action == 'thigh_session_end':
            if self.state != 'active':
                return self._error('Start a thigh session before ending it.')
            self.state = 'ended'
            self._clear_cycle()
        elif action == 'thigh_cancel':
            self.__init__()
        else:
            return self._error('Choose a supported thigh action.')
        self.reason = None
        return self.snapshot()

    @staticmethod
    def _valid_reference(reference, exercise_id):
        if (not isinstance(reference, dict) or reference.get('exercise_id') != exercise_id
                or reference.get('measurement_version') != 'thigh_tilt_v1'
                or reference.get('placement') != 'front_thigh'
                or not isinstance(reference.get('recorded_at'), str) or not reference['recorded_at']):
            return False
        values = [reference.get(key) for key in
                  ('reference_peak_deg', 'bend_threshold_deg', 'upright_band_deg')]
        if any(type(value) not in (int, float) or not math.isfinite(value) for value in values):
            return False
        peak, bend, upright = values
        return 0 < upright < bend <= peak <= 180

    def interrupt(self, reason):
        if self.state != 'idle':
            self.state, self.reason = 'interrupted', reason
        self.capture = []
        self.tilt = self.recorded_peak = None
        self.gravity = self.zero_gravity = self.bias = None
        self.last_t = self.gravity_t = None
        self.zero_progress = 0.0
        self._clear_cycle()
        return self.snapshot()

    def process(self, sample):
        if self.state not in ('zeroing', 'recording', 'active'):
            return self.snapshot()
        t = sample['time_us']
        if t == self.last_t:
            return self.snapshot()
        if self.last_t is not None and (t < self.last_t or (t-self.last_t)/1e6 > MAX_GAP_S):
            return self.interrupt('Thigh sample gap or timestamp reset; set session zero again.')
        dt = 0 if self.last_t is None else (t-self.last_t)/1e6
        self.last_t = t
        accel, gyro = sample.get('thigh_accel'), sample.get('thigh_gyro')
        if accel is None or gyro is None:
            return self.interrupt('Thigh IMU readings unavailable; reconnect and set session zero again.')
        if (len(accel) != 3 or len(gyro) != 3
                or any(type(value) not in (int, float) or not math.isfinite(value) for value in accel+gyro)):
            return self.interrupt('Invalid thigh IMU readings; set session zero again.')
        scaled = sample.get('scaled', False)
        accel = [value/(1 if scaled else ACCEL_DIVISOR) for value in accel]
        gyro = [value/(1 if scaled else GYRO_DIVISOR) for value in gyro]
        if (any(value <= -32768/ACCEL_DIVISOR or value >= 32767/ACCEL_DIVISOR for value in accel)
                or any(value <= -32768/GYRO_DIVISOR or value >= 32767/GYRO_DIVISOR for value in gyro)):
            return self.interrupt('Thigh IMU clipped; check the wearable and set session zero again.')
        magnitude = math.sqrt(sum(value*value for value in accel))
        gravity_valid = GRAVITY_MIN_G <= magnitude <= GRAVITY_MAX_G
        if self.state == 'zeroing':
            return self._zero(accel, gyro, gravity_valid, t)
        corrected = [value-bias for value, bias in zip(gyro, self.bias)]
        self.gravity = _rotate_gravity(self.gravity, corrected, dt)
        if gravity_valid:
            measured = _unit(accel)
            weight = 1-math.exp(-dt/FILTER_TAU_S)
            blended = [(1-weight)*g+weight*a for g, a in zip(self.gravity, measured)]
            if sum(value*value for value in blended) > 1e-12:
                self.gravity = _unit(blended)
            self.gravity_t = t
        elif (t-self.gravity_t)/1e6 > GRAVITY_TIMEOUT_S:
            return self.interrupt('Thigh gravity correction unavailable; set session zero again.')
        dot = sum(a*b for a, b in zip(self.gravity, self.zero_gravity))
        self.tilt = math.degrees(math.acos(max(-1.0, min(1.0, dot))))
        self._cycle(t)
        return self.snapshot()

    def _zero(self, accel, gyro, gravity_valid, t):
        if not gravity_valid:
            self.capture = []
            self.zero_progress = 0.0
            return self._error('Stand still while setting session zero.')
        self.capture.append((t, accel, gyro))
        if any(pstdev(row[field][axis] for row in self.capture) > limit
               for field, limit in ((1, ACCEL_NOISE_G), (2, GYRO_NOISE_DPS)) for axis in range(3)):
            self.capture = [(t, accel, gyro)]
            self.zero_progress = 0.0
            return self._error('Movement detected; stand still to restart session zero.')
        elapsed = (t-self.capture[0][0])/1e6
        self.zero_progress = min(1.0, elapsed/STANDING_S, len(self.capture)/STANDING_COUNT)
        if self.zero_progress < 1:
            return self.snapshot()
        self.bias = [mean(row[2][axis] for row in self.capture) for axis in range(3)]
        self.zero_gravity = _unit([mean(row[1][axis] for row in self.capture) for axis in range(3)])
        self.gravity, self.gravity_t, self.tilt = list(self.zero_gravity), t, 0.0
        self.capture = []
        self.state, self.reason = ('recording' if self.recording else 'active'), None
        return self.snapshot()

    def _cycle(self, t):
        if self.recording and self.recorded_peak is not None:
            return
        upright_band = TRIAL_RETURN_DEG if self.recording else self.reference['upright_band_deg']
        bend = TRIAL_MIN_DEG if self.recording else self.reference['bend_threshold_deg']
        if self.departure is None:
            if self.tilt > upright_band:
                self.departure = t
                self.cycle_peak = self.tilt
            return
        self.cycle_peak = max(self.cycle_peak, self.tilt)
        if self.tilt >= bend:
            if self.bend_since is None:
                self.bend_since = t
            elif (t-self.bend_since)/1e6 >= HOLD_S:
                self.bend_confirmed = True
        else:
            self.bend_since = None
        if self.tilt <= upright_band:
            if self.return_since is None:
                self.return_since = t
            elif (t-self.return_since)/1e6 >= HOLD_S:
                if self.bend_confirmed and (self.return_since-self.departure)/1e6 >= MIN_CYCLE_S:
                    if self.recording:
                        self.recorded_peak = self.cycle_peak
                    else:
                        self.latest_peak = self.cycle_peak
                        self.repetitions += 1
                    self.reason = None
                self._clear_cycle()
        else:
            self.return_since = None
