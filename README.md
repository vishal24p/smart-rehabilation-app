# Rehab monitor

Flutter Android app with embedded Python processing. **Home** starts grouped
**Squat** and **Sit-to-stand** sessions and shows saved history; **Register**,
**Sensors**, and **Settings** provide references, diagnostics, and setup.
One thigh MPU estimates standing-relative thigh tilt and bend-return repetitions.
SQLite stores exercise references, settings, and workout results. Outputs are prototype
estimates, not clinical accuracy, diagnosis or recovery scores.

## Healthy-thigh references and exercise sessions

1. Open **Register**, choose the exercise, and connect the wearable.
2. Tap **Record reference** with the MPU on the healthy thigh.
   Stand still during the large **3 → 2 → 1** session-zero countdown. It completes
   only after three seconds and at least 60 stable samples; motion resets it.
3. Perform one complete movement and return standing, then **Finish recording**.
   Move beyond the standing tolerance and return; there is no minimum depth,
   movement duration or hold requirement.
4. Review the measured thigh range and **Save reference**. Each exercise is saved
   locally in SQLite and survives app restart. **Re-record reference** replaces
   it only after another successful save; cancellation retains the previous one.
5. In **Settings**, set each exercise's repetition target and tap **Save targets**.
   Targets are whole numbers from 1 to 1000, default to 10, and are loaded when
   starting a new workout session. Select the injured leg to highlight its heel.
6. On **Home**, tap **Start session**, choose an exercise, connect, then tap
   **Start exercise**. The saved reference loads automatically. Stand still for
   the session-zero countdown, then exercise. Completed upright-lowered-upright
   cycles count only when they reach the saved depth and return. They show peak
   thigh tilt and difference from the saved reference. Depth comparisons use the
   same one-decimal precision shown on screen.
7. Reaching the repetition target automatically ends the exercise. **End exercise**
   saves completed repetitions with an ended-early outcome; partial cycles do not
   count. After saving, **Return to session** lets you repeat or choose another
   exercise. **End session** saves the grouped workout. Use **Retry saving** if a
   save fails; continuing is blocked until the pending result is saved.
8. **Home** shows sessions by their local start date in the calendar and history.
   Open one to review each exercise's repetitions, active duration, final peak,
   reference, and difference. Interrupted results keep their completed repetitions.
   After an app restart, an unfinished workout can be reviewed and **Close session**
   saves its end; sensor counting does not resume. Only previously saved results
   survive process termination.

The selected exercise labels the session: one thigh MPU cannot distinguish squat
from sit-to-stand, confirm chair contact, measure knee angle, or certify form.
Inclination includes lateral tilt. Use consistent placement on the front thigh.
Reference and exercise routes use ±2g/±250°/s, matching the supplied ESP8266 firmware.
Each new capture starts its own sample clock. A gap before tapping Record or Start
does not interrupt the new capture. Gaps shorter than ten seconds retain a movement
that already reached the saved depth; the next valid standing reading completes it
once. Movements that had not reached the depth are discarded. Fresh readings show
the current angle immediately. Completed repetitions are preserved. During standing zero, these
gaps restart the countdown automatically. Missing thigh readings wait for fresh
values for up to ten seconds, without counting movements during the loss. Reference
recording retains an observed bend until fresh readings confirm the standing return.
Ten seconds without fresh readings or a disconnect interrupts the attempt and
requires a fresh zero. Completed repetitions remain saved. Readings stay visible
during movement; no bend or return holds are required.

## Phone setup

1. Install the Android app using `flutter run` or the built debug APK.
2. Power the wearable. Open **Sensors** and tap **Connect wearable**.
3. Accept Android permission/Wi-Fi prompts. Expected Wi-Fi: `REHAB`,
   password `rehab1234`. It provides no internet; stay connected to it.
   On older Android versions, join through **Open Wi-Fi settings**, return and
   connect again.
   If already joined to that network, the app uses the existing Wi-Fi connection.
   The Android approval prompt has no app-imposed 20-second deadline. If the
   request is declined or fails, retry explicitly or open Wi-Fi settings; the app
   does not repeatedly reopen the prompt.
4. Expand **Sensor details**. Move thigh/shin sensors and press each heel sensor;
   verify the correct physical side's readings change.
5. In **Settings**, connect and tap **Capture unloaded sensors** with both heels
   unloaded and still for two seconds. At least 40 stable samples are required;
   missing, unstable, or clipped readings fail capture. The 10-bit baseline saves
   locally and restores on connection. Recapture after sensor placement changes.
6. **Disconnect**, switching away from Sensors/Register/Settings, or backgrounding
   stops readings/retries. Returning requires connecting again. A grouped workout
   keeps its connection between exercise routes; backgrounding interrupts its active
   exercise. Saved settings/references/results persist, but live counting and session
   zero do not run in the background. Zero is set again for each exercise.

Python runs inside the installed APK. No laptop, cloud server, internet or phone
Python installation is required during a session. Building downloads dependencies.

## Optional two-MPU knee calibration in Live sensors

1. In **Sensors**, expand **Calibration & setup**. Verify both MPU ranges are ±2g
   and ±250°/s, then enable **IMU ranges confirmed**.
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
before interpreting results. This optional flow retains the legacy two-MPU stream;
its in-memory summary is separate from the saved thigh-exercise workout history.

## Sensor protocol and units

TCP `192.168.4.1:5000` sends this header then newline-delimited integer CSV:

```text
time_us,thigh_ax,thigh_ay,thigh_az,thigh_gx,thigh_gy,thigh_gz,shin_ax,shin_ay,shin_az,shin_gx,shin_gy,shin_gz,fsr
```

Thigh MPU6050: `0x69`; shin: `0x68`. Timestamp is unsigned 32-bit microseconds,
motion values signed 16-bit counts, and the parser accepts heel ADC 0..4095 for
legacy ESP32 streams. CRLF is accepted. The app-compatible sketch in
`firmware/esp8266_app_compatible/` targets ESP8266:
I2C SDA/SCL are GPIO4/5, heel-select outputs GPIO14/12, and shared ADC A0 is 0..1023.
It sends the named dual-heel format below; legacy ESP32 GPIO34/35 wiring is separate.
Verify the actual firmware/header and MPU configuration before physical-unit use.
The supplied ESP8266 sketches limit I2C clock stretching to 1 ms per bit. This
reduces a stuck-clock failure path that otherwise can pause the two MPU reads
for about 2.7 seconds. This setting does not apply to ESP32 firmware.

`firmware/mpu_axis_capture/` is a separate standalone HTTP dashboard on port 80,
with its own calibration, exercise controls and reports. It does not provide the
TCP CSV stream required by the Android app. Use the app-compatible sender for
Android sessions; keeping this HTTP sketch does not change the app protocol.

For a Register/exercise interruption, Android debug builds log bounded diagnostics
under `RehabWearable`. Device timestamp gaps, rejected CSV row counts, arrival/parse
timing, socket failures, and explicit lifecycle stops are logged. State/reason
changes also log thigh acceleration, gyro and tilt to explain sensor faults.
Repetition-phase logs show depth reached, standing return, movement peak and count.
These distinguish a sender pause from parser rejection or a
connection stop. Release builds omit these diagnostics. Inspect them with
`adb logcat -s RehabWearable:D '*:S'` while reproducing the issue.

### Two heel sensors

The right-only `fsr` stream represents the **right** heel. To add the other heel,
append `fsr_left` to the header and append its integer ADC reading to every row:

```text
time_us,thigh_ax,thigh_ay,thigh_az,thigh_gx,thigh_gy,thigh_gz,shin_ax,shin_ay,shin_az,shin_gx,shin_gy,shin_gz,fsr,fsr_left
```

Both channels accept 0..4095. The old right-only stream still works; left readings
and comparison remain unavailable until both channels arrive. With two channels,
the app swaps the CSV heel labels to match this wearable's physical wiring:
`fsr`/`fsr_right` becomes physical left, and `fsr_left` becomes physical right.
Verify physical sides by pressing each sensor; do not infer sides from CSV names.

The app also accepts explicit named heel columns (`fsr_left,fsr_right`), including
this thigh-only header:

```text
time_us,thigh_ax,thigh_ay,thigh_az,thigh_gx,thigh_gy,thigh_gz,fsr_left,fsr_right
```

To retain shin readings in that format, insert
`shin_ax,shin_ay,shin_az,shin_gx,shin_gy,shin_gz` before the two heel columns,
and transmit the actual six shin readings in each row. Both supplied ESP8266
sketches use that full named dual-IMU header and the heel-label swap above.

Thigh-only streams keep heel capture/comparison active, but display shin readings
and knee metrics as unavailable. Existing shin-enabled streams retain their
normal calibration and session flow. Named-header streams treat six-zero failed
IMU reads as unavailable data for the affected board, preserving heel readings.
A failed thigh read pauses exercise counting for up to ten seconds and cannot
complete a repetition from frozen tilt. Legacy headers keep their interpretation. Restoring
both IMUs requires fresh motion calibration.

For optional legacy heel-contact calibration in **Sensors → Calibration & setup**,
capture both heels **unloaded**, then both **steadily loaded**,
for two seconds each. Heel capture does not require IMU axes or weight input.
Python determines each channel's unloaded median, noise and loaded polarity.
It computes `signal = max(0, (ADC - unloaded_baseline) * polarity)`, discarding
signals within `max(5 ADC, 3 * calibration noise)` of zero. Left/right shares
are computed internally for comparison. The main display shows only **Left leg more**,
**Right leg more**, or **Same** when the two signals differ by at most 10% of the
larger signal. Missing or ineffective readings do not display Same.

These are **relative heel ADC signal shares**, not calibrated force, pressure,
body-weight distribution, or whole-leg loading. FSR response is nonlinear; equal
ADC excursions do not establish equal force. No Newton conversion is assumed.
The main comparison requires a baseline; it does not fall back to raw ADC shares.
The saved **Settings** baseline uses `max(0, ADC - baseline)` for each heel,
gates totals at the sum of channel deadbands, and filters signals with a 0.15-second
time constant before dividing. It needs no loaded capture. Missing channels,
clipped measurements, and no-load states show a reason. Settings baselines remain
separate from thigh references and optional unloaded/loaded heel-contact captures.

Readings default to raw counts. Enable **IMU ranges confirmed** only after checking
both MPUs use ±2g acceleration and ±250°/s angular velocity. Python then divides
acceleration by 16384 and angular velocity by 131. Heel ADC is not force in newtons.
The graph retains at most ten seconds, with fixed ADC display range 0..1023 for the
supplied wearable. Legacy parser acceptance up to 4095 does not change that range.

## Permissions and recovery

Android 10–12 request Location permission (precise on Android 12); Android 13+ use
Nearby Wi-Fi devices. No Wi-Fi scanning or location recording. Older phones may
require Location services. Errors offer retry/settings. TCP uses selected Wi-Fi
even when cellular is enabled. Live requires a valid sample; ten seconds with
no valid sample clears readings. Foreground retries use 1, 2, then 5-second delays.
Timestamp restart clears graph history; Disconnect cancels retries/resources.
Timestamp rollback, repeated headers, TCP retry or a device gap over 250 ms also
invalidates two-IMU calibration. Thigh reference recording and exercises recover
from gaps over 250 ms and shorter than ten seconds with fresh readings visible
immediately; observed full depth is retained until a valid standing return. Other
partial movements are discarded and standing re-arms counting. Timestamp resets and
gaps of ten seconds or more interrupt. Gyro clipping interrupts thigh analytics;
acceleration-only clipping during continuous movement skips accelerometer correction
and keeps the gyro estimate. A new zero requires unsaturated readings, and recovery
after a gap waits for unsaturated acceleration to establish the current pose.
Temporary acceleration changes during movement do not hide thigh tilt; gyro
integration continues while acceleration is unsuitable for correcting the estimate.
Unavailable current metrics display an em dash; a frozen summary stays separate.
The screen stays awake while the wearable connection is active; disconnect clears it.

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
# With a connected Android device/emulator:
android/gradlew.bat -p android :app:connectedDebugAndroidTest
```

Physical acceptance: test permissions denied/retry, cellular off/on, wearable
power loss/restart, Disconnect during retries, background/return and screen exit.
Verify sensors independently change their readings and stale readings disappear.
Keep **Sensors** foreground while testing the no-internet wearable connection;
opening Android Wi-Fi settings backgrounds the app and stops its session. Test
guided calibration, complete/partial cycles, interrupted summaries, heel contact
with increasing/decreasing ADC, reference angle differences, automatic target
completion, save retries, history after restart, and failed IMU reads. Automated checks
and APK builds do not establish hardware correctness or clinical accuracy.

Debug builds save Wi-Fi request, handshake/authentication, IP, TCP and lifecycle
diagnostics in the phone's private `files/wearable-connection.log`, rotated at
64 KiB. They also appear under the `RehabWearable` logcat tag. No passwords or
raw sensor readings are recorded. With USB debugging connected, retrieve the file
with `adb shell run-as com.example.rehab_monitor cat files/wearable-connection.log`.
Android may expose only a generic connection failure; compare these timestamps
with Android Wi-Fi system logs for association rejection details.

Live UI: `lib/live_sensor_screen.dart`; channel state: `lib/wearable_connection.dart`.
Calibration/session panel: `lib/rehab_session_panel.dart`.
Thigh references/session controls: `lib/exercise_reference_screen.dart`,
`lib/exercise_reference.dart`, and `lib/thigh_session_panel.dart`.
Grouped workouts/history: `lib/workout_session.dart`, `lib/workout_session_screen.dart`,
and `lib/session_home_screen.dart`; settings: `lib/app_settings.dart`, `lib/settings_screen.dart`.
Android transport: `android/app/src/main/kotlin/com/example/rehab_monitor/`.
SQLite storage/validation: `ExerciseReferenceStore.kt` and `WorkoutSessionPayload.kt`
in that Android folder.
Python parser: `android/app/src/main/python/rehab_sensor.py`;
calculations/session state: `android/app/src/main/python/rehab_session.py` and
`android/app/src/main/python/thigh_session.py`.

## Gait demonstration

Open **Home → Gait analysis** in the Android app. The wearable must stream
both MPU6050s (right thigh and right shin) plus the two forefoot FSRs (one under the ball of each foot) over the existing
Wi-Fi connection. No trained model is required. The ESP8266 firmware must preserve the existing CSV and 0..4095 FSR signal contract.

1. Connect and verify both IMUs use ±2g and ±250°/s. Select each signed hinge axis
   and confirm right-leg mounting. Load each forefoot separately to verify the app's
   left/right labels. The parser retains the previous side swap: match readings to physical sensors before confirming setup.
2. Confirm gait setup, capture both unloaded forefeet, capture both loaded forefeet,
   then complete standing calibration. Calibration never starts walking automatically.
3. Enter the measured path distance and press **Start baseline walk**. Walk the path
   and press **Stop walk** at its end. Complete at least ten same-foot stride intervals
   on each side. Preview and explicitly save the baseline; replacing it requires an
   explicit save. Failed captures or saves retain the previous reference.
4. Enter the comparison path distance and press **Start comparison walk**, then
   manually stop. Keep mounting and walking conditions consistent with the baseline.

The app shows step counts, cadence, mean step/stride times, timing asymmetry,
forefoot-loaded/unloaded duration proxies, right-leg angular excursion, trial average
speed and approximate average step/stride lengths. Average speed includes pauses;
lengths are distance/count estimates, with start/stop boundary error, not per-foot
spatial measurements. Timing uses local forefoot loading events, not heel strikes. Forefoot unloading is not verified toe-off: true stance, swing and double
support remain unavailable. Angular excursion is not a validated anatomical knee angle.

Comparison uses cadence and mean left/right step and stride times. A deviation
strictly greater than the editable tolerance (20% by default) gives **Outside reference**
and names the triggering metric. Otherwise a usable comparison gives **Within reference**.
Short, interrupted, malformed or unreliable trials give **Insufficient data** and
cannot replace a baseline. A recorded baseline is not proof of healthy gait; these
rules are demonstration settings, not normal/abnormal medical classification.

Forefoot baselines use `gait_forefoot_timing_v1` and `right_thigh_shin_bilateral_forefeet`. Saved heel baselines are ignored without deletion; record a new baseline after moving sensors. An explicit successful save replaces the old singleton.

One baseline persists locally in the existing Android reference database. Version 4
adds missing gait, settings and workout tables while preserving data from version 1,
both version-2 branch schemas and version 3. Automated synthetic
tests verify calculations and recovery, but real walking accuracy still needs video-
annotated recordings and physical validation.

Gait calculations: `android/app/src/main/python/gait_session.py`; DTO/store:
`lib/gait_analysis.dart`; trial UI: `lib/gait_session_panel.dart`.

### ESP8266 shared-A0 integration

The supplied firmware drives both FSR GPIOs as outputs, holding the inactive FSR LOW. With the shared-A0 wiring, that inactive FSR becomes an extra pressure-dependent path to ground and changes the selected sensor reading. The inactive pin must be high impedance (INPUT with no pull-up); only the selected pin drives HIGH. This is an engineering analysis of the supplied circuit, not a verified hardware result.

The ESP8266 core may cache ADC results for at least 5 ms while Wi-Fi runs. The supplied 100-microsecond separation cannot ensure independent readings; allow more than 5 ms after selecting each sensor and physically verify separate responses. Its 10-bit readings must be normalized from 0..1023 to 0..4095 to preserve the app's saturation contract. Do not confirm FSR setup until this is done. The app's legacy parser swaps FSR sides: compensate the transmitted column order or physically verify the resulting labels before calibration.

The user confirmed a bare ESP-12E module. Its ADC accepts 0..1 V and has no NodeMCU board divider. Do not use the pictured shared-A0 wiring as drawn: the selected 3.3 V GPIO can exceed the ADC limit. Add a suitable ADC protection divider before connecting A0; firmware timing and separate sensor response still require physical verification. [ESP8266 Arduino Core reference](https://arduino-esp8266.readthedocs.io/en/latest/reference.html#analog-input).
