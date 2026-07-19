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

## Blood-glucose complication (watch face)

The app publishes a **public Connect IQ complication** (`resources/complications/complications.xml`,
id 0) carrying the current glucose + a Latin-safe trend arrow (e.g. `124 ^`). Source:
`source/BgComplication.mc`, updated on every phone status reply and re-published on launch.

- Because it's `public`, Garmin **Face It** faces and CIQ watch faces that support complications
  can show it. Stock Garmin faces cannot display third-party CIQ data — pick a Face It or a CIQ
  face and add the *ControlX2 BG* complication to a field.
- A background service (`source/ControlX2Background.mc`, temporal event ~every 5 min) re-publishes
  the last-known reading and best-effort re-requests fresh data from the phone while the app is
  closed. Field reachability of background phone messaging varies; opening the app/glance is the
  reliable refresh path. Requires the `ComplicationPublisher` + `Background` permissions.
- The 34×34 icon must be an SVG for a public complication (`resources/drawables/bg_complication.svg`).

## iPhone-side bridge (Connect IQ iOS SDK)

The iOS host receives the venu3s app's messages via the **Connect IQ Mobile SDK for iOS**
(`ConnectIQ.xcframework`), mapping them to the same `RemoteCommand` the double-confirm host
handles (`ios/ControlX2/Data/GarminRemoteBridge.swift`).

- SDK (not committed — Garmin license): place at `~/Code/vendor/connectiq-companion-app-sdk-ios-1.8.0`
  (referenced by `project.yml` as a local SPM package at `../../vendor/...`).
- URL scheme `controlx2ciq` + `gcm-ciq` query scheme are in the generated Info.plist.
- Requires the **Garmin Connect Mobile** app installed and the watch paired to it.
- In the iOS app, tap the watch icon (top-right) → "Set up Garmin remote" to pick the device
  (opens Garmin Connect); the selection is remembered.
