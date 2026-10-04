"""Standing-relative planar estimates. Thresholds are unvalidated bench settings."""

import math
from statistics import mean, median, pstdev

# Keep engineering settings together for bench tuning; these are not clinical targets.
STANDING_S, STANDING_COUNT = 3.0, 60
HEEL_S, HEEL_COUNT = 2.0, 30
MAX_GAP_S = 0.250
GYRO_NOISE_DPS, ACCEL_NOISE_G = 3.0, 0.03
GRAVITY_MIN_G, GRAVITY_MAX_G, PLANE_MIN_G = 0.85, 1.15, 0.2
FILTER_TAU_S, GRAVITY_TIMEOUT_S = 0.5, 1.0
OFF_AXIS_FRACTION, OFF_AXIS_TIMEOUT_S = 0.20, 0.5
TRIAL_MIN_DEG, TRIAL_RETURN_DEG, TRIAL_DIFFERENCE = 30.0, 10.0, 0.20
BEND_FRACTION, UPRIGHT_FRACTION = 0.60, 0.15
HOLD_S, MIN_CYCLE_S, CONTACT_DWELL_S = 0.250, 1.0, 0.100
ACCEL_DIVISOR, GYRO_DIVISOR = 16384, 131


def _wrap(angle: float) -> float:
    return (angle + 180) % 360 - 180


def _gravity_tilt(accel: list, axis: dict) -> float:
    # Cyclic bases (Y,Z), (Z,X), (X,Y) have u cross v = +hinge.
    # Gravity rotates opposite the board; negate its oriented angle.
    i = axis['index']
    u, v = (i + 1) % 3, (i + 2) % 3
    return -math.degrees(math.atan2(axis['sign'] * accel[v], accel[u]))


class SessionProcessor:
    def __init__(self):
        self.state, self.reason, self.progress = 'setup', None, 0.0
        self.config = None
        self.summary = None
        self.last_t = None
        self.heel_contact = None
        self.heel_saturated = False
        self.heel_baseline = None
        self.heel_thresholds = None
        self.contact_candidate = None
        self.contact_since = None
        self.capture = []
        self.angle = None
        self.segments = None
        self.motion_ready = False
        self.polarity = None
        self.trials = []
        self.trial_peak, self.trial_return = 0.0, None
        self.trial_armed, self.trial_upright_since = False, None
        self.motion_energy, self.off_energy = 0.0, 0.0
        self.bend_threshold, self.upright_band = None, None
        self.session_start = None
        self.cycle_times = []
        self.angle_min, self.angle_max = None, None
        self._clear_cycle()

    def _clear_cycle(self):
        self.armed = False
        self.departure = None
        self.bend_since, self.return_since = None, None
        self.bend_confirmed = False

    def _error(self, reason: str) -> dict:
        self.reason = reason
        return self.snapshot()

    def command(self, action: str, config: dict | None = None) -> dict:
        if action == 'configure':
            if self.state == 'active':
                return self._error('End the active session before changing setup.')
            if not isinstance(config, dict) or any(
                type(config.get(key)) is not bool
                for key in ('ranges_confirmed', 'mounting_confirmed')
            ):
                return self._error('Confirm IMU ranges and mounting with boolean values.')
            for key in ('thigh_axis', 'shin_axis'):
                axis = config.get(key)
                if (not isinstance(axis, dict) or type(axis.get('index')) is not int
                        or axis['index'] not in (0, 1, 2)
                        or type(axis.get('sign')) is not int or axis['sign'] not in (-1, 1)):
                    return self._error('Select each board hinge axis and its signed direction.')
            self.config = {**config, 'thigh_axis': dict(config['thigh_axis']),
                           'shin_axis': dict(config['shin_axis'])}
            self._invalidate_motion()
            self.state = 'setup'
        elif action == 'retry':
            if self.state == 'active':
                return self._error('End the active session before retrying calibration.')
            self._invalidate_motion()
            self.heel_baseline, self.heel_thresholds, self.heel_contact = None, None, None
            self.state = 'setup'
        elif action in ('heel_unloaded', 'heel_loaded', 'standing'):
            if self.state == 'active':
                return self._error('End the active session before calibrating.')
            if action == 'heel_loaded' and self.heel_baseline is None:
                return self._error('Capture the unloaded heel baseline first.')
            if action == 'standing' and not self._setup_confirmed():
                return self._error('Confirm IMU ranges and both signed hinge axes first.')
            self.capture = []
            self.progress = 0.0
            if action == 'standing':
                self._invalidate_motion()
            else:
                self.heel_thresholds, self.heel_contact = None, None
                self.contact_candidate, self.contact_since = None, None
                if action == 'heel_unloaded':
                    self.heel_baseline = None
            self.state = action
        elif action == 'movement':
            if self.state != 'movement_ready':
                return self._error('Capture a stable standing reference first.')
            self.trials, self.polarity = [], None
            self.trial_peak, self.trial_return = 0.0, None
            self.trial_armed, self.trial_upright_since = False, None
            self.motion_energy, self.off_energy = 0.0, 0.0
            self.state = 'movement'
        elif action == 'finish_movement':
            if self.state != 'movement':
                return self._error('Begin the two instructed movement trials first.')
            if (len(self.trials) != 2 or self.angle is None
                    or abs(self.angle) > TRIAL_RETURN_DEG or self.trial_peak):
                return self._error('Complete two bends of at least 30 degrees and return upright.')
            if abs(self.trials[0] - self.trials[1]) > TRIAL_DIFFERENCE * mean(self.trials):
                return self._error('Repeat calibration with two similar bend excursions.')
            if self.motion_energy and self.off_energy / self.motion_energy > OFF_AXIS_FRACTION:
                return self._error('Check signed hinge alignment; excessive off-axis movement.')
            smaller = min(self.trials)
            self.bend_threshold = BEND_FRACTION * smaller
            self.upright_band = min(10.0, max(5.0, UPRIGHT_FRACTION * smaller))
            self.motion_ready, self.state, self.progress = True, 'ready', 1.0
        elif action == 'start':
            if not self.motion_ready or self.state not in ('ready', 'ended') or self.last_t is None:
                return self._error('Finish valid movement calibration before starting a session.')
            self.summary = None
            self.cycle_times = []
            self.angle_min = self.angle_max = self.angle
            self.session_start = self.last_t
            self._clear_cycle()
            self.armed = self.angle is not None and abs(self.angle) <= self.upright_band
            self.state = 'active'
        elif action == 'end':
            if self.state != 'active':
                return self._error('Start a session before ending it.')
            self._freeze(False)
            self.state = 'ended'
            self._clear_cycle()
        else:
            return self._error('Choose a supported calibration or session action.')
        self.reason = None
        return self.snapshot()

    def _setup_confirmed(self) -> bool:
        return bool(self.config and self.config['ranges_confirmed']
                    and self.config['mounting_confirmed'])

    def _invalidate_motion(self):
        self.segments, self.angle, self.polarity = None, None, None
        self.motion_ready = False
        self.capture, self.trials = [], []
        self.trial_armed, self.trial_upright_since = False, None
        self.progress = 0.0
        self._clear_cycle()

    def interrupt(self, reason: str) -> dict:
        active = self.state == 'active'
        if active:
            self._freeze(True)
        self._invalidate_motion()
        self.heel_baseline, self.heel_thresholds, self.heel_contact = None, None, None
        self.contact_candidate, self.contact_since = None, None
        self.last_t = None
        self.state = 'interrupted' if active else 'needs_calibration'
        self.reason = reason
        return self.snapshot()

    def _motion_failure(self, reason: str) -> dict:
        # IMU quality does not invalidate the independent heel classifier.
        active = self.state == 'active'
        if active:
            self._freeze(True)
        self._invalidate_motion()
        self.state = 'interrupted' if active else 'needs_calibration'
        self.reason = reason
        return self.snapshot()

    def _freeze(self, interrupted: bool):
        self.summary = {'cycles': len(self.cycle_times), 'rom_deg': self._rom(),
                        'active_s': max(0.0, (self.last_t - self.session_start) / 1e6),
                        'cycle_times_s': list(self.cycle_times), 'interrupted': interrupted}

    def _rom(self):
        return None if self.angle_min is None else self.angle_max - self.angle_min

    def snapshot(self) -> dict:
        showing_session = self.motion_ready and self.state in ('active', 'ended')
        return {'state': self.state, 'reason': self.reason, 'progress': self.progress,
                'angle_deg': self.angle, 'rom_deg': self._rom() if showing_session else None,
                'cycles': len(self.cycle_times) if showing_session else None,
                'last_cycle_s': self.cycle_times[-1] if showing_session and self.cycle_times else None,
                'heel_contact': self.heel_contact, 'heel_saturated': self.heel_saturated,
                'summary': None if self.summary is None else {
                    **self.summary, 'cycle_times_s': list(self.summary['cycle_times_s'])}}

    def process(self, sample: dict) -> dict:
        t = sample['time_us']
        if t == self.last_t:
            return self.snapshot()
        if self.last_t is not None and (t < self.last_t or (t-self.last_t)/1e6 > MAX_GAP_S):
            return self.interrupt('Device timestamp reset or sample gap; repeat calibration.')
        dt = 0.0 if self.last_t is None else (t - self.last_t)/1e6
        self.last_t = t
        self.heel_saturated = sample['fsr'] in (0, 4095)
        self._contact(sample['fsr'], t)
        if self.state in ('heel_unloaded', 'heel_loaded'):
            self._capture_heel(sample['fsr'], t)
        if not self._setup_confirmed():
            return self.snapshot()
        scaled = sample.get('scaled', False)
        boards = []
        for name in ('thigh', 'shin'):
            accel = [x / (1 if scaled else ACCEL_DIVISOR) for x in sample[name + '_accel']]
            gyro = [x / (1 if scaled else GYRO_DIVISOR) for x in sample[name + '_gyro']]
            clipped = any(x <= -32768 / ACCEL_DIVISOR or x >= 32767 / ACCEL_DIVISOR for x in accel)
            clipped |= any(x <= -32768 / GYRO_DIVISOR or x >= 32767 / GYRO_DIVISOR for x in gyro)
            if clipped and self.state in ('standing', 'movement_ready', 'movement', 'ready', 'active', 'ended'):
                return self._motion_failure('IMU clipping; check ranges and repeat calibration.')
            boards.append((accel, gyro))
        if self.state == 'standing':
            self._capture_standing(boards, t)
        elif self.segments is not None:
            reason = self._estimate(boards, t, dt)
            if reason:
                return self._motion_failure(reason)
            if self.state == 'movement':
                self._movement(t)
            elif self.state == 'active':
                self.angle_min = self.angle if self.angle_min is None else min(self.angle_min, self.angle)
                self.angle_max = self.angle if self.angle_max is None else max(self.angle_max, self.angle)
                self._cycle(t)
        return self.snapshot()

    def _capture_heel(self, fsr: int, t: int):
        self.capture.append((t, fsr))
        elapsed = (t - self.capture[0][0])/1e6
        self.progress = min(1.0, elapsed/HEEL_S, len(self.capture)/HEEL_COUNT)
        if elapsed < HEEL_S or len(self.capture) < HEEL_COUNT:
            return
        values = [value for _, value in self.capture]
        center = median(values)
        mad = median(abs(value-center) for value in values)
        self.capture = []
        if self.state == 'heel_unloaded':
            self.heel_baseline = (center, mad)
            # Wait for explicit loaded command; do not capture the transition.
            self.state, self.progress = 'setup', 0.0
            self.reason = 'Press the heel sensor, then start the loaded capture.'
        else:
            unloaded, unloaded_mad = self.heel_baseline
            separation = abs(center-unloaded)
            noise = max(mad, unloaded_mad)
            self.state = 'setup'
            if separation < max(50, 6*noise) or noise > max(12, 0.08*separation):
                self.heel_thresholds, self.heel_contact = None, None
                self.contact_candidate, self.contact_since = None, None
                self.reason = 'Heel readings overlap; repeat heel capture or continue to standing.'
                return
            delta = center-unloaded
            self.heel_thresholds = (unloaded+0.65*delta, unloaded+0.35*delta, 1 if delta > 0 else -1)
            self.heel_contact = None
            self.contact_candidate, self.contact_since = None, None
            self.reason = None

    def _contact(self, fsr: int, t: int):
        if self.heel_thresholds is None:
            return
        on, off, direction = self.heel_thresholds
        candidate = self.heel_contact
        if (fsr-on)*direction >= 0:
            candidate = True
        elif (fsr-off)*direction <= 0:
            candidate = False
        if candidate is None or candidate == self.heel_contact:
            self.contact_candidate, self.contact_since = None, None
        elif candidate != self.contact_candidate:
            self.contact_candidate, self.contact_since = candidate, t
        elif (t-self.contact_since)/1e6 >= CONTACT_DWELL_S:
            self.heel_contact = candidate
            self.contact_candidate, self.contact_since = None, None

    def _capture_standing(self, boards: list, t: int):
        valid = all(GRAVITY_MIN_G <= math.sqrt(sum(x*x for x in a)) <= GRAVITY_MAX_G
                    and math.hypot(*(a[i] for i in range(3) if i != self.config[name+'_axis']['index'])) >= PLANE_MIN_G
                    for name, (a, _) in zip(('thigh', 'shin'), boards))
        if not valid:
            self.capture = []
            self.progress = 0.0
            self.reason = 'Keep both boards still with gravity visible in the hinge plane.'
            return
        self.capture.append((t, boards))
        # Reject motion as soon as it spoils this consecutive stable window.
        for board in range(2):
            for field, limit in ((0, ACCEL_NOISE_G), (1, GYRO_NOISE_DPS)):
                if any(pstdev(row[1][board][field][i] for row in self.capture) > limit for i in range(3)):
                    self.capture = [(t, boards)]
                    self.progress = 0.0
                    self.reason = 'Movement detected; hold the instructed standing pose still.'
                    return
        elapsed = (t-self.capture[0][0])/1e6
        self.progress = min(1.0, elapsed/STANDING_S, len(self.capture)/STANDING_COUNT)
        if elapsed < STANDING_S or len(self.capture) < STANDING_COUNT:
            return
        self.segments = []
        for board, name in enumerate(('thigh', 'shin')):
            accel = [mean(row[1][board][0][i] for row in self.capture) for i in range(3)]
            bias = [mean(row[1][board][1][i] for row in self.capture) for i in range(3)]
            reference = _gravity_tilt(accel, self.config[name+'_axis'])
            self.segments.append({'bias': bias, 'reference': reference, 'tilt': reference,
                                  'gravity_t': t, 'off_t': None})
        self.angle = 0.0
        self.state, self.reason, self.progress = 'movement_ready', None, 1.0
        self.capture = []

    def _estimate(self, boards: list, t: int, dt: float) -> str | None:
        total_energy, off_energy = 0.0, 0.0
        for name, segment, (accel, gyro) in zip(('thigh', 'shin'), self.segments, boards):
            axis = self.config[name+'_axis']
            i = axis['index']
            corrected = [gyro[j]-segment['bias'][j] for j in range(3)]
            total = sum(x*x for x in corrected)
            off = total-corrected[i]**2
            total_energy += total*dt
            off_energy += off*dt
            if total > GYRO_NOISE_DPS**2 and off/total > OFF_AXIS_FRACTION:
                if segment['off_t'] is None:
                    segment['off_t'] = t
                elif (t-segment['off_t'])/1e6 > OFF_AXIS_TIMEOUT_S:
                    return 'Excessive off-axis movement; check mounting and repeat calibration.'
            else:
                segment['off_t'] = None
            segment['tilt'] += axis['sign']*corrected[i]*dt
            magnitude = math.sqrt(sum(x*x for x in accel))
            projection = math.sqrt(sum(accel[j]**2 for j in range(3) if j != i))
            if GRAVITY_MIN_G <= magnitude <= GRAVITY_MAX_G and projection >= PLANE_MIN_G:
                innovation = _wrap(_gravity_tilt(accel, axis)-segment['tilt'])
                segment['tilt'] += (1-math.exp(-dt/FILTER_TAU_S))*innovation
                segment['gravity_t'] = t
            elif (t-segment['gravity_t'])/1e6 > GRAVITY_TIMEOUT_S:
                return 'Gravity correction unavailable; check placement and repeat calibration.'
        self.motion_energy += total_energy
        self.off_energy += off_energy
        relative = _wrap((self.segments[0]['tilt']-self.segments[0]['reference'])
                         -(self.segments[1]['tilt']-self.segments[1]['reference']))
        if (self.state == 'movement' and self.trial_armed
                and self.polarity is None and abs(relative) > TRIAL_RETURN_DEG):
            self.polarity = 1 if relative > 0 else -1
        self.angle = relative * (self.polarity or 1)
        if (self.state == 'movement' and self.polarity is not None
                and self.angle < -TRIAL_RETURN_DEG):
            return 'Bend direction inconsistent; check signed axes and repeat calibration.'
        return None

    def _movement(self, t: int):
        if not self.trial_armed:
            if abs(self.angle) <= TRIAL_RETURN_DEG:
                if self.trial_upright_since is None:
                    self.trial_upright_since = t
                elif (t-self.trial_upright_since)/1e6 >= HOLD_S:
                    self.trial_armed = True
            else:
                self.trial_upright_since = None
            return
        if self.angle > TRIAL_RETURN_DEG:
            self.trial_peak = max(self.trial_peak, self.angle)
            self.trial_return = None
        elif abs(self.angle) <= TRIAL_RETURN_DEG and self.trial_peak:
            if self.trial_return is None:
                self.trial_return = t
            elif (t-self.trial_return)/1e6 >= HOLD_S:
                if self.trial_peak >= TRIAL_MIN_DEG:
                    self.trials.append(self.trial_peak)
                self.trial_peak, self.trial_return = 0.0, None
        self.progress = min(1.0, len(self.trials)/2)

    def _cycle(self, t: int):
        upright = abs(self.angle) <= self.upright_band
        if not self.armed:
            if upright:
                self.armed = True
            return
        if self.departure is None:
            if self.angle > self.upright_band:
                self.departure = t
            return
        if self.angle >= self.bend_threshold:
            if self.bend_since is None:
                self.bend_since = t
            elif (t-self.bend_since)/1e6 >= HOLD_S:
                self.bend_confirmed = True
        else:
            self.bend_since = None
        if upright:
            if self.return_since is None:
                self.return_since = t
            elif (t-self.return_since)/1e6 >= HOLD_S:
                duration = (self.return_since-self.departure)/1e6
                if self.bend_confirmed and duration >= MIN_CYCLE_S:
                    self.cycle_times.append(duration)
                self._clear_cycle()
                self.armed = True
        else:
            self.return_since = None
