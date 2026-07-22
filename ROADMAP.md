# faBolus — Roadmap (accumulated requests)

Working order agreed with the user: **1 → 2 → 3 → 4**, then the rest. Each step is built,
installed, and pushed before moving on.

## 1. Fix alert clearing (done — pending one ack readout)
Clearing an alert re-surfaced on the next poll because *condition-based* alerts (e.g. a CGM high
while BG is genuinely still high) are re-raised by the pump every poll.
- **Local acknowledge/snooze**: tapping Clear hides the alert (and stops re-notifying) until the
  pump condition actually clears (the bit drops) or a 30-min re-nag window elapses — matching how
  a CGM app behaves. Truly-dismissable alerts still clear on the pump and don't return. ✅
- **Durable dismiss-ack**: the `DismissNotificationResponse` status is kept on the Alerts
  diagnostic (`· ack N (accepted/rejected)`) so a subsequent poll can't clobber it before it's
  read. Confirms accepted (condition-based) vs rejected (signing). ✅ (awaiting one on-device read)
- Watch alert delay reduced via the 15 s alert poll + push-on-change. ✅

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

## 5. Siri (App Intents) — CarPlay dropped (read-only done)
- **CarPlay is not feasible**: it requires an Apple-granted entitlement limited to specific app
  categories (audio, nav, EV, food, …); a bolus/medical app can't get it, so a CarPlay app
  can't be built or installed. Dropped.
- **Siri (read-only)** ✅ — App Intents + `AppShortcutsProvider` for **glucose**, **insulin on
  board**, **pump status**, and **last bolus**. Each reads the App Group snapshot (same data as
  the widgets), runs without opening the app, and speaks a dialog. See
  `ios/faBolus/Intents/StatusIntents.swift`.
- **Voice bolus is intentionally out of scope**: per the safety rule, dosing is CarPlay-only, and
  CarPlay can't be built — so there is no Siri bolus intent. Revisit only if CarPlay becomes
  possible (with its touchscreen 1-2-3 confirm gate).

## 5b. Bolus from an iPhone widget (1-2-3 confirm) ✅
- Interactive Home-Screen **Quick Bolus** widget (App Intents) delivering a preset dose, gated by
  the same **1-2-3 sequential tap** the Garmin uses (1→2→3 in order; a wrong/late tap within 20 s
  resets). Steps 1-2 advance App Group state headlessly; the final tap opens the app and, only if
  1→2 completed, hands off a pending bolus the app delivers via `remoteDeliver` (the validated
  signed path, with progress + cancel). Preset amount in Settings.
- Files: `Shared/WidgetShared.swift` (WidgetBolusStore/Request), `ios/faBolusWidgets/
  WidgetBolusIntents.swift` + `QuickBolusWidget.swift`, consume hook in `App.swift`.

## 6. Garmin: configurable screen order + default screen ✅
- Phone setting (**Settings → Garmin remote → Screen order**): reorder the swipe screens (glance /
  alerts / history / details) and pick which opens first. Pushed in the status payload
  (`screenOrder` + `defaultScreen`); the Garmin app persists it (Storage) so it survives restarts
  and offline launches.
- Garmin nav refactored from a fixed push/pop stack to a **carousel** (`switchToView`) driven by
  `AppState.screenOrder`; `getInitialView` opens `AppState.defaultScreen`. See `garmin/source/Nav.mc`.

## 7. Docs + build instructions (LoopDocs-style site)
- Refresh the mkdocs site for all of the above (tabs/settings, IOB overlay, Siri, Garmin config).
- Add a **Building & installing** guide: toolchain (Xcode + XcodeGen, Connect IQ SDK, JDK for the
  oracle), signing/team + App Group capability, `xcodebuild`/`devicectl` device install, building
  and beta-uploading the Garmin `.iq`, and running PumpX2Kit tests against the oracle.

## Deferred / notes
- Apple Watch full parity (history plot, details screen) if wanted.
- The signed dismiss path and all delivery paths remain **experimental / in development.**

### Chained remotes (parent's own Watch/Mac → parent phone → child host) — designed, NOT enabled
The iPhone-to-iPhone remote ships; driving the child host from the parent's *own* Apple Watch or Mac
(relayed through the parent phone) is deferred because it can't be done safely without on-device
testing across 3 devices, and the naïve wiring risks the shipped watch↔host path. Concrete blockers:
- **Single `WCSession`:** a second WatchConnectivity host on the parent phone would steal the delegate
  from the app's `PhoneRemoteHost`, and `addRemoteEcho`/`addStatusListener` aren't removable (they'd
  leak/duplicate). Needs removable listeners + a single host whose target switches.
- **CoreBluetooth one-restore-id-per-central:** relaying to the child means a *second* restorable
  central alongside the pump central → the documented SIGABRT risk (`DexcomG6BLESource` note).
- **Safe path:** a `RelayBackend: PumpBackend` that forwards to the child over the existing
  `SealedTransport`/`BLELink` and maps relayed status into `PumpSnapshot`. Then the parent phone's
  existing `AppModel` + all its leaves (watch/Garmin/Mac/widgets) work unchanged, sourcing the child.
- Already free today: the parent watch's glucose **complication** reflects the child while the parent
  phone is on the remote screen (`RemoteClientModel.publishSnapshot` → App Group).

### Apple Watch host / phone-as-remote swap (tracked, not started)
Make the **watch the pump host** and the **phone a remote**. The pump allows only one paired
controller (see `docs/setup/pairing.md`), so this is a full re-pair that evicts the phone — not a
quick toggle. Ties into the existing untested **Phase-1 direct-pump** scaffold
(`watch/faBolusWatch/WatchPumpClient.swift`, `WatchDirectView.swift`). Work required:
1. **Phase 2 watch backend** — port `TandemBackend`'s tiered polling + signed
   `deliverBolus`/`cancelBolus`/`dismissNotification` + snapshot building into `WatchPumpClient`
   (the `PumpX2BLE`/`PumpX2Auth`/`PumpX2Messages` libs already run on watchOS unchanged).
2. **Reverse the relay** — the watch becomes the `statusCommand` producer / `remoteDeliver`
   executor / echo source; iOS becomes a `RemoteClientModel` consumer. `RemoteLink`
   (WatchConnectivity) has no host/remote role today (cf. `PeerLink.Role`) — add one.
3. **Single-pairing eviction UX** — pairing the watch unpairs the phone; add a clear hand-off flow.
4. **On-device host testing** — validate the watch-hosted signed delivery path (extends the
   currently-untested Phase-1 direct-pump work).
   Files: `watch/faBolusWatch/WatchPumpClient.swift`, `ios/faBolus/Data/TandemBackend.swift`,
   `Shared/RemoteClientModel.swift`, `Packages/faBolusCore/.../RemoteCommand.swift`.
