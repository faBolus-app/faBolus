# Plan — Independent Apple Watch (direct-to-pump)

Goal: let the Apple Watch connect to the pump **over its own Bluetooth** and read status + deliver
saline boluses **without the iPhone present**, as an option alongside the current iPhone-relay mode.
Bench proof-of-concept, saline only.

## The hard constraint: one control connection
The pump accepts **one authenticated control connection at a time** (the same reason t:connect must
be unpaired to use ControlX2). So "independent watch" does **not** mean phone + watch both driving
the pump at once. It means the watch can **take over** the connection when the phone is away
(a *handoff*). The design is built around arbitration, not simultaneous control.

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

So code entry is a **one-time** step on the watch; the recurring path is resume-auth. This makes the
watchOS crypto spike harder — the watch must run the **full JPAKE key exchange**, not just resume.

!!! warning "Open question — does the pump keep more than one pairing?"
    If the pump stores only **one** pairing at a time, pairing the watch may **evict the phone's
    pairing** (and vice-versa), forcing a re-pair when you switch devices. If it keeps several, phone
    and watch can each stay paired (still only one *connected* at a time). Determine this in Phase 0 —
    it decides whether "independent watch" is a co-equal second device or a re-pair-to-switch model.

## Phases

### Phase 0 — Feasibility spikes (de-risk first)
- **Crypto on watchOS:** confirm `PumpX2Auth` (full **JPAKE** key exchange + HMAC-SHA1) builds and
  runs on watchOS arm64. The mbedtls backend (`scripts/link-mbedtls.sh`) must produce a watch slice —
  this is the biggest unknown. Fallback: a pure-Swift/CryptoKit HMAC + a Swift JPAKE if mbedtls can't
  target the watch. (Must cover the full pairing handshake, not just resume.)
- **CoreBluetooth on the watch:** confirm `PumpX2BLE`'s `CBCentralManager` can discover + connect the
  pump from a physical Apple Watch (watchOS supports CB central; range/throughput are lower).
- **Pairing model:** pair the watch directly (fresh code from the pump) and confirm whether doing so
  **evicts the phone's pairing** — this answers the "one pairing?" question above and shapes the UX.

### Phase 1 — On-watch pairing UI + storage
- A watch **6-digit code entry** (crown digit-picker or tap number pad) → run JPAKE on the watch →
  store the derived secret in the **watch Keychain**.
- A "Pair to pump" flow in the watch Settings; a "Forget pairing" to clear. Resume-auth on later
  connects using the stored secret.
- Remove/retire the `keyShare`/`pumpKeyHex` handoff path (kept only if Phase 0 unexpectedly shows the
  pump accepts a shared secret across devices — not expected).

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
- **JPAKE/crypto on watchOS** — the watch must run the *full* pairing handshake; mbedtls may not
  target watchOS, forcing a CryptoKit/Swift path (largest risk).
- **One pairing vs many** — does pairing the watch evict the phone's pairing? (Phase 0; decides the model.)
- **On-watch code entry** — a usable 6-digit input on a tiny screen (crown picker vs number pad).
- **watchOS BLE** — range, throughput, background limits, battery.
- **Safety** — direct delivery keeps every guard: max-bolus clamp, saline/bench confirm, the
  deliberate confirm, and the validated signed path. No new dosing path bypasses these.

## Status
Superseded: the `keyShare`/`pumpKeyHex` handoff (the pump needs a fresh code per device, so the
watch pairs itself). Not started: watchOS crypto/BLE spikes, on-watch code entry + JPAKE,
`WatchPumpClient`, arbitration. Start at **Phase 0** — the crypto spike (full JPAKE) and the
"does pairing the watch evict the phone" question gate everything else.
