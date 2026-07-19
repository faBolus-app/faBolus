# Garmin remote

A Connect IQ (Monkey C) companion for the **venu3s**. It's a **dumb remote**: it messages the
iPhone host via the **Connect IQ mobile SDK**; the phone runs the confirm interlock and
dispatches through `PumpX2Kit`. Source: `garmin/`.

## Screens (swipe up/down to move through them)
- **Glance** — current glucose + trend arrow (drawn, range-colored) and a **Bolus** button.
- **Alerts** — active pump alerts/alarms; **tap a row to clear** one.
- **History** — a Dexcom-style plot; **tap to cycle** the window 3 → 6 → 12 h.
- **Details** — Last bolus, Active Insulin, Reservoir, Battery, and an alert count.

### Reorder the screens / pick the default
The **order** of these screens and **which one opens first** are configurable from the phone:
**Settings → Garmin remote → Screen order**. Drag to reorder (Edit) and choose the screen that
opens first. The layout is sent to the watch on its next status update and is remembered on the
watch (it survives restarts and offline launches). Default order: Glance → Alerts → History →
Details, opening on Glance.

## Input model (venu3s)
The venu3s has two buttons and delivers screen taps as high-level events, so the app uses:

- **Tap** a button/target (bolus −/+, Deliver, numbered confirm, alert row).
- **Swipe up/down** to move between screens.

## Bolus flow
1. Open **Bolus**, tap the mode chip to switch **Units/Carbs**, tap **−/+** to set the amount,
   then **Deliver**.
2. On the confirm screen, **tap 1 → 2 → 3 in order** (like unlocking a t:slim). A wrong tap
   resets. Completing the sequence sends the bolus to the phone, which delivers it. The remote
   never delivers on its own; the pump still enforces its max and signing.

## Complication
The app publishes a **public BG complication** (value + trend arrow, no units) that Garmin
"Face It" faces and CIQ faces can show on the watch face. A reading older than 6 minutes shows
`--`. It updates while the app runs and via a background refresh (~5 min); it needs the iPhone
app open + connected for fresh data.

## Contract
The Monkey C side generates/validates against the same
[`schema/command.schema.json`](../architecture.md) as the Swift side — the shared schema is the
reason the Garmin app lives in this repo.

!!! note "Standalone Garmin is a separate project"
    Running the protocol **standalone on Garmin** (no phone) would require a full Monkey C
    reimplementation of protocol/crypto/BLE, tracked as a future repo (`PumpX2Garmin`), gated on
    whether Connect IQ's BLE can establish the bonded/authenticated connection the pump needs.
