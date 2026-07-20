# Apple Watch remote

A Loop-style remote at parity with the phone + Garmin. **The watch never touches the pump** —
`PumpX2Kit` runs on the iPhone; the watch relays commands over WatchConnectivity.

## Screens (swipe between pages)
- **Glance** — big glucose + trend (hidden when stale), IOB, reservoir, alert count, iPhone
  reachability, and the **Bolus** button.
- **Chart** — a Loop-style glucose history plot (the recent readings the phone sends).
- **Details** — active insulin, reservoir, battery, CGM, last bolus, carb ratio, correction
  factor, target, max bolus, connection (matches the phone details card).
- **Alerts** — active pump alerts/alarms, each with **Clear** (relayed to the phone's signed
  dismiss). Notes when a CGM alert is condition-based.

## Bolus
- Tap **Bolus**, pick **Carbs** or **Units** (default from Settings), set the amount with the
  **Digital Crown** (step = the *Watch & Garmin* increment from Settings), then **Bolus**.
- Confirm on the watch (a deliberate saline/bench confirmation). The iPhone then delivers
  **directly** through the validated signed path — like the Garmin remote — converting carbs to
  units with the pump's calculator. You can **Cancel** while it's delivering.
- If the iPhone is out of range, the request is queued/failed cleanly — never silently delivered.

The watch honors its own bolus/carb increments and default mode, set in **iPhone Settings →
Watch & Garmin increments** and **Default mode**.

## Contract
Phone↔watch messages follow [`schema/command.schema.json`](../architecture.md): a tiny JSON
contract (`kind`, `requestId`, `units`, `confirmToken`, `status`, …). The Swift mirror is
`Shared/RemoteCommand.swift`; transport is `Shared/RemoteLink.swift`.
