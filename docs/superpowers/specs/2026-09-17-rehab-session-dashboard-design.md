# Rehab Session Dashboard Design

## Goal

Create the first mobile Flutter mock screen for a sensor-assisted rehabilitation app. The screen communicates session completion clearly before real sensor connectivity exists.

## Scope

- One mobile-first session dashboard.
- Mock session: two exercises, each showing correct repetitions out of total repetitions.
- Overall completion summary, percentage, duration, and exercise count.
- Exercise list with status icon, progress bar, and correct/total copy.
- Bottom navigation shell with Home selected and inactive Progress/Profile destinations.
- White theme with charcoal text, teal primary, pale mint surfaces, and restrained lavender accent.

Out of scope: sensor/Bluetooth APIs, live data, backend, login, persistence, charts, and additional screens.

## Architecture

Use a single `MaterialApp` and a focused `HomeScreen` backed by immutable local mock data. Flutter Material 3 supplies layout primitives, typography, icons, progress indicators, navigation, and accessibility semantics; no external package is required for this mock.

## Interaction

The mock is read-only. Bottom navigation is visually present and tappable, with a small selected-index state so the shell feels real without inventing unfinished screens. Exercise rows are not interactive until sensor-backed drill-down exists.

## Visual Direction

Use safe-area-aware vertical scrolling, compact 8-point spacing, cards with moderate corner radii, light borders, and shallow elevation. The visual hierarchy is: greeting/session context → overall completion → exercise-by-exercise evidence → next-step action. Use Material icons rather than custom drawn assets.

## Accessibility and Verification

Use semantic labels for icon-only controls, sufficient contrast, visible text for all metrics, and minimum comfortable tap targets. Verify with `flutter analyze` and `flutter test`.

