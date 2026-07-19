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
- **Quick Bolus** — Home Screen small/medium. Same flow as the Garmin remote: tap the **Units /
  Carbs** label to switch modes, **set the amount** with **− / +** (step = your iPhone bolus/carb
  increment; units clamped to the pump's max, carbs to 200 g), tap **Bolus**, then confirm with a
  **1 → 2 → 3** sequential tap (a wrong/late tap within 20 s resets). In carbs mode the app converts
  to units with the pump's calculator before delivering. Completing it delivers **in place**: the
  widget shows **Delivering… + a Cancel button**, then **Delivered X.XX U** (auto-returns to the
  amount screen after a few seconds). There is **no preset amount** and it does **not** open the app.

    Under the hood the widget hands the confirmed dose to the app over the App Group and a Darwin
    notification; the app (kept alive in the background by its `bluetooth-central` connection)
    delivers through the validated signed path and writes progress back to the widget. If the pump
    isn't connected, the widget shows **"Pump not connected — open app."**

!!! danger "Quick Bolus is a real delivery"
    Completing 1-2-3 delivers the preset dose (bench/saline only). It is not a shortcut into the
    entry screen — treat it like the Garmin hold-to-deliver. It only works while the app is running
    with the pump connected (typically in the background); otherwise open the app first.

## Setup
Long-press the Home Screen (or Lock Screen → Customize) → add widget → **ControlX2**. On device,
the App Group capability must be enabled once on the app + widget targets (automatic signing
registers it; the entitlements are generated from `project.yml`).

!!! note "Freshness"
    Widgets update when the app publishes (every pump update) and on WidgetKit's own schedule.
    If the app hasn't run recently, a widget may show a stale/`--` value with its age.
