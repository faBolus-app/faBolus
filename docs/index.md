# ControlX2iOS

An **independent, open reimplementation** of a Tandem **t:slim X2 / Mobi** remote-control app
for iPhone, with Apple Watch and Garmin remotes. It speaks the pump's Bluetooth protocol
(reverse-engineered by the [pumpX2](https://github.com/jwoglom/pumpx2) project) to read status
and deliver **manual boluses** — it is **not** an automated closed-loop system.

!!! danger "Bench proof-of-concept — not for therapy"
    This project is a **bench proof-of-concept**. All testing uses a **dedicated test pump
    dispensing saline into a container on a scale — never on a body.** On-body use is
    explicitly out of scope. The dosing path is our own reimplementation and is treated as
    unproven until exhaustively validated (see [Safety](safety.md)).

!!! warning "Not affiliated"
    Not affiliated with, endorsed by, or a fork of Tandem Diabetes Care, jwoglom's
    `controlX2`/`pumpX2`, or Loop/LoopKit. "ControlX2iOS" simply names the iOS sibling of the
    Android `controlX2` reference. The UI borrows Loop's visual language for familiarity only.

## What it does
- Connects to one pump at a time over Bluetooth (exclusive control connection), with
  **auto-reconnect** on range drops and CoreBluetooth **state restoration**.
- A **tabbed UI** (Dashboard · Bolus · Alerts · Settings). The Dashboard shows a Loop-style HUD —
  glucose with trend + a chart (3/6/12/24 h) with an optional **IOB overlay** and **bolus bars**
  (toggleable axes) — and scrolls to a details card with everything from the pump (carb ratio,
  correction factor/ISF, target, max bolus, reservoir, battery, CGM, last bolus).
- A CGM reading older than **6 minutes** is hidden so a stale value is never shown as current.
- **Settings**: default bolus mode (carbs/units) and bolus/carb increments, shared with the
  Apple Watch and Garmin remotes.
- Backfills the glucose chart from the pump's **history log** on each connect.
- Delivers a **manual (units) or carbs bolus** (the pump's calculator formula) with an explicit
  confirm and a max-units clamp; cancels in-progress and reports partial delivery.
- Views and **clears pump alerts/alarms** (a signed dismiss) — from the phone and the watch.
- **iPhone widgets** (Lock Screen + Home Screen): glucose, an overview, a bolus shortcut, and a
  **Quick Bolus** widget that delivers a preset dose behind a Garmin-style **1-2-3 confirm**.
- **Siri** (read-only): ask for glucose, insulin on board, pump status, or the last bolus. Voice
  bolusing is intentionally excluded (dosing stays a deliberate, confirmed action).
- Accepts boluses from an **Apple Watch** or **Garmin** remote (double-confirmed); the Garmin
  also has a glucose **complication**, a Dexcom-style history screen, and a details screen.

## The two repositories
- **[PumpX2Kit](https://github.com/zgranowitz/PumpX2Kit)** — the Swift protocol/auth/BLE core
  (message framing, HMAC signing, legacy + JPAKE pairing, Core Bluetooth). Validated
  byte-exact against the pumpX2 `cliparser` oracle.
- **ControlX2iOS** (this repo) — the iOS host app, watch remote, Garmin remote, and the
  phone↔remote command schema. Consumes `PumpX2Kit`.
