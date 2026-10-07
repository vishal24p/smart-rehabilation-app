# Changelog

## [1.2.0.0] - 2026-10-07

### Added
- Start grouped workout sessions, perform sequential exercises, and review saved sessions in the home calendar and history.
- Record and save personal healthy-thigh references for squat and sit-to-stand, with a stable standing-zero countdown and measured range preview.
- Set repetition targets for each exercise and freeze results when the target is reached or a session ends or is interrupted.
- Save injured-leg settings, heel baselines, exercise references and workout results locally, with retry-safe session saves.
- Use supplied ESP8266 and MPU axis-capture firmware with named heel channels and optional shin readings.

### Changed
- Show only which leg has the higher heel signal, or Same when the signals differ by at most 10% of the larger value; remove percentages from the main pressure comparison.
- Simplify patient navigation and live heel comparison, with accessible layouts for small screens and large text.
- Label the Android app Gait Analysis.
- Recover reference recording after short sample gaps and reject unstable zero captures.

### Fixed
- Connect to the ESP hotspot named REHAB, matching the user's uploaded firmware, including detection of an already joined network.
- Retain an already observed full-depth movement during sensor gaps shorter than ten seconds, then count it once when fresh readings confirm standing; retain observed reference bends across brief loss too.
- Compare movement depth at the same one-decimal precision shown on screen; continue gyro-based thigh readings during acceleration-only saturation instead of interrupting the exercise.
- Keep Android Wi-Fi approval requests open instead of cancelling after 20 seconds; stop repeated prompts after failure and reuse an already joined wearable network.
- Limit I2C clock-stretch waits in the supplied ESP8266 firmware to reduce multi-second streaming stalls when the MPU bus fails.
- Wait up to ten seconds for fresh thigh readings during registration and exercises, preserving completed repetitions and observed full depth while discarding unqualified partial movements; restart standing-zero countdowns without another tap.
- Keep thigh readings visible during movement; remove movement holds, duration requirements and the fixed 30-degree registration minimum. Count sessions only after reaching the full saved depth and returning standing.
- Retry interrupted standing zero on the same exercise page and expose disconnect controls during live registration.
- Start reference recording and exercises without inheriting sample gaps from before the new capture; longer gaps still freeze completed results safely.
- Correct left/right heel mapping and preserve compatibility with existing sensor headers.
- Treat supplied dual-IMU failed-read zeros as unavailable motion data, preserving heel readings and preventing false repetitions.
- Retain interrupted workout results when reconnect is requested during disconnect cleanup.

### Verification
- Log repetition phases, completed movement peaks, saved depth and standing tolerance to explain uncounted movements.
- Save bounded phone-local debug logs for Wi-Fi joining, authentication, IP setup, TCP connection and app disconnects.
- Add local Android debug diagnostics for sample timing, rejected rows, socket failures and lifecycle stops.
- Log missing/restored thigh readings, processor state/reason transitions with thigh vectors and tilt, and session command timing in the bounded phone-local log.
- Expand automated checks for sensor processing, reference recovery, target results, persistence and workout lifecycle behavior.
