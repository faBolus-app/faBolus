# Plan — Independent Apple Watch (direct-to-pump)

Goal: let the Apple Watch connect to the pump **over its own Bluetooth** and read status + deliver
boluses **without the iPhone present**, as an option alongside the current iPhone-relay mode.
Experimental — in development.

## The hard constraint: one pairing at a time (re-pair to switch)
The pump stores **one pairing at a time** — pairing a new device **evicts** the previous device's
pairing (confirmed in testing, and it's why t:connect must be unpaired to use faBolus). So
"independent watch" is **not** phone + watch both controlling the pump, and it isn't even a live
handoff between two paired devices. It's an **either/or**:

- Whichever device you **paired last** (with a fresh code) is the one that can talk to the pump.
- Pairing the **watch** evicts the **phone** (the phone app must re-pair, with a new code, to use the
  pump again) — and vice-versa.

This *simplifies* the software (no simultaneous-connection arbitration to build) but makes switching
a deliberate, manual **re-pair with a new code** each time. The design centers on making that
re-pair fast and obvious, not on juggling two live connections.

## Authentication: the watch must pair itself (code entry on the watch)
The pump issues a **fresh 6-digit pairing code for every device pairing**, and the derived secret is
bound to that pairing. So the phone **cannot** hand its secret to the watch — the earlier
`keyShare`/`pumpKeyHex` idea (share the phone's derived secret, resume-auth on the watch) is **not
viable** and is superseded by this section. The watch must run its **own full JPAKE pairing**:

1. On the pump, generate a new pairing code (Options → Device Settings → Bluetooth → Pair Device).
2. **Enter that code on the Apple Watch**, and the watch runs JPAKE directly with the pump to derive
   **its own** secret, stored in the watch Keychain.
3. Thereafter the watch **resume-auths** with its stored secret (no code re-entry) on every connect —
   exactly like the phone does today.

Code entry is a **one-time** step per pairing session; the recurring path is resume-auth — until you
pair the *other* device, which evicts this one and forces a re-pair here next time. This makes the
watchOS crypto spike harder: the watch must run the **full JPAKE key exchange**, not just resume.

## Phases

### Phase 0 — Feasibility spikes (de-risk first)
- **Crypto on watchOS:** ✅ **compiles** — `PumpX2Messages`, `PumpX2Auth` (full JPAKE + mbedTLS EC-JPAKE
  C sources, minimal config), and `PumpX2BLE` all build for `generic/platform=watchOS` (2026-07-19).
  The package already declares `.watchOS(.v9)`. The feared mbedtls-won't-target-watchOS risk did **not**
  materialize, so no CryptoKit/Swift-JPAKE fallback is needed. Still to verify on-device: JPAKE actually
  completing a pairing over BLE (runtime, needs a watch + pump).
- **CoreBluetooth on the watch:** builds; still need to confirm at runtime that `CBCentralManager` on a
  **physical** Apple Watch discovers + connects the pump (range/throughput are lower than iOS).
- **Pairing model:** ✅ confirmed in testing — the pump keeps **one** pairing; pairing the watch
  evicts the phone (re-pair-to-switch). No further spike needed here.

### Phase 1 — On-watch pairing UI + storage ✅ (built, pending on-device test)
- ✅ `PumpX2Kit` (Messages/Auth/BLE) wired into the watch app target.
- ✅ `WatchPumpClient` (`watch/faBolusWatch/WatchPumpClient.swift`): scans → connects → runs the
  full JPAKE pairing with the 6-digit code, or resume-auths from the stored secret; exposes a
  `PairState` (idle/connecting/pairing/paired/failed).
- ✅ `WatchPairingStore` — the watch's own derived secret in the **watch Keychain** (separate service).
- ✅ UI: a **Direct** page (`WatchDirectView`) + a 6-digit **pairing sheet** (`WatchPairingView`) with
  Pair / Re-pair / Forget and live state.
- Retired the `keyShare`/`pumpKeyHex` handoff (pump needs a fresh code per device).
- **Pending:** the on-device run — enter a real code and confirm JPAKE completes over the watch's BLE
  (Phase 0's runtime check happens naturally here).

### Phase 2 — Watch pump client
- Add `PumpX2Kit` (Messages/Auth/BLE) as watch-app dependencies.
- `WatchPumpClient` mirroring `LivePumpDataSource`: connect → resume-auth with the shared secret →
  poll status, deliver signed bolus, dismiss alerts. Reuse the exact signed path (byte-verified).
- The watch's existing views bind to either the relay model or the direct client behind a protocol.

### Phase 3 — Mode + switching (no live arbitration needed)
Because only one device is ever paired, there's **no simultaneous-connection arbitration to build** —
whichever paired last owns the pump. What's needed is a clear switch:
- Watch setting: **Direct to pump** vs **iPhone relay** (default). Choosing Direct starts the on-watch
  pairing (Phase 1); the phone shows a "Watch is now paired — re-pair the phone to use it here" banner.
- Both apps surface **who is paired now** and offer a one-tap "Re-pair this device" (with the fresh
  code) so switching back is fast and obvious.
- Optional nicety: since it's either/or, the relay path and the direct path are mutually exclusive at
  runtime — the watch uses the direct `WatchPumpClient` when paired, else falls back to relay.

### Phase 4 — Reliability / background
- watchOS `bluetooth-central` background mode + reconnect/backoff on the watch (background BLE is
  more restricted than iOS; foreground operation is the reliable baseline for the PoC).
- Battery budget: the watch polling + BLE is heavier than relay; tune the cadence.

### Phase 5 — Validation
- Saline on a scale. Re-run the oracle byte-exactness for signed messages generated on the watch.
- Edge cases: re-pair round-trips (watch↔phone) with fresh codes, watch out of range mid-bolus,
  resume-auth after the watch app is killed, pump eviction mid-session (the other device was paired).

## Risks / open questions
- **JPAKE/crypto on watchOS** — ✅ retired: all three modules (incl. mbedTLS EC-JPAKE C) compile for
  watchOS. Remaining is runtime-only (JPAKE completing over the watch's BLE).
- **Re-pair friction** — ✅ single pairing (watch evicts phone). Switching devices always means a
  fresh code entry; the UX must make that fast, or the watch mostly stays the paired device.
- **On-watch code entry** — a usable 6-digit input on a tiny screen (crown picker vs number pad).
- **watchOS BLE** — range, throughput, background limits, battery.
- **Safety** — direct delivery keeps every guard: max-bolus clamp, the deliberate confirm, the
  deliberate confirm, and the validated signed path. No new dosing path bypasses these.

## Status
- ✅ **Phase 0 build spike:** Messages/Auth/BLE compile for watchOS. Pairing model confirmed
  (single pairing, re-pair to switch).
- ✅ **Phase 1 built:** PumpX2Kit wired into the watch; `WatchPumpClient` (JPAKE pair + resume) +
  `WatchPairingStore` (Keychain) + Direct page & pairing sheet. Compiles for watchOS.
- **Next:** run it on a physical watch (enter a real code → JPAKE completes over watch BLE). Then
  Phase 2 (`WatchPumpClient` status polling + signed delivery), Phase 3 (relay↔direct switch UX).
