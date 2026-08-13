# Branch model, promotion, and the experimental gate

This governs all three code repos — **faBolus**, **PumpX2Kit**, **faBolusGarmin** — which move in
lockstep (§1.3). `faBolus-internal` is private and single-branch and is not covered here.

Written per §1.1–§1.4 and §13 of the v3 handoff. It is deliberately in the repo root beside
`CONTRIBUTING.md` / `ARCHITECTURE.md`, **not** in the mkdocs site: it is contributor governance, not
end-user documentation.

## The three branches

| Branch | What it is | CI | Who runs it |
|---|---|---|---|
| `deprecated` | A **frozen snapshot** of `main` as it stood on 2026-08-04, *before* the round-3 safety fixes. Tag `deprecated/2026-08-04-v0.1.0-build1`. **Not a supported fallback** — rolling back here reintroduces every known P0. No further commits. | — | nobody; forensics/bisection only |
| `main` | The current, CI-green, release-blocking-set baseline. Everything here has passed CI under the real toolchain. | push + PR + dispatch | self-compilers following the build docs |
| `experimental` | Work that meets the §1.2 classification below. Default-off, unproven, or unverifiable-against-the-pump features live here until promoted. | push + PR + dispatch | **the developer only**, until the clinical-review gate is satisfied (below) |

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

## Cross-repo CI is branch-aware (§1.2)

The three repos build against each other (faBolus consumes PumpX2Kit as a local package; faBolusGarmin
validates against faBolus's schema). CI checks out the sibling at the branch **matching** the branch
under test, falling back to `main` when no same-named counterpart exists — so an `experimental` faBolus
builds against `experimental` PumpX2Kit. The resolver logs the resolved ref **and its SHA**, because the
one dangerous failure is a silent fallback that greens a mismatch. See each repo's
`.github/workflows/ci.yml` (`resolve-refs` in faBolus; the inline `fbref` step in faBolusGarmin).

## Order of operations

Per §1.2: `deprecated` was cut first (before any merge, so it captures the pre-fix `main`), then the
round-3 fixes merged to `main`, then `experimental` was created from the fixed `main`. Creating
`experimental` from a pre-fix `main` would have carried the P0s into it.

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

The intended contract for the backend dependency (PumpX2Kit) is:

1. PumpX2Kit is released under **annotated** tags (`git tag -a`), so a tag carries its own message and
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
PumpX2Kit `main` — with a `FABOLUS_PUMPX2_LOCAL=1` local-path override for day-to-day development
against an unreleased backend (`project.yml`, `scripts/generate-project.sh`).

- **The stated SwiftPM `.unsafeFlags` blocker is retired.** PumpX2Kit's crypto target
  (`CMbedTLSJPAKE`, used by the `PumpX2Auth`/`PumpX2BLE` products faBolus consumes) now sets
  `.define` instead of `.unsafeFlags` at `Package.swift:37` (D3, commit `7ec57c6`), landed on `main`
  via PR #16. The feared 13-symlink `../../vendor/mbedtls` vendoring refactor proved unnecessary — the
  fix was a one-line `.unsafeFlags` → `.define` swap. (A **pinned revision** is also exempt from
  SwiftPM's URL+version/`.unsafeFlags` restriction at the SwiftPM level regardless — that restriction
  applies to version-range/exact pins, not `revision:` pins — but the D3 fix landed anyway as part of
  the same change.)
- **Governance fact, recorded rather than papered over:** PR #16's squash merge carried **D2**
  (`d128eed`, experimental BLE txId correlation) onto PumpX2Kit `main` in the same commit as D3 — D2
  did not independently clear the §1.4 promotion gate above. The owner's **pin-current-main** decision
  (2026-08-13, recorded in `.planning/phases/03-pumpx2kit-version-pin/03-01-SUMMARY.md`) accepts this:
  D2 is opt-in/fail-closed (`correlationMode` defaults to `opcodeFIFO`, `internal(set)`, only elevated
  by `setPumpFamily(.tslim)`, which faBolus never calls) and was squash-cherry-picked such that no
  `main` SHA exists with D3 but not D2. faBolus's revision pin therefore formally consumes D2's code
  even though faBolus never exercises the elevated path. **D2's own §1.4 promotion status remains the
  owner's separate concern — this pin does not retroactively promote it**, and this fact is not to be
  silently corrected away in a future edit of this document.
- Pinned revision: `6efdd43d767c34a0d298ac52fbbd2cd77a6d192a` (PumpX2Kit `main` tip as of 2026-08-13;
  verified CI-green — sbom-provenance + build-and-test — and `PumpX2AuthTests` oracle byte-parity green
  at that exact commit).
- The **in-progress M1 driver** (`feat/m1-tandem-pumpmanager`, `integrations/PumpX2LoopKit`, task #99)
  is no longer constrained to the local path for the crypto reason — it can consume PumpX2Kit via the
  pin, or `FABOLUS_PUMPX2_LOCAL=1` for local iteration, same as the app target.

**Current tag state (PumpX2Kit)**, recorded so it is not re-discovered — *do not create or modify these
tags as part of this contract*:

| Tag | Type | Note |
|---|---|---|
| `v0.1.0` | **annotated** | first-class tag object |
| `v0.2.0` | **lightweight** | bare commit pointer — should be re-cut annotated as a cleanup |
| `v0.3.0` | *(absent, reserved — NOT cut)* | D-01b: superseded by a revision pin instead; a revision pin needs no tag, so `v0.3.0` stays reserved for a possible future exact-version release |

faBolus now commits a canonical, root-level `Package.resolved` (restored into the generated project by
`scripts/generate-project.sh` after each `xcodegen generate`), locking `pumpx2kit` at the pinned
revision above alongside the existing `fabolusnudge`/`loopalgorithm` pins. This closes contract clause 3.
The PumpX2Kit repo's own resolved file stays gitignored by design (PumpX2Kit has no cross-repo package
dependencies of its own to lock). Committing this file does not change any shipped delivery/dosing/
alerting behavior — it is dependency-resolution metadata only.

### Garmin moves in lockstep with the app

> **A Garmin main release accompanies every app main release and holds the same quality bar. Garmin work
> does not lag behind the app and does not ship separately.**

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
- **Build-target set:** the `iq:products` in `faBolusGarmin/manifest.xml` — `venu3s`, `fr265s`,
  `fenix7`, `fr245`, `edge540`, `edge1040` — is the published minimum device set the app compiles for
  (touch and button watches + Edge cycling computers, adapting to touch vs. buttons); those beyond
  `venu3s` are compile-verified only, **not** hardware-validated.
- The store-facing source of truth for this list is `faBolusGarmin/store/connectiq-listing.md`
  (SUPPORTED DEVICES). On a device that is not supported, the app should fail gracefully with an
  explicit message rather than misbehave — a datafield/complication that structurally cannot render the
  honest-staleness `--` must say the value is unavailable rather than show a stale number.
