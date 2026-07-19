# ControlX2 Garmin remote (Connect IQ / Monkey C)

A thin remote that relays bolus commands to the ControlX2 **iPhone host** over the Connect IQ
mobile SDK. It never touches the pump — the phone runs the confirm interlock and dispatches via
`PumpX2Kit`. Bench PoC (saline only).

## Structure
- `manifest.xml` — app id, products, `Communications` permission.
- `monkey.jungle` — build config.
- `source/`
  - `ControlX2App.mc` — entry; registers the phone-message listener (receives `bolusStatus`).
  - `BolusView.mc` — Loop-style units picker + status; `BolusState` module holds UI state.
  - `BolusDelegate.mc` — UP/DOWN adjust units, START/ENTER sends a units-only `bolusRequest`.
  - `RemoteComm.mc` — builds command dictionaries matching `../schema/command.schema.json`
    (v1) and transmits to the phone.
- `resources/` — strings + drawables.

## Contract
Commands mirror `schema/command.schema.json` and `Shared/RemoteCommand.swift` exactly (kind,
requestId, units, …). Keep all three in lockstep — this shared schema is the reason the Garmin
app lives in the ControlX2iOS repo.

## Build (requires the Connect IQ SDK — not included)
1. Install the Connect IQ SDK and a developer key.
2. Add a `resources/drawables/launcher_icon.png` (see `drawables.xml`).
3. `monkeyc -f monkey.jungle -o ControlX2.prg -y <developer_key.der>`
4. Run in the Connect IQ simulator or sideload to a compatible watch, and pair with the
   ControlX2 iPhone app.

> Not yet compiled here (no Connect IQ SDK in this environment). The double-confirmation,
> out-of-range handling, and schema parity match the Apple Watch remote.
