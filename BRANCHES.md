# Branch model, promotion, and the experimental gate

This governs all three code repos — **faBolus**, **TandemKit**, **faBolusGarmin** — which move in
lockstep (§1.3). `faBolus-internal` is private and single-branch and is not covered here.

Written per §1.1–§1.4 and §13 of the v3 handoff. It is deliberately in the repo root beside
`CONTRIBUTING.md` / `ARCHITECTURE.md`, **not** in the mkdocs site: it is contributor governance, not
end-user documentation.

## The branches

| Branch | What it is | CI | Who runs it |
|---|---|---|---|
| `main` | The current, CI-green, release-blocking-set baseline. Everything here has passed CI under the real toolchain. | push + PR + dispatch | self-compilers following the build docs |
| `experimental` | Work that meets the §1.2 classification below. Default-off, unproven, or unverifiable-against-the-pump features live here until promoted. | push + PR + dispatch | **the developer only**, until the clinical-review gate is satisfied (below) |

The pre-fix state is kept as a TAG, not a branch: `deprecated/2026-08-04-v0.1.0-build1` is a frozen
snapshot of `main` as it stood on 2026-08-04, before the round-3 safety fixes. It is **not a supported
fallback** — rolling back to it reintroduces every known P0. There is no `deprecated` branch on any
remote; use the tag for forensics/bisection.

Two tags track goodness over time:

- `deprecated/2026-08-04-*` — immovable; the pre-fix snapshot.
- `safe-baseline/2026-08-04` — the **moving** last-known-good pointer, advanced as each release-blocking
  phase lands. This is the rollback target, not `deprecated`.

## §1.2 — what belongs on `experimental`

A feature belongs on `experimental` (not `main`) if it **fires on a threshold, automates a decision, or
produces output the user cannot immediately verify against the pump.**

By that rule, several features currently on `main` are misclassified and must move on the next
promotion pass. Recorded here as a **decision**, not left to be discovered at the first promotion:

| Feature | Why it is `experimental` | State today |
|---|---|---|
| Hypo / predicted-low banner | produces a glucose projection the user cannot verify against the pump | default-off; also under C3/§3.2 decision (P16) |
| Eating nudges | fires on a detector threshold | default-off, `#if FABOLUS_NUDGE` |
| Smart Assist bolus warnings | automates a judgement about a proposed dose | default-off, `#if FABOLUS_NUDGE` |
| Sleep / Exercise automation | automates a pump-mode decision on a schedule | default-off (Mobi-only) |

All four are default-off and three are already behind `#if FABOLUS_NUDGE`, so the move is small — but it
is a move, and it happens as part of creating/curating `experimental`, not silently.

## §1.4 — promotion criteria (written before the first promotion, deliberately)

`experimental` exists from this phase onward, so these criteria are set **now** — leaving them to a
later phase would leave every intervening promotion ungoverned. A feature promotes `experimental → main`
only when **all** hold:

1. **Verifiable or clearly bounded.** Either its output can be checked against the pump, or it is
   presented as advisory with that limitation stated in the UI at the point of use.
2. **Default-off preserved if it automates.** Anything that fires on a threshold or automates a decision
   ships default-off on `main` too, with a one-time plain-language explanation.
3. **CI-green on the real toolchain**, across every surface it touches (not just locally — CI runs a
   stricter Xcode than a typical dev machine; a local green is necessary, not sufficient).
4. **Tests pin the behaviour**, including the failure/edge path, not only the happy path.
5. **No new capability inferred where the pump already answers it** — read the pump, don't model it
   (C4). New inference is a promotion blocker until it is shown the pump can't supply the fact.
6. **Clinical review** (below) is complete for any feature touching dosing guidance, thresholds, or
   automation copy — this is a hard gate, not a checklist item.
7. **Disposition honoured.** Nothing that would move the delivery disposition off **NO-GO for real
   insulin delivery** promotes without that being the explicit, separate subject of the change.

## Clinical-review gate — a distribution constraint on `experimental` itself

§13 requires endocrinologist / CDCES review of **DS1, L6, H1–H4, K1–K2** and the **§2.1 therapy-editing
copy** *before anyone outside the developer runs an `experimental` build.*

This is a constraint on **distributing the branch**, so it lives with the branch:

- **Do not distribute `experimental` builds** (TestFlight, sideload to another person, store beta) until
  that review is complete and recorded.
- The developer building and running `experimental` on their own device for bench work is fine.
- When the review is done, record it here with date and reviewer, and only then widen distribution.

This plan/repo work **cannot** satisfy this gate — it needs a clinician. It is stated so the constraint
travels with the branch rather than being lost.

### RECORDED 2026-08-23 — owner-accepted AI-panel review (NOT a licensed clinician)

**Verdict: APPROVED, with documentation/copy changes (all applied) — no dose-path code change.**

The §2.1 therapy-editing copy (A1/B1/C2) and the insulin-affecting include-stale (#96) + two-way
stale-IOB/therapy behaviors were reviewed by an **owner-directed panel of two independent AI reviewers
(Claude + Codex)** — explicitly **NOT** a licensed endocrinologist/CDCES. The owner (Zev Granowitz, F5 §13
approver of record) accepts this AI-panel review as satisfying the copy-distribution gate **for the
still-saline-only experimental build**. This is a deliberate owner substitution for the clinician review
described above; it carries no licensed-clinician authority.

- **Outcome:** A1 / C2 / §4b approved as-is; B1a reworded (Control-IQ automation attributed to basal +
  correction factor only); B1b gained an acute-danger carve-out — both re-blessed in `TherapyEditAck.swift`
  (§13-cleared 2026-08-23). §4a/§3 framing corrected (path is bidirectional; the 0.10 U divergence guard
  bounds the fallback either way). Full record + sources + reviewer trail:
  `.planning/intel/prep/phase4-clinical-signoff/AI-PANEL-REVIEW-DECISIONS.md`.
- **Distribution:** experimental distribution to a non-developer is **UNBLOCKED** as of this record (once
  the blessed copy has propagated to `experimental` — landing in progress).
- **Standing (UNCHANGED): the saline-only NO-GO for real insulin remains fully in force.** Widening
  distribution here does **not** authorize real-insulin use — that stays gated on Phase 12 (on-hardware
  saline bench) and is a separate, explicit owner decision, never automatic.
- The DS1 / L6 / H1–H4 / K1–K2 advisory features named above are ranked / not-yet-built; their clinical
  design review is deferred until they exist (out of scope for this shipped-copy gate).

## Cross-repo CI is branch-aware (§1.2)

The three repos build against each other (faBolus consumes TandemKit as a local package; faBolusGarmin
validates against faBolus's schema). CI checks out the sibling at the branch **matching** the branch
under test, falling back to `main` when no same-named counterpart exists — so an `experimental` faBolus
builds against `experimental` TandemKit. The resolver logs the resolved ref **and its SHA**, because the
one dangerous failure is a silent fallback that greens a mismatch. See each repo's
`.github/workflows/ci.yml` (`resolve-refs` in faBolus; the inline `fbref` step in faBolusGarmin).

## Order of operations

Per §1.2: `deprecated` was cut first (before any merge, so it captures the pre-fix `main`), then the
round-3 fixes merged to `main`, then `experimental` was created from the fixed `main`. Creating
`experimental` from a pre-fix `main` would have carried the P0s into it.

## §1.2b — v0.5.0 narrow-main topology (Phase 0, 2026-08-20)

The v0.5.0 "narrow-main" milestone narrows `main` by SUBTRACTION from the full pre-narrow baseline. Phase 0
established the recoverable baseline + the per-surface sub-branch topology across the three-repo lockstep.

**Pre-narrow baseline tags** (annotated; the recoverable full-surface snapshot each sub-branch is cut from):

| Repo | Operative tag | At | Superseded |
|------|---------------|----|------------|
| faBolus | `pre-narrow/2026-08-20` | `main` @ `618dd29` | `pre-narrow/2026-08-18` (lightweight, ~130 commits stale — predated the 09.24–09.29 sync + the pump-disconnect fix; left untouched) |
| TandemKit | `pre-narrow/2026-08-20` | `main` @ `89c208e` | `pre-narrow/2026-08-18` (lightweight; left untouched) |
| faBolusGarmin | `pre-narrow/2026-08-20` | `main` @ `87ca1c1` | `pre-narrow/2026-08-18` (lightweight; left untouched) |

**Per-surface sub-branches — namespace `dev/<surface>`, NOT `experimental/<surface>`** (owner, 2026-08-20):
git cannot nest `experimental/<surface>` under the existing `experimental` integration branch (ref
file-vs-directory conflict), so per-surface branches live under a fresh `dev/` namespace; the `experimental`
all-features integration branch is unchanged. Each sub-branch is code-identical to the baseline at cut time
(no surface relocated in Phase 0); the owning per-surface phase (1–9) later moves its surface onto it.

| Repo | Sub-branches (`dev/…`) at Phase 0 cut (2026-08-20) | Count at cut |
|------|------------------------|-------|
| faBolus | `mac`, `phone-remote`, `watch-remote`, `watch-host`, `nudge`, `cgm-extra`, `mobi` | 7 |
| faBolusGarmin | `garmin-devices` | 1 |
| TandemKit | — (none: the protocol layer is pump-model-agnostic and ships `.mobi`-tagged messages unconditionally; Mobi removal is faBolus-side capability surgery) | 0 |

⚠ **The table above is the Phase-0 snapshot only — every repo has grown its `dev/*` roster since.**
Current counts (see §1.2c's "later removals" table for what each one preserves): faBolus **21**
(`git branch --list 'dev/*'`), faBolusGarmin **5**, TandemKit **1** (`dev/loopkit`, cut 2026-08-25).

**Branch-aware CI (TOPO-04):** `on.push.branches` widened to include `'dev/**'` on faBolus + faBolusGarmin so a
per-surface sub-branch push fires CI (the `resolve-refs`/`fbref` resolver already matches any branch name —
the gap was only the trigger key). **TandemKit's `ci.yml` trigger widening is DEFERRED — and the gap is now
FUNCTIONAL, not moot:** TandemKit's premise at the Phase-0 cut ("no `dev/*` sub-branch, so this is
non-functional now") is no longer true — `dev/loopkit` exists (locally and on `origin`) and its own
`loopkit-driver.yml` workflow already had to be re-pointed at it directly (`20b25f9`) because the repo-wide
`ci.yml` trigger still does not cover `dev/**`. TandemKit changes still go via PR → merge-after-green-CI
(kit discipline) as the primary gate, but the widening this section deferred is now due, not merely
hypothetical; open a kit PR to add it. `watch-host` builds Simulator-only (hardware → Phase-11 bench).

## §1.2c — narrow-main removal roster (v0.5.0 set final 2026-08-22; later removals appended below)

Phases 1–9 landed the full narrow-main subtraction set decided at 999.5-D1 (below) — that FIRST block
of rows is still final as of 2026-08-22. Removals made after that date (Phases 21–23, and the
tslim-reconnect-loop AAM cleanup) are NOT part of 999.5-D1; they are appended as their own rows below
the v0.5.0 set, each with its own specific rationale rather than the 999.5-D1 citation. Every
`dev/<surface>` branch named below is a real, existing branch (`git branch --list 'dev/<name>'` is
non-empty, and for the faBolusGarmin/TandemKit rows, the equivalent check in that repo) — a docs edit
does not create, rename, or move any of them.

| Surface | Preserved on | Why `experimental`, not `main` |
|---|---|---|
| Dexcom G7 direct-BLE | `dev/cgm-extra` | scope-narrowing per 999.5-D1 (CGM floor = Dexcom Share alone) |
| Dexcom G6 direct-BLE + local-connection failover | `dev/cgm-extra` | scope-narrowing per 999.5-D1 |
| LibreLinkUp | `dev/cgm-extra` | scope-narrowing per 999.5-D1 |
| xDrip App-Group | `dev/cgm-extra` | scope-narrowing per 999.5-D1 |
| Non-Venu-3S Garmin devices (fr265s / fenix7 / fr245 / edge540 / edge1040) + standalone watch-face app | `dev/garmin-devices` (faBolusGarmin repo) | scope-narrowing per 999.5-D1 (build-target set = Venu 3S alone, §1.3 below) |
| Mac menu-bar remote | `dev/mac` | scope-narrowing per 999.5-D1 |
| iPhone-to-iPhone peer remote | `dev/phone-remote` | scope-narrowing per 999.5-D1 (the Garmin/widget remote path stays on `main`; the `PhoneRemoteHost` receiver does NOT — Phase 17.5 retired the `WCSession`/`PhoneRemoteHost` transport, so it survives only on this branch) |
| Apple-Watch-as-remote | `dev/watch-remote` | scope-narrowing per 999.5-D1 |
| Apple-Watch-as-host (direct-to-pump) | `dev/watch-host` | scope-narrowing per 999.5-D1 (own sub-branch, kept separate from watch-as-remote per owner instruction) |
| faBolusNudge / Smart Assist submenu + Control-IQ-awareness readouts | `dev/nudge` | scope-narrowing per 999.5-D1 |
| Apple HealthKit (incl. HR reader, Health import/export) | `dev/healthkit` | scope-narrowing per 999.5-D1 |
| Nightscout (source + upload + backfill) | `dev/nightscout` | scope-narrowing per 999.5-D1 |
| Backup/restore incl. iCloud + SiteAtlas — on-device erase/full-reset is KEPT on `main` per D-08 | `dev/backup` | scope-narrowing per 999.5-D1 |
| Glucose Live Activity | `dev/live-activity` | maturity per the existing §1.2 rule (produces output the user cannot immediately verify against the pump) |
| GraphDetail scrubber | `dev/graph-detail` | maturity per the existing §1.2 rule |
| CGM app-icon glucose badge | `dev/glucose-badge` | maturity per the existing §1.2 rule |
| Child Mode UI | `dev/child-mode` | scope-narrowing per 999.5-D1 (runtime-gated; the dose-adjacent `AccessPolicy`/`ChildFeature` core stays byte-identical) |
| Siri / Shortcuts + Temp/Profile/Mode + activity/sleep automations | `dev/siri-shortcuts` | maturity per the existing §1.2 rule (automates a pump-mode decision) |
| Retrospective insights | `dev/retrospective` | maturity per the existing §1.2 rule |
| FoodFinder / food-scanner | `dev/food-finder` | scope-narrowing per 999.5-D1 |
| Custom alert-rules engine | `dev/alert-rules` | scope-narrowing per 999.5-D1 (the glucose LOW/HIGH/urgent-low + safety-trio alerts stay on `main`) |
| Mobi + all advanced t:slim control (temp-rate / suspend-resume / modes / IDP) | `dev/mobi-surface` (frozen; `dev/mobi` retained as history) | scope-narrowing per 999.5-D1 (`main` = t:slim X2, bolus + status + alerts only). Real frozen pointer: `dev/mobi-surface`, cut from the pre-programme `experimental` tip — the only tip that still carries the full temp-rate/suspend/IDP surface (the older `dev/mobi` is 493 behind and its `REINTEGRATION.md` framed the capability-model removal as "not yet touched"). Its `REINTEGRATION.md` enumerates the actual preserved symbols (`PumpModel.mobi`, `TempRateAutomation`, `GatedPumpWrite.suspendDelivery`/`resumeDelivery`/`setTempBasal`/`setMode`, the IDP `createProfile`…`deleteProfileSegment` cases) and the restore steps. `dev/mobi` is kept for the Mobi save-PIN deletion history. |
| Simple/Standard experience-mode selector | `dev/mode-selector` (frozen) | scope-narrowing per 999.5-D1 (mode is pinned to `.advanced`). Real frozen pointer: `dev/mode-selector`, cut from the pre-programme `experimental` tip (the un-pinned, user-reachable form). Its `REINTEGRATION.md` enumerates the actual preserved symbols (`AppMode`/`SettingTier` in `SettingsTiers.swift`, `ModeGateContext` in `AccessPolicy.swift`, `GatedPumpWrite.requiredMode` in `GatedPumpWriteTier.swift`, the `appMode` pin, `ModeStore`, the emit-only `activeMode` wire field) and the restore steps — note `SettingTier` must be restored together with `GatedPumpWriteTier` or the package build breaks. |
| mmol/L display-units selector | runtime-locked/hidden on `main`, full feature on `experimental` | scope-narrowing per 999.5-D1 (display is locked to mg/dL; dose math is unit-internal, unchanged) |
| >24h history | runtime-locked/hidden on `main`, full feature on `experimental` | scope-narrowing per 999.5-D1 (locked to 24h; no dose/IOB path reads beyond it) |
| Extended (combo) bolus | `dev/extended-bolus` (frozen) | scope-narrowing per 999.5-D1 (the signed `deliverExtended` path stays byte-identical on `main`; the toggle is pinned off). Real frozen pointer: `dev/extended-bolus`, cut from the pre-programme `experimental` tip (the un-pinned form). Its `REINTEGRATION.md` enumerates the actual preserved symbols (`extendedBolusSection` in `BolusEntryView.swift`, the `extendedBolusEnabled` toggle/pin/catalog entry, `capabilities.supportsExtendedBolus`, `GatedPumpWrite.deliverExtendedBolus` and `PumpBackend.deliverExtendedBolus`) and the restore steps. |
| Pump clock-sync | `dev/clock-sync` (frozen) | scope-narrowing per 999.5-D1 (the read-side time-anchor stays on `main`; the write path is pinned off). Real frozen pointer: `dev/clock-sync`, cut from the pre-programme `experimental` tip — the only tip that still carries BOTH halves, because the dead-code programme's Phase 33 already removed the `AppModel` driver half (`syncTimeToNow()`, `maybeAutoSyncPumpTime`) from `main`. Its `REINTEGRATION.md` enumerates the actual preserved symbols (`autoSyncPumpTime` pin, `capabilities.supportsTimeSync`, `GatedPumpWrite.syncTimeToNow`, the backend implementations, and the `AppModel`/`RefreshEffectsCoordinator` driver) and the restore steps. |
| Insulin Stacking Guard disclosures (SG1/SG2/SG3a) | `dev/stacking-guard` (frozen) | scope-narrowing per 999.5-D1 (the `StackingGuard` core stays byte-identical on `main`; the friction disclosures are pinned off). Real frozen pointer: `dev/stacking-guard`, cut from the pre-programme `experimental` tip where the flag defaults **true** so the friction tiers actually apply. Its `REINTEGRATION.md` enumerates the actual preserved symbols (the `stackingGuardFrictionEnabled` toggle/pin/catalog entry, the `sg3aAppliedFriction` confirm-seam tier cap and the SG1/SG2/SG3a disclosure rendering in `BolusEntryView.swift`) and the restore steps — the guard core itself is NOT what this branch restores. |

**Later removals (not part of 999.5-D1; appended as each landed):**

| Surface | Preserved on | Why `experimental`/branch-only, not `main` |
|---|---|---|
| AAM (Active Alert Malfunction) read fan-in — op120/op146, confirmed dead plumbing (no live/decision consumer) | `dev/aam-malfunction-code` | tslim-reconnect-loop Phase B (`f2be9179`) — auto-polling it also provoked an op-77 + deliberate BLE teardown on Control-IQ-off/no-CGM API-2.5 t:slim X2 |
| Control-IQ auto-correction awareness display, phone half (`AutoCorrectionDisclosure.swift`'s `ambientIndicator`/`lockoutMessage`) | `dev/control-iq-awareness` | Phase 23 Plan 01 (`NARROW-CIQ-23`, W1) |
| Control-IQ auto-correction awareness display, Garmin half (`AppState.mc` controller-display helpers) | `dev/control-iq-awareness` (faBolusGarmin repo) | Phase 23 Plan 02 (`NARROW-CIQ-23`, W1) |
| Ambient heart-rate relay, phone/consumer half (`AppModel`/`GarminRemoteBridge` relay members) | `dev/garmin-hr-relay` | Phase 22 (`NARROW-HR-22`) |
| Ambient heart-rate relay, Garmin/producer half (`HeartRateRelay.mc`) | `dev/garmin-hr-relay` (faBolusGarmin repo) | Phase 22 (`NARROW-HR-22`) |
| Paused direct-to-pump + direct-to-CGM (Dexcom G7) BLE engines (probe-only, never shipped) | `dev/direct-ble` (faBolusGarmin repo) | narrow-main, owner decision 2026-08-27 (`f0a0fc3`) — auditability/reliability; preserved WITH 7 additional Phase-21 hardening commits on top |
| Garmin-only Insulin Stacking Guard dose-magnitude disclosure (W2) | `dev/stacking-guard-disclosure` (faBolusGarmin repo) | Phase 23 Plan 02 (`NARROW-CIQ-23`, W2) — the app-side SG1/SG2/SG3a row above is the phone half (runtime-locked, no branch needed); Monkey C has no runtime flag mechanism, so the Garmin-only half needs its own branch |
| `TandemLoopKit` — the optional LoopKit `PumpManager` adapter | `dev/loopkit` (TandemKit repo) | narrow-main (`cd7eec7`) — LoopKit is iOS-only/HealthKit-bearing; the adapter is a separate SwiftPM package that depends on the core, never the reverse, so it never entered the oracle-parity dependency graph |
| `datafield` Connect IQ target (BG data field, `type="datafield"`) | `dev/datafield` (faBolusGarmin repo) | owner decision 2026-08-31, Phase 37 plan 02 (D-05) — structurally inert Connect IQ target: Connect IQ's platform permission model forbids app type `datafield` from holding `ComplicationSubscriber` (verified against SDK 9.2.0, exit 102), so it can never read a BG reading on any of its five declared products; it also shared the working remote-control app's store listing name |

No surface in either table is on `main`. See DECISION 999.5-D1/D2 (`.planning/intel/decisions.md`) for the
ratified v0.5.0 as-built record, and each `dev/<surface>` branch's own `REINTEGRATION.md` for
reintegration steps (every branch above now has one).

**`experimental` next-sync fix-up needed (Phase 31 unit 3, D-21).**
`Packages/faBolusCore/Sources/faBolusCore/GraphDetailReadout.swift` was deleted outright from `main`
(no compile shim) — `experimental` is not frozen (it was 9 ahead / 388 behind `main` at the time this
note was written) and its own `ios/faBolus/Views/GraphDetailView.swift` + `GlucoseChartView.swift`
still reference the type, so `experimental` will fail to compile the next time it syncs from `main`
until that reference is resolved (either by re-adding the file locally on `experimental`, or by not
yet merging past this point). This is recorded here rather than fixed now because fixing it requires
touching `experimental`, out of scope for a `main`-only phase.

## §1.3 — versioning and the cross-repo contract

This is the **canonical** version + cross-repo contract for all three code repos. `AGENTS.md` and
`CONTRIBUTING.md` cross-reference this section rather than restating it, so there is one source of truth.

### App version — single source

Each app carries a marketing version (`CFBundleShortVersionString`, semver) and a build number
(`CFBundleVersion`). These are single-sourced in `Config.xcconfig` (`MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION`) exactly the way `APP_BUNDLE_ID` is: every target inherits them from the
project-level `configFiles` in `project.yml` — there are **no** per-target version literals to drift.
Bump `MARKETING_VERSION` on a release and record it in `CHANGELOG.md`. Current: **0.1.0 / build 1**.

### Backend version-pinning contract — the TARGET state

The intended contract for the backend dependency (TandemKit) is:

1. TandemKit is released under **annotated** tags (`git tag -a`), so a tag carries its own message and
   date and is a first-class object, not a bare pointer.
2. Apps pin the backend by an **explicit version or a pinned commit `revision:`** (SwiftPM `url:` +
   version range/exact, or `url:` + `revision:`), not an unversioned local path — so a build is
   reproducible and a rollback to `safe-baseline`/`deprecated` is meaningful for the pump-protocol
   stack, with a **documented local-path override** for day-to-day development against an unreleased
   backend.
3. The resolved graph is captured in a **committed `Package.resolved`** so CI and every clone build the
   same backend revision.

### Backend version-pinning — MET (current state, pinned revision, 2026-08-13)

This contract is now **MET**, via a **pinned revision** (D-01/D-01a) rather than the exact-version pin
originally envisioned. faBolus consumes the backend by `url:` + `revision:` — a pinned commit SHA on
TandemKit `main` — with a `FABOLUS_TANDEM_LOCAL=1` local-path override for day-to-day development
against an unreleased backend (`project.yml`, `scripts/generate-project.sh`).

- **The stated SwiftPM `.unsafeFlags` blocker is retired.** TandemKit's crypto target
  (`CMbedTLSJPAKE`, used by the `TandemAuth`/`TandemBLE` products faBolus consumes) now sets
  `.define` instead of `.unsafeFlags` at `Package.swift:37` (D3, commit `7ec57c6`), landed on `main`
  via PR #16. The feared 13-symlink `../../vendor/mbedtls` vendoring refactor proved unnecessary — the
  fix was a one-line `.unsafeFlags` → `.define` swap. (A **pinned revision** is also exempt from
  SwiftPM's URL+version/`.unsafeFlags` restriction at the SwiftPM level regardless — that restriction
  applies to version-range/exact pins, not `revision:` pins — but the D3 fix landed anyway as part of
  the same change.)
- **Governance fact, recorded rather than papered over:** PR #16's squash merge carried **D2**
  (`d128eed`, experimental BLE txId correlation) onto TandemKit `main` in the same commit as D3 — D2
  did not independently clear the §1.4 promotion gate above. The owner's **pin-current-main** decision
  (2026-08-13, recorded in `.planning/phases/03-pumpx2kit-version-pin/03-01-SUMMARY.md`) accepts this:
  D2 is opt-in/fail-closed (`correlationMode` defaults to `opcodeFIFO`, `internal(set)`, only elevated
  by `setPumpFamily(.tslim)`, which faBolus never calls) and was squash-cherry-picked such that no
  `main` SHA exists with D3 but not D2. faBolus's revision pin therefore formally consumes D2's code
  even though faBolus never exercises the elevated path. **D2's own §1.4 promotion status remains the
  owner's separate concern — this pin does not retroactively promote it**, and this fact is not to be
  silently corrected away in a future edit of this document.
- Pinned revision: `6efdd43d767c34a0d298ac52fbbd2cd77a6d192a` (TandemKit `main` tip as of 2026-08-13;
  verified CI-green — sbom-provenance + build-and-test — and `TandemAuthTests` oracle byte-parity green
  at that exact commit).
- The **in-progress M1 driver** (`feat/m1-tandem-pumpmanager`, `integrations/TandemLoopKit`, task #99)
  is no longer constrained to the local path for the crypto reason — it can consume TandemKit via the
  pin, or `FABOLUS_TANDEM_LOCAL=1` for local iteration, same as the app target.

**Current tag state (TandemKit)**, recorded so it is not re-discovered — *do not create or modify these
tags as part of this contract*:

| Tag | Type | Note |
|---|---|---|
| `v0.1.0` | **annotated** | first-class tag object |
| `v0.2.0` | **lightweight** | bare commit pointer — should be re-cut annotated as a cleanup |
| `v0.3.0` | *(absent, reserved — NOT cut)* | D-01b: superseded by a revision pin instead; a revision pin needs no tag, so `v0.3.0` stays reserved for a possible future exact-version release |

faBolus now commits a canonical, root-level `Package.resolved` (restored into the generated project by
`scripts/generate-project.sh` after each `xcodegen generate`), locking `tandemkit` at the pinned
revision above. This closes contract clause 3.
The TandemKit repo's own resolved file stays gitignored by design (TandemKit has no cross-repo package
dependencies of its own to lock). Committing this file does not change any shipped delivery/dosing/
alerting behavior — it is dependency-resolution metadata only.

### Garmin moves in lockstep with the app

> **A Garmin main release accompanies every app main release and holds the same quality bar. Garmin work
> does not lag behind the app and does not ship separately.**[^narrowed-999.5-D1]

[^narrowed-999.5-D1]: **Narrowed by DECISION 999.5-D1** (2026-08-22): this release-lockstep and
CI-branch-aware discipline is retained in full — only the **on-`main` device breadth** shrinks, from the
six-product set to Venu 3S alone (see "Minimum Garmin device set" below). A Garmin `main` release is still
required to accompany every app `main` release; it simply now targets one device instead of six.

The **enforcement mechanism already exists** — it is the P5/P6 **branch-aware cross-repo CI** described
above (faBolus's `resolve-refs`; faBolusGarmin's inline `fbref` step + the schema-drift check), which
builds each repo against the sibling on the matching branch and logs the resolved ref **and its SHA** so
a silent fallback that greens a mismatch is caught. No new CI is required for this clause.

### Compatibility matrix

The wire contract between the app and its remotes is the `RemoteCommand` **schema version**, asserted
in code (`Packages/faBolusCore/.../RemoteCommand.swift`: `schemaVersion = 1`, with a decode guard
`guard version == Self.schemaVersion`) and mirrored on Garmin (`source/app/RemoteComm.mc`:
`SCHEMA_VERSION = 1`), with `faBolusGarmin/scripts/check-schema-drift.sh` failing CI on drift. This
table documents that existing invariant across releases:

| App `MARKETING_VERSION` | faBolusGarmin version | `RemoteCommand` schemaVersion |
|---|---|---|
| 0.1.0 | 0.1.0 (lockstep; the Connect IQ `manifest.xml` carries no independent semver — its releases are tagged in lockstep with the app) | 1 |

Add a row on any release that bumps the app version or the schema version; a schema bump is a breaking
change that both sides must land together (§1.4-4 + the drift checker).

### Minimum Garmin device set

- **Hardware-validated:** `venu3s` is the **sole** hardware-validated Garmin device.
- **Build-target set on `main` — `venu3s` ALONE** (narrowed by **DECISION 999.5-D1**, 2026-08-22, GARMIN-01):
  the `iq:products` in `faBolusGarmin/manifest.xml` on `main` compiles for Venu 3S only. The other five
  products previously in the minimum set — `fr265s`, `fenix7`, `fr245`, `edge540`, `edge1040` (touch and
  button watches + Edge cycling computers) — are **removed from `main`** and now live in the `experimental`
  faBolusGarmin manifest on `dev/garmin-devices` (compile-verified there, not hardware-validated; see
  §1.2c above). The standalone watch-face app (`manifest-watchface.xml` / `watchface.jungle` /
  `watchface/`) is removed alongside them; the complication publisher (`BgComplication.mc` +
  `resources-complications/`) is KEPT on `main`.
- The store-facing source of truth for the `main` list is `faBolusGarmin/store/connectiq-listing.md`
  (SUPPORTED DEVICES), updated to Venu 3S only. On a device that is not supported, the app should fail
  gracefully with an explicit message rather than misbehave — a datafield/complication that structurally
  cannot render the honest-staleness `--` must say the value is unavailable rather than show a stale
  number.
