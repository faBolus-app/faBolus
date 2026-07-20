# Plan — Independent Apple Watch (direct-to-pump)

Goal: let the Apple Watch connect to the pump **over its own Bluetooth** and read status + deliver
saline boluses **without the iPhone present**, as an option alongside the current iPhone-relay mode.
Bench proof-of-concept, saline only.

## The hard constraint: one control connection
The pump accepts **one authenticated control connection at a time** (the same reason t:connect must
be unpaired to use ControlX2). So "independent watch" does **not** mean phone + watch both driving
the pump at once. It means the watch can **take over** the connection when the phone is away
(a *handoff*). The design is built around arbitration, not simultaneous control.

## Two ways to authenticate the watch
1. **Key handoff from the phone (recommended, already scaffolded).** The phone does the JPAKE
   pairing (6-digit code from the pump screen), derives the shared secret, and sends it to the watch
   over WatchConnectivity. The watch then uses **resume-auth** (`PairingCoordinator(resumeDerivedSecret:)`)
   to authenticate directly — no code entry on the watch. Groundwork exists: `RemoteCommand.keyShare`
   + `pumpKeyHex` (schema + Swift mirror). This is the pragmatic path.
2. **Full pairing on the watch.** Enter the 6-digit code on the watch and run JPAKE there. Awkward
   input and competes with the phone/t:connect for the single pairing slot. Only if handoff proves
   unworkable.

## Phases

### Phase 0 — Feasibility spikes (de-risk first)
- **Crypto on watchOS:** confirm `PumpX2Auth` (JPAKE + HMAC-SHA1) builds and runs on watchOS arm64.
  The mbedtls backend (`scripts/link-mbedtls.sh`) must produce a watch slice — this is the biggest
  unknown. Fallback: a pure-Swift/CryptoKit HMAC + a Swift JPAKE if mbedtls can't target the watch.
- **CoreBluetooth on the watch:** confirm `PumpX2BLE`'s `CBCentralManager` can discover + connect the
  pump from a physical Apple Watch (watchOS supports CB central; range/throughput are lower).
- **Handoff auth:** with the phone paired, copy the derived secret to the watch and prove the watch
  can resume-auth **after the phone disconnects** (reuses the existing "Copy pairing secret (debug)"
  + resume path). Confirms the pump accepts a second device holding the same secret.

### Phase 1 — Key handoff plumbing (partly done)
- Phone: after pairing, send `keyShare(pumpKeyHex:)` to the watch; add a "Send pump key to Watch"
  action in Settings. Store the secret in the **watch Keychain** (not UserDefaults).
- Watch: persist + a "Paired (via iPhone)" state; clear on re-pair/forget.

### Phase 2 — Watch pump client
- Add `PumpX2Kit` (Messages/Auth/BLE) as watch-app dependencies.
- `WatchPumpClient` mirroring `LivePumpDataSource`: connect → resume-auth with the shared secret →
  poll status, deliver signed bolus, dismiss alerts. Reuse the exact signed path (byte-verified).
- The watch's existing views bind to either the relay model or the direct client behind a protocol.

### Phase 3 — Mode + arbitration
- Setting: **Connection mode** = *iPhone relay* (default) or *Direct to pump*.
- Arbitration so both never hold the connection: switching the watch to Direct sends the phone a
  "release" (phone disconnects), then the watch connects; switching back reverses it. When the phone
  is reachable it owns the connection unless the user explicitly hands off.
- A clear on-watch indicator of which mode/owner is active.

### Phase 4 — Reliability / background
- watchOS `bluetooth-central` background mode + reconnect/backoff on the watch (background BLE is
  more restricted than iOS; foreground operation is the reliable baseline for the PoC).
- Battery budget: the watch polling + BLE is heavier than relay; tune the cadence.

### Phase 5 — Bench validation
- Saline on a scale. Re-run the oracle byte-exactness for signed messages generated on the watch.
- Handoff edge cases: both devices attempting connect, secret rotation on re-pair, phone returning
  mid-watch-session, watch out of range mid-bolus.

## Risks / open questions
- **mbedtls/crypto on watchOS** — may force a CryptoKit/Swift crypto path (largest risk).
- **Pump contention** — does the pump cleanly accept the watch resuming after the phone drops? (Phase 0.)
- **watchOS BLE** — range, throughput, background limits, battery.
- **Safety** — direct delivery keeps every guard: max-bolus clamp, saline/bench confirm, the
  1-2-3/deliberate confirm, and the validated signed path. No new dosing path bypasses these.

## Status
Scaffolded: `keyShare` + `pumpKeyHex` in the command contract; the phone's debug "copy pairing
secret". Not started: watchOS crypto/BLE spikes, `WatchPumpClient`, arbitration. Start at **Phase 0**
— the crypto spike gates everything else.
