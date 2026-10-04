# Rehab monitor

<!-- impeccable:product-schema 1 -->

## Platform

android

## Users and purpose

People checking wearable sensor readings during rehabilitation on an Android phone.
Connect to ESP32 over local Wi-Fi and inspect thigh, shin and heel readings.
A separate sample dashboard illustrates exercise session review.

## Capabilities and constraints

Flutter Android live sensor readings with Python embedded in the APK. ESP32 streams
thigh/shin IMU readings and heel ADC over local Wi-Fi; show readings and a ten-second
heel ADC graph. Foreground sessions only, with no auth or persistence. Calibration,
validated repetitions, knee angle/ROM and live accuracy are a later milestone.
Keep sample session review clearly distinct from actual live readings.
Current sample: seated knee extension 16/20; supported sit to stand 12/16.
Combined sample: 28/36, rounded to 78%. Preserve the current visual direction.
Live Python/Wi-Fi support targets Android first; other Flutter platforms can
still display the sample dashboard.

## Brand commitments

User requests a white theme, real shader gradient with fine grain, new typography
and logo treatment, consistent library icons, and mobile-first alignment.
No emojis or repetitive decorative pills. The existing dark UI is rejected.
