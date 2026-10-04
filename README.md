# Rehab monitor

Flutter Android app with embedded Python processing. **Live sensors** opens
actual ESP32 readings and a heel ADC graph; the dashboard is a labeled sample
review. Calibration, knee angle/ROM, repetitions and live accuracy come later.

## Phone setup

1. Install the Android app using `flutter run` or the built debug APK.
2. Power ESP32. Open **Live sensors** and tap **Connect wearable**.
3. Accept Android permission/Wi-Fi prompts. Expected Wi-Fi: `REHAB-WEARABLE`,
   password `rehab1234`. It provides no internet; stay connected to it.
   On older Android versions, join through **Open Wi-Fi settings**, return and
   connect again.
4. Move thigh/shin sensors and press the heel sensor; verify their readings change.
5. **Disconnect**, leaving the view, or backgrounding stops readings/retries.
   Returning requires connecting again. No persistence/background recording.

Python runs inside the installed APK. No laptop, cloud server, internet or phone
Python installation is required during a session. Building downloads dependencies.

## Sensor protocol and units

TCP `192.168.4.1:5000` sends this header then newline-delimited integer CSV:

```text
time_us,thigh_ax,thigh_ay,thigh_az,thigh_gx,thigh_gy,thigh_gz,shin_ax,shin_ay,shin_az,shin_gx,shin_gy,shin_gz,fsr
```

Thigh MPU6050: `0x69`; shin: `0x68`; FSR: GPIO34. Timestamp is unsigned 32-bit
microseconds, motion values signed 16-bit counts, heel ADC 0..4095. CRLF accepted.
Verify the actual firmware/header and MPU configuration before physical-unit use.

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
Automated checks and APK builds do not establish hardware correctness.

Live UI: `lib/live_sensor_screen.dart`; channel state: `lib/wearable_connection.dart`.
Android transport: `android/app/src/main/kotlin/com/example/rehab_monitor/`.
Python processing: `android/app/src/main/python/rehab_sensor.py`.
