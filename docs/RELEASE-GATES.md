# Release gates — on-hardware validation matrix

faBolus is **experimental and not FDA-cleared** (see the README safety banner). Everything below is
software-verified (unit tests, deterministic e2e, byte-parity against the vendored jwoglom oracle, and
Garmin compile checks across device types) but has **not** been validated end-to-end on pump hardware.
These gates must pass before the corresponding feature is relied on for anything real.

**Scope note (v0.5.0 narrow-main milestone):** this matrix spans the full historical feature surface,
including several surfaces the narrow-main removal (`BRANCHES.md` §1.2c) has since scope-narrowed off
`main` onto their `dev/<surface>` sub-branches — Apple Watch remote/host, the Mac menu-bar remote, the
iPhone-peer remote, Mobi + advanced t:slim control (IDP/temp-rate/suspend-resume), non-Venu-3S Garmin
devices, and Siri/Shortcuts. Those items are marked **[off-main]** below; the gate itself still applies
wherever the surface lives and must pass before any reintegration onto `main`.

**Hard rule for every insulin-affecting path: validate on a pump filled with saline, on the bench,
never on a body.** Confirm on the pump / t:connect what actually happened after each step.

## 1. Bolus delivery matrix (saline bench)

For each surface — phone, Garmin, iOS widgets (on `main`); Apple Watch, the Mac app, and the
peer-iPhone remote **[off-main]** — verify on saline:

- Units-mode bolus: requested units == pump-recorded units.
- Carb-mode bolus: host-computed dose delivered; carbs recorded (see §2).
- Correction-only (zero-carb, high BG): delivers the correction or explicitly rejects (never "no
  insulin needed", never a stuck "delivering") — GA-05.
- Cancel mid-delivery: partial amount reported accurately; `cancelled` status with delivered units.
- Extended/combo bolus: now-portion + duration honored; component split correct.
- Lost-response / indeterminate outcome: the app reports **unknown** (FB-02) and reconciles against
  pump history on reconnect — never a fabricated `delivered`.
- Divergence guard: a remote estimate > 0.10 U from the host recompute is rejected (C-06); within
  tolerance the shown dose == the delivered dose (GA-04 rounding parity).
- Max-bolus clamp and child-mode / read-only gating hold on every surface.

## 2. Carb & BG metadata on the pump (saline bench)

- A carb bolus records the **carb amount on the pump graph, t:connect, and Control-IQ** (FOOD1 /
  `foodVolume`), and `bolusBG` / `bolusIOB` land as intended (the *values sent* are oracle-locked; their
  on-pump interpretation is what this gate confirms).
- The best-effort `RemoteCarbEntry` / `RemoteBgEntry` inserts do not disrupt delivery (they are `try?`).
- Extended + carbs `foodVolume` split (currently 0 for the extended path — no oracle vector) is verified
  or left disabled.

## 3. IDP profile CRUD & reconfigure (saline bench, Mobi) [off-main]

Create / modify / delete profile segments and backup-restore reconfigure are gated behind the central
unverified-therapy acknowledgment (FB-06) and are **unproven end-to-end**:

- Create profile + segments: every field (basal, CR, ISF, target, duration) lands correctly on the pump.
- Modify / delete segment: the capture-aligned changed-field masks produce the intended pump state.
- Backup → restore reconfigure: the full profile set + Control-IQ + max bolus apply, or fail closed with
  a clear error (partial application must be recoverable).

## 4. Garmin on-hardware

Compile is verified for venu3s (touch, the sole build target on `main`), fr245 (button, no
Complications) and fenix7 **[off-main — `dev/garmin-devices`]**; **runtime is not**:

- Touch vs button input on each profile: no double-routing (GA-06); hold-to-confirm works; cancel works.
- BG complication in both display modes at fresh / boundary / stale ages; glance staleness after a cold
  restart / background launch (GA-08).
- Inbound malformed/fuzz payloads don't corrupt state (GA-09) — run a fuzz corpus on-device.
- GA-01 gesture-proof decision (phone-confirm vs two-phase token) — see `faBolusGarmin/docs/SECURITY.md`.

## 5. Signed Apple archives (release)

Needs a signing-capable Mac + provisioning:

- Signed device build of the iOS app, widgets, and (if shipped) the watch app and Mac app **[watch
  app / Mac app off-main]**.
- App Group + widget entitlements resolve on-device; QR camera entitlement on Mac **[off-main]**.
- Siri App Shortcuts register with the spoken/alternate names **[off-main — `dev/siri-shortcuts`]**.

## Status

Software layers (contracts, math, message encoding, transaction/idempotency logic, gating) are covered
by automated tests and oracle parity. The gates above require pump hardware and/or a signing Mac and are
tracked as open until validated. See `faBolus-internal/REMEDIATION.md` for per-finding status.
