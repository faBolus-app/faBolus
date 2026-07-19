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
- Connects to one pump at a time over Bluetooth (exclusive control connection).
- Shows a **Loop-style status HUD**: recent glucose, Active Insulin (IOB), Active Carbs (COB),
  reservoir, battery, CGM status.
- Delivers a **manual (units) bolus** with an explicit confirm and a max-units clamp; a
  carbs/BG calculator flow is a follow-on.
- Cancels an in-progress bolus and reports partial delivery.
- Accepts bolus requests from an **Apple Watch** or **Garmin** remote, gated by a
  **double confirmation** (remote → phone).

## The two repositories
- **[PumpX2Kit](https://github.com/zgranowitz/PumpX2Kit)** — the Swift protocol/auth/BLE core
  (message framing, HMAC signing, legacy + JPAKE pairing, Core Bluetooth). Validated
  byte-exact against the pumpX2 `cliparser` oracle.
- **ControlX2iOS** (this repo) — the iOS host app, watch remote, Garmin remote, and the
  phone↔remote command schema. Consumes `PumpX2Kit`.
