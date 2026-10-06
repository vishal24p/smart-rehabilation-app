# Rehab monitor

Flutter Android app with embedded Python processing. Home opens **Squat** and
**Sit-to-stand** sessions, **Exercise references**, and live ESP32 diagnostics.
One thigh MPU estimates standing-relative thigh tilt and bend-return repetitions.
SQLite stores a personal reference for each exercise. Outputs are prototype
estimates, not clinical accuracy, diagnosis or recovery scores.

## Healthy-thigh references and exercise sessions

1. Open **Exercise references**, choose the exercise, and connect the wearable.
2. Tap **Record healthy-thigh reference** with the MPU on the healthy thigh.
   Stand still during the large **3 → 2 → 1** session-zero countdown. It completes
   only after three seconds and at least 60 stable samples; motion resets it.
3. Perform one complete movement and return standing, then **Finish recording**.
   A clear excursion of at least 30° with a brief lowered hold and return is an
   engineering capture requirement, not a prescribed clinical exercise target.
4. Review the measured thigh range and **Save reference**. Each exercise is saved
   locally in SQLite and survives app restart. **Re-record reference** replaces
   it only after another successful save; cancellation retains the previous one.
5. From home, choose the exercise and connect, then **Start exercise**. The saved
   target loads automatically. Stand still for the session-zero countdown, then
   exercise. Completed upright-lowered-upright cycles show their peak thigh tilt
   and difference from the saved reference. **End exercise** stops counting.

The selected exercise labels the session: one thigh MPU cannot distinguish squat
from sit-to-stand, confirm chair contact, measure knee angle, or certify form.
Inclination includes lateral tilt. Use consistent placement on the front thigh.
Reference and exercise routes use ±2g/±250°/s, matching the supplied ESP32 firmware.

## Phone setup

1. Install the Android app using `flutter run` or the built debug APK.
2. Power ESP32. Open **Live sensors** and tap **Connect wearable**.
3. Accept Android permission/Wi-Fi prompts. Expected Wi-Fi: `REHAB-WEARABLE`,
   password `rehab1234`. It provides no internet; stay connected to it.
   On older Android versions, join through **Open Wi-Fi settings**, return and
   connect again.
4. Move thigh/shin sensors and press the heel sensor; verify their readings change.
5. Use the calibration/session controls below before starting an exercise session.
6. **Disconnect**, leaving the view, or backgrounding stops readings/retries.
   Returning requires connecting again. Saved exercise references persist;
   live readings and sensor zero do not run in the background.

Python runs inside the installed APK. No laptop, cloud server, internet or phone
Python installation is required during a session. Building downloads dependencies.

## Optional two-MPU knee calibration in Live sensors

1. Verify both MPU ranges are ±2g and ±250°/s, then enable **IMU ranges confirmed**.
   If already connected in raw mode, disconnect, enable it and reconnect.
   Select each board's signed X/Y/Z hinge axis using its actual markings. Each
   selected axis must be parallel to the knee hinge, with both signed directions
   pointing to the same physical side. The board guide is an example, not an
   automatic mounting detector. Confirm **Mounting and signed axes verified**,
   then tap **Confirm setup**. Unconfirmed motion metrics remain unavailable.
2. Optionally calibrate heel contact: **Capture unloaded heel** while unloaded
   and still for two seconds, then **Capture loaded heel** while steadily pressed
   for two seconds. Poor separation leaves contact unknown; valid motion
   calibration can continue. Heel contact means this sensor is pressed, not
   full-foot stance or chair contact. Saturation does not measure load magnitude.
3. Tap **Ready for standing reference** in your comfortable upright pose. Hold
   still for three consecutive seconds; at least 60 accepted samples are needed.
   Movement resets the capture. This is a user-confirmed standing reference,
   not a claim of anatomical zero degrees.
4. Tap **Ready for movement check** upright. Hold upright briefly, perform two slow
   **stand → sit → stand** cycles at your pace, then **Finish movement check** upright.
   Calibration checks repeatable movement and return; these cycles do not count
   toward a session. Follow the reason shown if calibration needs repeating.
5. **Start session** becomes available after valid motion calibration. Only
   completed bend-and-return cycles increment **Detected sit-to-stand cycles**;
   ending halfway through a cycle does not add one. **Estimated knee bend from
   standing** is a sagittal, standing-relative estimate. Session ROM uses accepted
   angles during the active session; last-cycle time excludes return debounce.
6. **End session** freezes completed counts, ROM, active duration and cycle times in an
   in-memory summary. Connection/quality loss or backgrounding interrupts the
   session, discards a partial cycle and retains completed results marked
   interrupted. Reconnect requires calibration again. A successful new Start
   clears the prior summary; leaving the live route or terminating the app loses it.

Calibration and detection thresholds are unvalidated engineering settings kept
together in `android/app/src/main/python/rehab_session.py`. Compare sensor mounting,
counts/timings and angles with manually observed cycles and reference measurements
before interpreting results. No new ESP32 firmware or wiring is required.

## Sensor protocol and units

TCP `192.168.4.1:5000` sends this header then newline-delimited integer CSV:

```text
time_us,thigh_ax,thigh_ay,thigh_az,thigh_gx,thigh_gy,thigh_gz,shin_ax,shin_ay,shin_az,shin_gx,shin_gy,shin_gz,fsr
```

Thigh MPU6050: `0x69`; shin: `0x68`; FSR: GPIO34. Timestamp is unsigned 32-bit
microseconds, motion values signed 16-bit counts, heel ADC 0..4095. CRLF accepted.
Verify the actual firmware/header and MPU configuration before physical-unit use.

### Two heel sensors

The existing `fsr` column represents the **right** heel. To send the left heel,
append `fsr_left` to the header and append its integer ADC reading to every row:

```text
time_us,thigh_ax,thigh_ay,thigh_az,thigh_gx,thigh_gy,thigh_gz,shin_ax,shin_ay,shin_az,shin_gx,shin_gy,shin_gz,fsr,fsr_left
```

Both channels accept 0..4095. The old right-only stream still works; left readings
and comparison remain unavailable until both channels arrive. Firmware wiring
and the second GPIO are configured separately; this change is software-only.

The app also accepts explicit named heel columns (`fsr_left,fsr_right`), including
the supplied thigh-only firmware header:

```text
time_us,thigh_ax,thigh_ay,thigh_az,thigh_gx,thigh_gy,thigh_gz,fsr_left,fsr_right
```

To retain shin readings in that format, insert
`shin_ax,shin_ay,shin_az,shin_gx,shin_gy,shin_gz` before the two heel columns,
and transmit the actual six shin readings in each row. Names determine heel
assignment: the supplied sketch labels GPIO34 left and GPIO35 right.

Thigh-only streams keep heel capture/comparison active, but display shin readings
and knee metrics as unavailable. Existing shin-enabled streams retain their
normal calibration and session flow. The supplied thigh-only firmware's six-zero
failed-read placeholder is treated as unavailable thigh data; it does not
replace missing shin data. Restoring both IMUs requires fresh motion calibration.

In Live sensors, capture both heels **unloaded**, then both **steadily loaded**,
for two seconds each. Heel capture does not require IMU axes or weight input.
Python determines each channel's unloaded median, noise and loaded polarity.
It computes `signal = max(0, (ADC - unloaded_baseline) * polarity)`, discarding
signals within `max(5 ADC, 3 * calibration noise)` of zero. Left/right shares
are `100 * signal / (left_signal + right_signal)` and total 100%; the display
rounds one side and uses its complement for the other.

These are **relative heel ADC signal shares**, not calibrated force, pressure,
body-weight distribution, or whole-leg loading. FSR response is nonlinear; equal
ADC excursions do not establish equal force. No Newton conversion is assumed.
Before heel captures, the bottom comparison uses raw ADC shares when both
channels are available and neither is clipped. Both-zero signals have no share.
Valid heel captures switch comparison to baseline-adjusted shares. Missing left
data, clipped measurements, and calibrated no-load states show a reason.
These heel captures remain separate from saved thigh references.

Readings default to raw counts. Enable **IMU ranges confirmed** only after checking
both MPUs use ±2g acceleration and ±250°/s angular velocity. Python then divides
acceleration by 16384 and angular velocity by 131. Heel ADC is not force in newtons.
The graph retains at most ten seconds, with fixed ADC range 0..4095.

## Permissions and recovery

Android 10–12 request Location permission (precise on Android 12); Android 13+ use
Nearby Wi-Fi devices. No Wi-Fi scanning or location recording. Older phones may
require Location services. Errors offer retry/settings. TCP uses selected Wi-Fi
even when cellular is enabled. Live requires a valid sample; three seconds with
no valid sample clears readings. Foreground retries use 1, 2, then 5-second delays.
Timestamp restart clears graph history; Disconnect cancels retries/resources.
Timestamp rollback, repeated headers, TCP retry or a device gap over 250 ms also
invalidates calibration. IMU clipping or unreliable motion stops motion analytics.
Unavailable current metrics display an em dash; a frozen summary stays separate.

## Build and checks

Flutter, Android SDK/JDK 17 and local Python 3.11 are build requirements. Chaquopy
bundles Python 3.11 for arm64 phones/x86_64 emulators, minimum API 24. Preserve the
current Android Gradle/Kotlin versions.

```powershell
flutter pub get
py -3.11 -m unittest discover -s test/python -v
android/gradlew.bat -p android :app:testDebugUnitTest
flutter analyze
flutter test
flutter build apk --debug
```

Physical acceptance: test permissions denied/retry, cellular off/on, wearable
power loss/restart, Disconnect during retries, background/return and screen exit.
Verify sensors independently change their readings and stale readings disappear.
Keep **Live sensors** foreground while testing the no-internet ESP32 connection;
opening Android Wi-Fi settings backgrounds the app and stops its session. Test
guided calibration, complete/partial cycles, interrupted summaries, heel contact
with increasing/decreasing ADC, and reference angle differences. Automated checks
and APK builds do not establish hardware correctness or clinical accuracy.

Live UI: `lib/live_sensor_screen.dart`; channel state: `lib/wearable_connection.dart`.
Calibration/session panel: `lib/rehab_session_panel.dart`.
Android transport: `android/app/src/main/kotlin/com/example/rehab_monitor/`.
Python parser: `android/app/src/main/python/rehab_sensor.py`;
calculations/session state: `android/app/src/main/python/rehab_session.py`.
