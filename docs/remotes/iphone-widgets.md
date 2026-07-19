# iPhone widgets

A WidgetKit extension (`ios/ControlX2Widgets/`) surfaces pump data on the Lock Screen and Home
Screen. Widgets read the last snapshot the app publishes to a shared **App Group**
(`group.com.zgranowitz.controlx2`) — they can't drive Bluetooth themselves, so they show the
last published value and hide any reading older than 6 minutes.

## Widgets
- **Glucose** — Lock Screen (`inline`, `circular`, `rectangular`) + Home Screen small. Current
  glucose + trend arrow, range-colored.
- **Pump Overview** — Home Screen medium: glucose trend + a sparkline, Active Insulin, reservoir,
  last bolus.
- **Bolus** — Home Screen small + Lock Screen circular. A shortcut that opens the app's
  bolus-entry + confirm flow (`controlx2://bolus`); it never dispenses from the widget itself.
- **Quick Bolus** — Home Screen small/medium. Delivers a **preset** dose gated by the same
  **1-2-3** sequential-tap confirm the Garmin uses. Tap **1 → 2 → 3 in order**; a wrong or late
  tap (20 s) resets. The final tap opens the app, which delivers through the validated signed path
  and shows progress + cancel — the widget can't drive Bluetooth and never dispenses headlessly.
  Set the preset in **Settings → Home-Screen widget → Quick-bolus amount**.

!!! danger "Quick Bolus is a real delivery"
    Completing 1-2-3 delivers the preset dose (bench/saline only). It is not a shortcut into the
    entry screen — treat it like the Garmin hold-to-deliver.

## Setup
Long-press the Home Screen (or Lock Screen → Customize) → add widget → **ControlX2**. On device,
the App Group capability must be enabled once on the app + widget targets (automatic signing
registers it; the entitlements are generated from `project.yml`).

!!! note "Freshness"
    Widgets update when the app publishes (every pump update) and on WidgetKit's own schedule.
    If the app hasn't run recently, a widget may show a stale/`--` value with its age.
