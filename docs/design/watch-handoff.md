# Handoff — Apple Watch install + independent pairing (paused 2026-07-19)

Where the Apple Watch work stands, so anyone can pick it up. Two threads: (A) getting the watch app
**installed** on the physical watch, and (B) the **independent direct-to-pump** watch. All code is
committed and compiles; the block is device/account setup, not code.

## Environment facts
- **Watch:** Apple Watch **Series 4** (`Watch4,1`), **watchOS 10.6.2** (build 21U594). App min target
  is 10.0 → compatible.
- **iPhone:** iPhone 13 mini, UDID `00008110-001244692280A01E`, **registered** for dev.
  devicectl id `55BB0EAB-1D34-5EA9-9A42-7C707C88BCCA`. Dev team `4AA4WP5Q4S`.
- The **watch is NOT a registered dev device** — the `com.zgranowitz.controlx2.watch` provisioning
  profile contains only the iPhone UDID. A dev-signed app can't install until the watch's UDID is
  registered (happens when Xcode "prepares" the watch).
- **App Group is NOT enabled** on either watch App ID (`com.zgranowitz.controlx2.watch` and
  `…watch.widgets`) — checked the profiles; both have no `application-groups`.

## A. Install status
- The watch app is **embedded as a companion** in the iPhone app
  (`WKCompanionAppBundleIdentifier=com.zgranowitz.controlx2`, watch id `com.zgranowitz.controlx2.watch`).
  Installing the iPhone app carries the watch app in `ControlX2.app/Watch/` — a physical watch is not
  a CLI install target, so this is the delivery path.
- **Fixed:** the watch app had **no app icon**, so watchOS rejected the install (iOS is lenient).
  Added `watch/ControlX2Watch/Assets.xcassets` (single 1024 `AppIcon`) +
  `ASSETCATALOG_COMPILER_APPICON_NAME`. Bundle now has `Assets.car` + `CFBundleIcons`.
- **Blocker 1 — watch not prepared for dev.** In Xcode → Devices & Simulators, "Preparing for
  development / Copying shared cache symbols" **hung**. Root cause: **low disk** (was 6.2 GB free).
  Cleared regenerable caches (iOS DeviceSupport 5.5 GB, DerivedData, local build dirs, the partial
  `Watch4,1 10.6.2` symbol folder, unavailable simulators) → **~14 GB free** now. Retry with the
  **watch on its charger + screen kept awake** (sleeping restarts the copy). ~4 GB more available via
  `xcrun simctl delete all` if needed.
- **Blocker 2 — signing.** Once the watch is prepared (UDID registered), **rebuild** so automatic
  signing adds the watch UDID to the profile, then reinstall.

### Finish the install (after the watch is prepared)
```
cd ControlX2iOS
xcodebuild -project ControlX2.xcodeproj -scheme ControlX2 -destination 'generic/platform=iOS' \
  -configuration Debug -allowProvisioningUpdates DEVELOPMENT_TEAM=4AA4WP5Q4S -derivedDataPath build/DD build
xcrun devicectl device install app --device 55BB0EAB-1D34-5EA9-9A42-7C707C88BCCA \
  build/DD/Build/Products/Debug-iphoneos/ControlX2.app
```
Or simplest: in Xcode pick the **ControlX2Watch** scheme + the watch and **Run** (registers + installs
in one go). Watch compile-check: `-scheme ControlX2Watch -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO`.

## B. Independent (direct-to-pump) watch — see `independent-watch.md`
- **Pump keeps ONE pairing**; pairing a new device **evicts** the old (confirmed). So it's
  re-pair-to-switch, not simultaneous — the watch runs its **own** JPAKE pairing (code entered on the
  watch). The `keyShare`/`pumpKeyHex` handoff idea is **dead** (superseded).
- **Phase 0 ✅ (build):** `PumpX2Messages`, `PumpX2Auth` (full JPAKE + mbedTLS EC-JPAKE C), and
  `PumpX2BLE` all compile for watchOS. The crypto risk is retired. **Runtime untested** (JPAKE over
  the watch's BLE) — happens naturally the first time the app runs on the watch.
- **Phase 1 ✅ (built, untested on device — blocked by the install above):**
  - `watch/ControlX2Watch/WatchPumpClient.swift` — scans/connects the pump over the watch's own BLE,
    runs the full JPAKE pairing with a 6-digit code, or resume-auths from the stored secret; exposes
    `PairState`.
  - `watch/ControlX2Watch/WatchPairingStore.swift` — the watch's own derived secret in the watch
    Keychain (service `com.zgranowitz.controlx2.watch.pairing`).
  - `WatchDirectView` (5th page) + `WatchPairingView` (6-digit sheet): Pair / Re-pair / Forget.
  - PumpX2Kit wired into the watch target in `project.yml`.
- **First on-device test:** pump → new pairing code; watch → **Direct → Pair to pump** → enter code →
  expect **"Paired!"** (this **evicts the iPhone's pairing** — re-pair the phone afterward). That both
  confirms Phase 0 runtime and validates Phase 1.
- **Next (Phase 2):** promote `WatchPumpClient` to poll status + deliver the **signed** bolus directly
  (reuse the byte-verified path), so Glance/Chart/Details/Bolus/Alerts run off the direct link.
  **Phase 3:** relay↔direct switch UX. See `independent-watch.md` for the full plan.

## C. Complication (glucose on the watch face) — temporarily removed
- Built but **un-embedded** for now: `watch/ControlX2WatchWidgets/GlucoseComplication.swift` (widget
  extension) reads the App Group snapshot the watch app publishes (`WatchModel.publishComplication`).
- Removed from the build because the **App Group isn't registered** on the watch App IDs (signed
  builds fail on it). To restore: in Xcode, enable App Group `group.com.zgranowitz.controlx2` on
  **ControlX2Watch** + **ControlX2WatchWidgets** (Signing & Capabilities — registers it on the App
  IDs; persists through XcodeGen regen), then in `project.yml` re-add the watch App Group entitlement
  + re-add `- target: ControlX2WatchWidgets` to the watch app's dependencies, regenerate, rebuild.

## What the watch app already does (parity work, done earlier)
Paged UI: **Glance · Chart · Details · Alerts · Direct**. Carbs/Units bolus with watch increments +
on-watch confirm → phone delivers directly. `WatchModel` mirrors the full status payload. All via the
iPhone relay today; the Direct page is the entry point for the independent path.
