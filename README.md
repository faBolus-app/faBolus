# ControlX2iOS

iOS host app plus smartwatch remotes (Apple Watch and Garmin Connect IQ) for **remote
bolusing** and status viewing on a Tandem **t:slim X2 / Mobi** pump. The iPhone owns the
pump's BLE connection (via [`PumpX2Kit`](../PumpX2Kit)); the watches are thin remotes that
relay confirmed commands to the phone.

> [!WARNING]
> **Independent, unofficial reimplementation — a bench proof-of-concept.** This is **not**
> a fork of, affiliated with, or endorsed by Tandem Diabetes Care or jwoglom's `controlX2`
> project. The name mirrors `controlX2` only to signal the parallel (`PumpX2Kit` ↔ pumpX2,
> `ControlX2iOS` ↔ controlX2). All testing is on a **dedicated test pump dispensing saline
> into a container on a scale — never on a body.**

## Layout

```
ios/ControlX2/        # iOS host app — owns the pump connection, full UI (Milestone 2)
ios/ControlX2Widgets/ # WidgetKit extension — Lock Screen + Home Screen widgets + tap-to-bolus
watch/                # watchOS target — iPhone-hosted remote (Milestone 3), standalone (Milestone 4)
garmin/               # Connect IQ (Monkey C) remote + BG complication (Milestone 2)
schema/               # THE phone ↔ watch/garmin message contract — single source of truth
docs/                 # architecture + bench notes
```

### iPhone widgets (WidgetKit)

`ios/ControlX2Widgets/` provides three widgets that read a snapshot the app publishes to a
shared **App Group** (`group.com.zgranowitz.controlx2`):

- **Glucose** — Lock Screen (`accessoryInline`/`accessoryCircular`/`accessoryRectangular`, the
  row under the clock) + Home Screen small. BG + trend arrow, range-colored.
- **Pump Overview** — Home Screen medium: glucose trend + sparkline, Active Insulin, reservoir,
  last bolus.
- **Bolus** — Home Screen small + Lock Screen circular. A *link* into the app's bolus-entry +
  confirm flow (`controlx2://bolus`); it never dispenses from the widget.

Widgets can't drive Bluetooth, so they show the last value the app published (with an age when
stale). On device the App Group capability must be enabled on both the app and the widget target
(automatic signing usually registers it; the entitlements are generated from `project.yml`).

- `ios/` and `watch/` are targets in one Xcode project (standalone watchOS is a build
  config, not a separate repo).
- `garmin/` uses a different toolchain (Connect IQ SDK) but lives here so its message
  schema stays in lockstep with the iOS host — the whole reason to co-locate.
- Depends on `PumpX2Kit` via SPM (pin a released version).

## Status

Not started — blocked on `PumpX2Kit` Milestone 1 reaching its bench definition-of-done.
This repo is scaffold-only for now. Requires **full Xcode + a paid Apple Developer
account** (and, for `garmin/`, the Connect IQ SDK) to build.
