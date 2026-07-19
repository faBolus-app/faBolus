# ControlX2iOS — Roadmap (accumulated requests)

Working order agreed with the user: **1 → 2 → 3 → 4**, then the rest. Each step is built,
installed, and pushed before moving on.

## 1. Fix alert clearing (in progress)
Clearing an alert (phone or watch) doesn't clear it on the pump.
- Surface the pump's dismiss-ack status prominently (phone + watch) so we can tell whether the
  pump **rejects** the signed dismiss (status ≠ 0 → signing/opcode issue) or **accepts** it
  (status 0 → the alert is condition-based and re-raises, e.g. a high-glucose alert while BG is
  still high).
- Re-verify the `DismissNotificationRequest` cargo/opcode/kind/id + signed path vs controlX2.
- Reduce the **watch alert delay**: the phone already pushes on change; also poll alerts on a
  tighter cadence and push immediately when the alert set changes (balance vs battery).

## 2. iOS tab bar + Settings + bolus defaults/increments
- Bottom **TabView** (modern iOS): **Dashboard · Bolus · Alerts · Settings**.
- **Dashboard** scrolls: HUD (glucose ring, chart, pills) then a details section with everything
  from the pump (correction factor/ISF, carb ratio, target, max bolus, reservoir, battery, CGM
  status, last bolus, pump time).
- **Settings** (persisted, shared to remotes via the App Group / status payload):
  - Default bolus entry mode: **Carbs** (new default) or Units.
  - **Bolus increment**: 0.01 / 0.05 / 0.1 / 0.5 / 1 / 2 U.
  - **Carb increment**: 1 / 5 / 10 / 15 g.
  - (Y-axis toggles from step 3 live here too, or on the chart.)
- Apply the default mode + increments in the iOS bolus entry; propagate to Garmin + Apple Watch
  (default mode on open, +/- step = the chosen increment). Apple Watch gains a Carbs mode.

## 3. Phone chart: IOB overlay + bolus bars
- Second **y-axis = Insulin on Board** over time, drawn as an overlay line.
- Vertical **bolus bars** at each bolus time, height ∝ units.
- Both y-axes (glucose + IOB) individually **toggle on/off**.
- Sourcing IOB history: accumulate the polled IOB into a time series; bolus markers from the
  bolus history (history-log bolus events, or the last-bolus stream).

## 4. Bluetooth reliability
- More robust connect/reconnect: retry with backoff, restart scanning if a pending connect
  stalls, recover from transient GATT errors, and verify state-restoration wake paths.
- Reduce spurious "Disconnected" flicker; keep the pending-connect alive across app states.

## 5. Siri (App Intents) — CarPlay dropped
- **CarPlay is not feasible**: it requires an Apple-granted entitlement limited to specific app
  categories (audio, nav, EV, food, …); a bolus/medical app can't get it, so a CarPlay app
  can't be built or installed. Dropped.
- **Siri**: App Intents for view/bolus. Bolusing via Siri **gated to CarPlay-connected state**
  only (checked at intent runtime); otherwise view-only. Safety-sensitive + untested — treat as
  bench-only and require an explicit confirm.

## 6. Garmin: configurable screen order + default screen
- A setting (phone-side, pushed to the watch) to choose the **default screen** (glance / history
  / alerts / details) and the **swipe order** of the screens.

## 7. Docs + build instructions (LoopDocs-style site)
- Refresh the mkdocs site for all of the above (tabs/settings, IOB overlay, Siri, Garmin config).
- Add a **Building & installing** guide: toolchain (Xcode + XcodeGen, Connect IQ SDK, JDK for the
  oracle), signing/team + App Group capability, `xcodebuild`/`devicectl` device install, building
  and beta-uploading the Garmin `.iq`, and running PumpX2Kit tests against the oracle.

## Deferred / notes
- Apple Watch full parity (history plot, details screen) if wanted.
- The signed dismiss path and all delivery paths remain **bench-only, saline, not on a body.**
