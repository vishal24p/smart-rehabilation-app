# Changelog

## [1.2.0.0] - 2026-10-07

### Added
- Start grouped workout sessions, perform sequential exercises, and review saved sessions in the home calendar and history.
- Record and save personal healthy-thigh references for squat and sit-to-stand, with a stable standing-zero countdown and measured range preview.
- Set repetition targets for each exercise and freeze results when the target is reached or a session ends or is interrupted.
- Save injured-leg settings, heel baselines, exercise references and workout results locally, with retry-safe session saves.
- Use supplied ESP8266 and MPU axis-capture firmware with named heel channels and optional shin readings.

### Changed
- Simplify patient navigation and live heel comparison, with accessible layouts for small screens and large text.
- Label the Android app Gait Analysis.
- Recover reference recording after short sample gaps and reject unstable zero captures.

### Fixed
- Keep Android Wi-Fi approval requests open instead of cancelling after 20 seconds; stop repeated prompts after failure and reuse an already joined wearable network.
- Limit I2C clock-stretch waits in the supplied ESP8266 firmware to reduce multi-second streaming stalls when the MPU bus fails.
- Wait up to ten seconds for fresh thigh readings during registration and exercises, preserving completed repetitions and discarding partial movements; restart standing-zero countdowns without another tap.
- Allow complete bend-and-return movements without a fixed one-second duration requirement; retain brief bend and upright holds and sensor-quality checks.
- Retry interrupted standing zero on the same exercise page and expose disconnect controls during live registration.
- Start reference recording and exercises without inheriting sample gaps from before the new capture; longer gaps still freeze completed results safely.
- Correct left/right heel mapping and preserve compatibility with existing sensor headers.
- Treat supplied dual-IMU failed-read zeros as unavailable motion data, preserving heel readings and preventing false repetitions.
- Retain interrupted workout results when reconnect is requested during disconnect cleanup.

### Verification
- Save bounded phone-local debug logs for Wi-Fi joining, authentication, IP setup, TCP connection and app disconnects.
- Add local Android debug diagnostics for sample timing, rejected rows, socket failures and lifecycle stops.
- Log missing/restored thigh readings, processor state/reason transitions and session command timing in the bounded phone-local log.
- Expand automated checks for sensor processing, reference recovery, target results, persistence and workout lifecycle behavior.
