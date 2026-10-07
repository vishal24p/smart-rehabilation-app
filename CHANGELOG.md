# Changelog

## [1.1.0.0] - 2026-10-07

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
- Start reference recording and exercises without inheriting sample gaps from before the new capture; actual gaps during exercise still freeze completed results safely.
- Correct left/right heel mapping and preserve compatibility with existing sensor headers.
- Treat supplied dual-IMU failed-read zeros as unavailable motion data, preserving heel readings and preventing false repetitions.
- Retain interrupted workout results when reconnect is requested during disconnect cleanup.

### Verification
- Expand automated checks for sensor processing, reference recovery, target results, persistence and workout lifecycle behavior.
