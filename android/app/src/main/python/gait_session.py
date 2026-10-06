"""Rule-based forefoot pressure timing; events are not verified heel strike or toe-off."""

from copy import deepcopy
from datetime import datetime, timezone
import math
import re
from statistics import mean, median, pstdev

from rehab_session import (
    ACCEL_DIVISOR, GYRO_DIVISOR, MAX_GAP_S, FILTER_TAU_S,
    GRAVITY_MIN_G, GRAVITY_MAX_G, PLANE_MIN_G, GYRO_NOISE_DPS,
    ACCEL_NOISE_G, _gravity_tilt, _wrap,
)

GAIT_ACTIONS = frozenset(('gait_configure', 'gait_forefoot_unloaded', 'gait_forefoot_loaded',
                         'gait_standing', 'gait_reference_begin', 'gait_reference_finish',
                         'gait_session_begin', 'gait_session_end', 'gait_cancel'))
COMPARED_METRICS = ('cadence_spm', 'right_step_time_s', 'left_step_time_s',
                    'right_stride_time_s', 'left_stride_time_s')
MIN_STRIDES = 10
CONTACT_DWELL_S = .060
RUNNING = ('recording', 'active')
CALIBRATING = ('forefoot_unloaded', 'forefoot_loaded', 'standing')
METRIC_KEYS = ('duration_s', 'distance_m', 'right_steps', 'left_steps',
               'right_strides', 'left_strides', *COMPARED_METRICS,
               'timing_asymmetry_pct', 'right_forefoot_loaded_s', 'left_forefoot_loaded_s',
               'right_forefoot_unloaded_s', 'left_forefoot_unloaded_s',
               'right_leg_excursion_deg', 'speed_mps',
               'average_step_length_m', 'average_stride_length_m')


def _positive(value):
    return type(value) in (int, float) and math.isfinite(value) and value > 0


def valid_reference(reference):
    if not isinstance(reference, dict) or set(reference) != {
        'measurement_version', 'placement', 'recorded_at',
        'right_strides', 'left_strides', 'metrics',
    }:
        return False
    if (reference['measurement_version'] != 'gait_forefoot_timing_v1'
            or reference['placement'] != 'right_thigh_shin_bilateral_forefeet'
            or any(type(reference[key]) is not int or reference[key] < MIN_STRIDES
                   for key in ('right_strides', 'left_strides'))):
        return False
    metrics = reference['metrics']
    if (not isinstance(metrics, dict) or set(metrics) != set(COMPARED_METRICS)
            or any(not _positive(value) for value in metrics.values())):
        return False
    date = reference['recorded_at']
    if not isinstance(date, str) or re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z', date) is None:
        return False
    try:
        parsed = datetime.fromisoformat(date[:-1] + '+00:00')
        return parsed.tzinfo is not None and parsed.utcoffset().total_seconds() == 0
    except ValueError:
        return False


class GaitProcessor:
    def __init__(self):
        self.state, self.reason, self.progress = 'setup', None, 0.0
        self.config = None
        self.last_t = self.latest = None
        self.capture = []
        self.baselines = self.thresholds = self.segments = None
        self.reference = self.reference_preview = self.summary = None
        self.comparison, self.deviations = None, []
        self.distance = self.start_t = None
        self.tolerance = 20.0
        self._reset_trial()

    def _reset_trial(self):
        self.steps = {'right': 0, 'left': 0}
        self.step_times = {'right': [], 'left': []}
        self.stride_times = {'right': [], 'left': []}
        self.forefoot_times = {side: {True: [], False: []} for side in self.steps}
        self.contacts = {side: None for side in self.steps}
        self.candidates = {side: None for side in self.steps}
        self.candidate_t = {side: None for side in self.steps}
        self.contact_t = {side: None for side in self.steps}
        self.armed = {side: False for side in self.steps}
        self.last_event = None
        self.side_event = {side: None for side in self.steps}
        self.angle_min = self.angle_max = None

    def _error(self, reason):
        self.reason = reason
        return self.snapshot()

    def command(self, action, config=None):
        if action not in GAIT_ACTIONS:
            return self._error('Choose a supported gait action.')
        if action == 'gait_cancel':
            if self.state in RUNNING:
                return self.interrupt('Gait trial cancelled; repeat calibration.')
            self.__init__()
            return self.snapshot()
        if self.state in RUNNING and action not in ('gait_reference_finish', 'gait_session_end'):
            return self._error('Stop the current walk before changing gait setup.')
        if action == 'gait_configure':
            required = ('ranges_confirmed', 'mounting_confirmed', 'forefoot_mapping_confirmed')
            if not isinstance(config, dict) or set(config) != set(required) | {'thigh_axis', 'shin_axis'}:
                return self._error('Confirm ranges, mounting, forefoot sides and signed axes.')
            if any(type(config[key]) is not bool for key in required):
                return self._error('Gait confirmations must be boolean values.')
            for key in ('thigh_axis', 'shin_axis'):
                axis = config[key]
                if (not isinstance(axis, dict) or set(axis) != {'index', 'sign'}
                        or type(axis['index']) is not int or axis['index'] not in (0, 1, 2)
                        or type(axis['sign']) is not int or axis['sign'] not in (-1, 1)):
                    return self._error('Select both signed board axes.')
            self.config = deepcopy(config)
            self.baselines = self.thresholds = self.segments = None
            self.state, self.progress = 'setup', 0.0
        elif action in ('gait_forefoot_unloaded', 'gait_forefoot_loaded', 'gait_standing'):
            if not self.config or not all(self.config[key] for key in
                                         ('ranges_confirmed', 'mounting_confirmed', 'forefoot_mapping_confirmed')):
                return self._error('Confirm gait sensor setup before calibration.')
            if action == 'gait_forefoot_loaded' and self.baselines is None:
                return self._error('Capture both unloaded forefeet first.')
            if action == 'gait_standing' and self.thresholds is None:
                return self._error('Capture valid unloaded and loaded forefeet first.')
            self.capture, self.progress = [], 0.0
            self.state = action.removeprefix('gait_')
            self.segments = None
            if self.state != 'standing':
                self.thresholds = None
                if self.state == 'forefoot_unloaded':
                    self.baselines = None
        elif action in ('gait_reference_begin', 'gait_session_begin'):
            expected = {'distance_m', 'tolerance_pct'}
            if action == 'gait_session_begin':
                expected.add('reference')
            if (not isinstance(config, dict) or set(config) != expected
                    or not _positive(config['distance_m']) or not _positive(config['tolerance_pct'])
                    or config['tolerance_pct'] > 100):
                return self._error('Enter positive distance and tolerance greater than 0 and at most 100%.')
            if action == 'gait_session_begin' and not valid_reference(config['reference']):
                return self._error('Record a forefoot baseline with ten strides per foot; heel baselines cannot be compared.')
            if self.state not in ('ready', 'reference_ready', 'ended') or self.segments is None or self.last_t is None:
                return self._error('Finish forefoot and standing calibration before starting a walk.')
            self.distance, self.tolerance = config['distance_m'], config['tolerance_pct']
            self.reference = deepcopy(config.get('reference'))
            self.reference_preview = self.summary = self.comparison = None
            self.deviations = []
            self.start_t = self.last_t
            self._reset_trial()
            self.state = 'recording' if action == 'gait_reference_begin' else 'active'
        elif action in ('gait_reference_finish', 'gait_session_end'):
            required_state = 'recording' if action == 'gait_reference_finish' else 'active'
            if self.state != required_state:
                return self._error('Start the matching gait walk before stopping it.')
            self._freeze(False)
            if required_state == 'recording' and self._usable(self.summary['metrics']):
                metrics = self.summary['metrics']
                self.reference_preview = {
                    'measurement_version': 'gait_forefoot_timing_v1',
                    'placement': 'right_thigh_shin_bilateral_forefeet',
                    'recorded_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
                    'right_strides': metrics['right_strides'], 'left_strides': metrics['left_strides'],
                    'metrics': {key: metrics[key] for key in COMPARED_METRICS},
                }
                self.state = 'reference_ready'
            else:
                self.state = 'ended'
            self.reason = ('Insufficient usable data; need ten complete strides per foot and finite metrics.'
                           if self.comparison == 'insufficient_data' else None)
            return self.snapshot()
        self.reason = None
        return self.snapshot()

    def interrupt(self, reason):
        if self.state in RUNNING:
            self._freeze(True)
        if self.state != 'setup' or self.config is not None:
            self.state, self.reason = 'interrupted', reason
        self.segments = self.baselines = self.thresholds = None
        self.reference_preview = None
        self.capture, self.progress = [], 0.0
        self.last_t = self.latest = None
        return self.snapshot()

    @staticmethod
    def _usable(metrics):
        return (metrics['right_strides'] >= MIN_STRIDES and metrics['left_strides'] >= MIN_STRIDES
                and all(_positive(metrics[key]) for key in COMPARED_METRICS))

    def _metrics(self):
        if self.summary is not None and self.state not in RUNNING:
            return deepcopy(self.summary['metrics'])
        result = dict.fromkeys(METRIC_KEYS)
        duration = max(0, (self.last_t - self.start_t)/1e6) if self.last_t is not None and self.start_t is not None else 0.0
        result.update(duration_s=duration, distance_m=self.distance)
        for side in self.steps:
            result[side+'_steps'] = self.steps[side]
            result[side+'_strides'] = len(self.stride_times[side])
            for name, values in (('step_time_s', self.step_times[side]),
                                 ('stride_time_s', self.stride_times[side]),
                                 ('forefoot_loaded_s', self.forefoot_times[side][True]),
                                 ('forefoot_unloaded_s', self.forefoot_times[side][False])):
                result[side+'_'+name] = mean(values) if values else None
        intervals = self.step_times['right'] + self.step_times['left']
        if intervals:
            result['cadence_spm'] = 60/mean(intervals)
        right, left = result['right_step_time_s'], result['left_step_time_s']
        if right is not None and left is not None:
            result['timing_asymmetry_pct'] = 100*abs(right-left)/mean((right, left))
        if self.angle_min is not None:
            result['right_leg_excursion_deg'] = self.angle_max-self.angle_min
        if self.distance is not None and duration > 0:
            result['speed_mps'] = self.distance/duration
        steps = sum(self.steps.values())
        if self.distance is not None and steps:
            result['average_step_length_m'] = self.distance/steps
            result['average_stride_length_m'] = 2*result['average_step_length_m']
        for key, value in result.items():
            if isinstance(value, float) and not math.isfinite(value):
                result[key] = None
        return result

    def _freeze(self, interrupted):
        metrics = self._metrics()
        self.comparison, self.deviations = None, []
        if interrupted or not self._usable(metrics):
            self.comparison = 'insufficient_data'
        elif self.reference is not None:
            for key in COMPARED_METRICS:
                baseline = self.reference['metrics'][key]
                deviation = 100*(abs(metrics[key]-baseline)/baseline)
                if not math.isfinite(deviation):
                    self.comparison, self.deviations = 'insufficient_data', []
                    break
                if deviation > self.tolerance and not math.isclose(deviation, self.tolerance, rel_tol=1e-12, abs_tol=1e-12):
                    self.deviations.append({'metric': key, 'deviation_pct': deviation})
            if self.comparison != 'insufficient_data':
                self.comparison = 'outside_reference' if self.deviations else 'within_reference'
        self.summary = {'metrics': metrics, 'comparison': self.comparison,
                        'deviations': deepcopy(self.deviations), 'interrupted': interrupted}

    def snapshot(self):
        return {'state': self.state, 'reason': self.reason, 'progress': self.progress,
                'metrics': self._metrics(), 'comparison': self.comparison,
                'deviations': deepcopy(self.deviations),
                'reference_preview': deepcopy(self.reference_preview), 'summary': deepcopy(self.summary)}

    def _channels(self, sample):
        forefeet = {}
        for side, key in (('right', 'fsr'), ('left', 'fsr_left')):
            value = sample.get(key)
            if type(value) is not int or not 0 <= value <= 4095:
                return None
            unloaded = None if self.baselines is None else self.baselines[side][0]
            if self.state != 'forefoot_unloaded' and value in (0, 4095) and value != unloaded:
                # Unloaded ADC endpoint is allowed; loaded saturation loses information.
                return None
            forefeet[side] = value
        boards = []
        for name in ('thigh', 'shin'):
            vectors = [sample.get(name+'_accel'), sample.get(name+'_gyro')]
            if any(not isinstance(vector, (list, tuple)) or len(vector) != 3 or
                   any(type(value) not in (int, float) or not math.isfinite(value) for value in vector)
                   for vector in vectors):
                return None
            divisors = (1, 1) if sample.get('scaled', False) else (ACCEL_DIVISOR, GYRO_DIVISOR)
            accel, gyro = [[value/divisor for value in vector] for vector, divisor in zip(vectors, divisors)]
            if (any(value <= -2 or value >= 32767/ACCEL_DIVISOR for value in accel)
                    or any(value <= -32768/GYRO_DIVISOR or value >= 32767/GYRO_DIVISOR for value in gyro)):
                return None
            boards.append((accel, gyro))
        return forefeet, boards

    def process(self, sample):
        if self.state not in CALIBRATING + RUNNING + ('ready', 'reference_ready', 'ended'):
            return self.snapshot()
        t = sample.get('time_us')
        if type(t) is not int or not 0 <= t <= 0xFFFFFFFF or sample.get('restart', False):
            return self.interrupt('Invalid gait timestamp or device restart; repeat calibration.')
        if t == self.last_t:
            return self.snapshot()
        if self.last_t is not None and (t < self.last_t or (t-self.last_t)/1e6 > MAX_GAP_S):
            return self.interrupt('Gait sample gap or timestamp reset; repeat calibration.')
        channels = self._channels(sample)
        if channels is None:
            return self.interrupt('Gait channels missing, invalid, clipped or saturated; repeat calibration.')
        forefeet, boards = channels
        dt = 0 if self.last_t is None else (t-self.last_t)/1e6
        self.last_t, self.latest = t, channels
        if self.state in ('forefoot_unloaded', 'forefoot_loaded'):
            self._capture_forefeet(forefeet, t)
        elif self.state == 'standing':
            self._capture_standing(boards, t)
        elif self.segments is not None:
            angle = self._estimate(boards, dt)
            if self.state in RUNNING:
                self.angle_min = angle if self.angle_min is None else min(self.angle_min, angle)
                self.angle_max = angle if self.angle_max is None else max(self.angle_max, angle)
                for side in self.steps:
                    self._contact(side, forefeet[side], t)
                    if self.state == 'interrupted':
                        break
        return self.snapshot()

    def _capture_forefeet(self, forefeet, t):
        self.capture.append((t, forefeet))
        self.progress = min(1.0, (t-self.capture[0][0])/2e6, len(self.capture)/30)
        if self.progress < 1:
            return
        values = {}
        for side in self.steps:
            readings = [row[1][side] for row in self.capture]
            center = median(readings)
            values[side] = (center, median(abs(value-center) for value in readings))
        if self.state == 'forefoot_unloaded':
            self.baselines = values
        else:
            thresholds = {}
            for side in self.steps:
                center, noise = values[side]
                unloaded, unloaded_noise = self.baselines[side]
                delta = center-unloaded
                noise = max(noise, unloaded_noise)
                if (abs(delta) < max(50, 6*noise) or noise > max(12, .08*abs(delta))
                        or center in (0, 4095)):
                    self.state, self.progress = 'setup', 0.0
                    self.capture = []
                    self.reason = 'Forefoot readings overlap or are noisy; repeat both forefoot captures.'
                    return
                thresholds[side] = (unloaded+.65*delta, unloaded+.35*delta, 1 if delta > 0 else -1)
            self.thresholds = thresholds
        self.state, self.capture = 'setup', []
        self.reason = None

    def _capture_standing(self, boards, t):
        stable = all(GRAVITY_MIN_G <= math.sqrt(sum(x*x for x in accel)) <= GRAVITY_MAX_G
                     and math.sqrt(sum(x*x for x in gyro)) <= GYRO_NOISE_DPS
                     for accel, gyro in boards)
        if not stable:
            self.capture, self.progress = [], 0.0
            self.reason = 'Stand still to restart gait standing calibration.'
            return
        self.capture.append((t, boards))
        self.progress = min(1.0, (t-self.capture[0][0])/3e6, len(self.capture)/60)
        if self.progress < 1:
            return
        segments = []
        for index, name in enumerate(('thigh', 'shin')):
            readings = [row[1][index] for row in self.capture]
            if any(pstdev([reading[0][axis] for reading in readings]) > ACCEL_NOISE_G for axis in range(3)):
                self.capture, self.progress = [], 0.0
                self.reason = 'Movement detected; stand still for gait calibration.'
                return
            accel = [mean(reading[0][axis] for reading in readings) for axis in range(3)]
            axis = self.config[name+'_axis']
            if math.sqrt(sum(accel[j]**2 for j in range(3) if j != axis['index'])) < PLANE_MIN_G:
                self.state, self.capture, self.progress = 'setup', [], 0.0
                self.reason = 'Gravity is parallel to a selected hinge; check signed axes.'
                return
            tilt = _gravity_tilt(accel, axis)
            segments.append({'tilt': tilt, 'reference': tilt,
                             'bias': [mean(reading[1][j] for reading in readings) for j in range(3)]})
        self.segments, self.state, self.capture = segments, 'ready', []
        self.reason = None

    def _estimate(self, boards, dt):
        for segment, name, (accel, gyro) in zip(self.segments, ('thigh', 'shin'), boards):
            axis = self.config[name+'_axis']
            index = axis['index']
            segment['tilt'] += axis['sign']*(gyro[index]-segment['bias'][index])*dt
            magnitude = math.sqrt(sum(value*value for value in accel))
            projection = math.sqrt(sum(accel[j]**2 for j in range(3) if j != index))
            if GRAVITY_MIN_G <= magnitude <= GRAVITY_MAX_G and projection >= PLANE_MIN_G:
                segment['tilt'] += (1-math.exp(-dt/FILTER_TAU_S))*_wrap(_gravity_tilt(accel, axis)-segment['tilt'])
        return _wrap((self.segments[0]['tilt']-self.segments[0]['reference'])
                     -(self.segments[1]['tilt']-self.segments[1]['reference']))

    def _contact(self, side, reading, t):
        on, off, direction = self.thresholds[side]
        candidate = self.contacts[side]
        if (reading-on)*direction >= 0:
            candidate = True
        elif (reading-off)*direction <= 0:
            candidate = False
        if candidate is None:
            return
        if candidate != self.candidates[side]:
            self.candidates[side], self.candidate_t[side] = candidate, t
        if candidate == self.contacts[side] or (t-self.candidate_t[side])/1e6 < CONTACT_DWELL_S:
            return
        event_t = self.candidate_t[side]
        previous = self.contacts[side]
        self.contacts[side] = candidate
        if previous is not None and self.contact_t[side] is not None:
            self.forefoot_times[side][previous].append((event_t-self.contact_t[side])/1e6)
        self.contact_t[side] = event_t if previous is not None else None
        if not candidate:
            self.armed[side] = True
        elif self.armed[side]:
            self.armed[side] = False
            if self.last_event is not None and self.last_event[0] == side:
                self.interrupt('Repeated same-side forefoot event; gait alternation lost. Repeat calibration.')
                return
            if self.last_event is not None and event_t <= self.last_event[1]:
                self.interrupt('Simultaneous forefoot events cannot establish gait timing. Repeat calibration.')
                return
            self.steps[side] += 1
            if self.last_event is not None:
                self.step_times[side].append((event_t-self.last_event[1])/1e6)
            if self.side_event[side] is not None:
                self.stride_times[side].append((event_t-self.side_event[side])/1e6)
            self.side_event[side], self.last_event = event_t, (side, event_t)
