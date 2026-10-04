# Rehab monitor

<!-- impeccable:product-schema 1 -->

## Platform

android

## Users and purpose

People checking wearable sensor readings during rehabilitation on an Android phone.
Connect to ESP32 over local Wi-Fi, inspect thigh/shin/heel readings and run guided
single-leg sit-to-stand sessions after verifying mounting and calibration.
A separate sample dashboard illustrates exercise session review.

## Capabilities and constraints

Flutter Android live sensor readings with Python embedded in the APK. ESP32 streams
thigh/shin IMU readings and heel ADC over local Wi-Fi; show readings and a ten-second
heel ADC graph. Guided setup requires confirmed IMU ranges and each board's signed
hinge axis, followed by a stable standing reference and two movement trials.
Optional unloaded/loaded heel captures calibrate sensor contact independently.
Live analytics show estimated knee bend from standing, session ROM, detected
stand → sit → stand cycles, last-cycle duration and heel-sensor contact.

Python owns calculations and processes every accepted frame; Android serializes
commands off the UI thread and Flutter presents cumulative snapshots. Calibration
cycles and partial session cycles do not count. Unavailable values stay unavailable.
End freezes counts, ROM, active duration and completed-cycle times; interruptions
retain completed results with an interrupted marker and require recalibration.
Summaries live only in memory, clear on successful new Start, and are lost on live
route exit or process termination. Foreground only; no auth, persistence or cloud.

These are standing-relative prototype estimates and detected movement cycles,
not clinical accuracy, anatomical extension, chair contact or recovery scores.
Heel contact describes pressure at one sensor, not force, whole-foot loading or
rep completion. Engineering thresholds and physical accuracy remain unvalidated;
hardware mounting, manually observed cycles and reference-angle comparisons are
required. Preserve ESP32 firmware, wiring and CSV format.
Keep sample session review clearly distinct from actual live readings.
Current sample: seated knee extension 16/20; supported sit to stand 12/16.
Combined sample: 28/36, rounded to 78%. Preserve the current visual direction.
Live Python/Wi-Fi support targets Android first; other Flutter platforms can
still display the sample dashboard.

## Brand commitments

User requests a white theme, real shader gradient with fine grain, new typography
and logo treatment, consistent library icons, and mobile-first alignment.
No emojis or repetitive decorative pills. The existing dark UI is rejected.
