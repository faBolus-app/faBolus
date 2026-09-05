# Narrow-main gates: the removal convention (Phase 0 capstone)

**Status:** convention + pattern spec. Phase 0 authors this; it implements **none** of the runtime
gates below. Later phases (1–9.5) implement removals against this single convention instead of
inventing their own shapes.

> **RETIRED — cross-branch dose/signed byte-identity freeze.**
> The requirement that the dose-path file set (see the section below) stay byte-identical between
> `main` and every `dev/<surface>` sub-branch does not resume. It was never a running gate — it exited
> 0 unless invoked with a manual override flag — and its enforced mode was a cross-branch `git diff`
> that stayed red across every sub-branch it was ever run against, not a byte-parity oracle. No CI
> workflow invoked it.
>
> The dose-wire correctness net that actually runs is the TandemKit **JDK-21 oracle byte-parity** run
> plus each phase's own named suites (`BolusMathParityTests`, the `GatedPumpWrite` guards, and the
> other suites named per gate below), together with `check-schema-drift.sh`. Any change touching
> delivery code keeps those green; that is the re-proof, not a cross-branch diff.

## The dose-path file set (the membership marker)

The dose/signed source set that every removal phase treats as dose-adjacent, **by file, not by
symbol**:

- `Packages/faBolusCore`
- `ios/faBolus/Data/AppModel.swift`
- `ios/faBolus/Data/TandemBackend.swift`

Membership in this list is what a later phase checks before deciding whether an item needs the full
dose re-proof (the oracle byte-parity run plus the named suites) rather than an ordinary suite run.
The two-tier narrowing of this list — whether a file that only partially touches dose logic should
count as a partial member — is an open question this document does not resolve.

The v0.5.0 "narrow main" milestone subtracts surfaces from `main` one at a time. Every removal takes
**exactly one of two shapes**, and which shape is allowed is decided by whether the surface is
dose-adjacent:

| Shape | Used for | Mechanism | The invariant it must preserve |
|-------|----------|-----------|--------------------------------|
| **Compile gate** (`FABOLUS_*` + `# >>> TAG … # <<< TAG`) | Self-contained, **non**-dose surfaces (a whole target, package, or source-dir set) | `scripts/generate-project.sh` strips the block from a copy of `project.yml` before `xcodegen` runs | The surface is absent at `=0`, present at default; the default spec stays byte-identical to today |
| **Runtime gate** (settings-forced-value + UI-hide) | **Dose-adjacent** surfaces | Force the existing setting to its safe value + hide the UI; the evaluator/core is **NOT touched** | The dose/signed evaluator/core is **byte-identical across every branch** (INV-01/INV-03) |

**Why dose-adjacent surfaces get a runtime gate, never a compile-deletion (D-03):** every one of the
7 hides below touches code the dose-path file set above protects (`AccessPolicy`,
`GatedPumpWrite`, `StackingGuard`, `deliverExtendedBolus`, the `PumpResponseApplier` time anchor). A
`#if FABOLUS_*` around any of it would make the dose/signed core diverge between branches, the exact
drift the exit gate forbids. So a dose-adjacent surface is removed by **forcing its setting off and
hiding its UI**, leaving the evaluator byte-identical and its named test suite green. Compile-deleting
dose-adjacent code before its dedicated, oracle-re-run phase is Pitfall 5.

---

## The 7 dose-adjacent runtime gates (documentation only; implemented in Phases 7/8)

Each spec below is the same shape: **settings-forced-value + UI-hide; evaluator/core byte-identical;
the named test suite stays green.** Phase 0 flips none of them.

### 1. extended-bolus-hide  (Phase 8; **RETIRED**)
Retired: the `extendedBolusEnabled` pin, the extended-bolus section of `BolusEntryView`, and every
now/later dose-splitting plumbing symbol it threaded through (`attemptDeliver`'s `extended`
parameter, `freeze`'s split arm, `FrozenBolus.extendedNow`/`extendedDurationMin`,
`deliverFrozen`'s dispatch) are deleted — there is no longer a settings row or UI section to hide.
The delivery core (`AppModel.deliverExtendedBolus`, `TandemBackend.deliverExtendedBolus`,
`GatedPumpWrite.deliverExtendedBolus`) and the `AppModel` capability pre-flight
(`guard capabilities.supportsExtendedBolus`) are kept byte-identical and untouched — they simply
have no caller left in the app UI. Preserved on the `dev/extended-bolus` branch. Named suites that
must stay green: `BolusMathParityTests`, the `GatedPumpWrite` guards, `KeyboardShortcutDoseGuardTests`,
`ExtendedBolusHiddenBoundaryTests` (the end-to-end consented-total proof through the retained
delivery core).

### 2. history-24h-lock  (Phase 8)
Cap `HistoryStore` retention (settings-forced-value on `historyRetentionDays`) and remove the
Data & History settings UI. The read path and any IOB/dose computation stay **byte-identical**; a gate
assertion confirms no IOB/dose read reaches back beyond 24h. Named suites: `BolusMathParityTests`,
`HistoryLogSyncDeliveryBoundaryTests`.

### 3. clock-sync-removal  (Phase 8; **RETIRED**)
Retired: the pump clock-sync WRITE path is deleted whole — `supportsTimeSync`,
`GatedPumpWrite.syncTimeToNow`, the three backend implementations (`TandemBackend`, `PumpBackend`
default, `MockBackend`), and the `autoSyncPumpTime = false` init pin — in one commit, together with
`TandemBackend.sendControl` and the `ControlAckInspection.swift` ack-inspection machinery it retired
as their last functional caller. `GatedPumpWrite` reaches its final four cases (`deliverBolus`,
`deliverExtendedBolus`, `cancelBolus`, `dismissNotification`); `.controlInterlock` has no surviving
member. **The read-side `PumpResponseApplier` time anchor is kept byte-identical and untouched** — the
app must still interpret pump-reported timestamps correctly even though it no longer *writes* the
clock. This was the one gate with an explicit "keep the read side" caveat; removing the anchor would
corrupt dose/IOB timing. The removal is net-positive, not merely tidy: the write was already double-dead
(`autoSyncPumpTime` defaulted off and no real pump advertised `supportsTimeSync` on `main`), and the
project's own bench observed a `ChangeTimeDate`-family write producing an op-77 plus a BLE link drop on
API 2.5. The `_autoSyncPumpTime` stored preference and its `store` wire are left standing — a readerless
residual whose own removal is a separate decision, not an automatic follow-on. Preserved on the
`dev/clock-sync` branch. Named suites: `BolusMathParityTests`, the `GatedPumpWrite` guards,
`AccessPolicyTests`.

### 4. units-mgdl-lock  (Phase 8)
Force `glucoseDisplayUnit = .mgdl` and hide the unit picker. Dose math is already mg/dL-canonical and
unit-internal, so the evaluator/core is **byte-identical**; this gate is purely a display-surface
lock. Named suite: `BolusMathParityTests` (proves the dose path never read the display unit).

### 5. mode-lock-advanced  (Phase 8; **RETIRED**)
Retired: the `AccessPolicy` Mode Gate, the `appMode = .advanced` pin, and the whole `AppMode` /
`SettingTier` vocabulary that existed only to feed it are deleted. The mode axis was structurally
inert on three independently verified legs before removal: (1) the only production
`ModeGateContext` construction site omitted `disabledFeatures`, so the per-feature toggle set was
always empty; (2) `appMode` was pinned to the ceiling (`.advanced`) on every launch, with a single
documented writer that agreed; (3) at the ceiling, every action's minimum-mode requirement was at
most `.advanced`, so the gate's own comparison could never deny. Nothing became reachable that was
not already reachable: the gate's two `evaluate` branches, `GatedPumpWrite.requiredMode`, the
`AccessPolicy.ModeGateContext` struct and `Context.modeContext`, the `DenialReason` cases the gate
alone produced, `SettingsTiers.swift` (both enums, whole), the `SettingsCatalog` mode/tier axis (the
35 descriptors' per-row minimum-mode filter, which had zero production readers), and the
`activeMode` phone→remote wire field (an emit-only field no remote consumed) are all gone together,
in one commit, so no reader is ever left describing a system that no longer exists. The
`AccessPolicy` / `GatedPumpWrite` / `BolusGate` evaluators' surviving gates (child mode, phone/remote
read-only, per-surface remote-bolus enable, the Garmin passcode gate, and pump capability) are
**byte-identical**: removing the mode axis changed which surfaces were ever gated by it, never how
any other check is evaluated. Preserved on the `dev/mode-selector` branch. Named suites:
`BolusMathParityTests`, the relevant `*ScopeGuard` suites, `KeyboardShortcutDoseGuardTests`.

### 6. stacking-guard-hide  (Phase 8; **RETIRED**)
Retired: the `stackingGuardFrictionEnabled` pin and the whole escalated-friction UI it gated
(`sgReenter`/`sgConfirmExtra` state, their dialogs, `reenterMatches`, `standardConfirmRoute`, the
`StandardConfirmRoute` enum) are deleted. **Correction to this gate's original description above:**
while the pin existed, the previous text here claimed *"the guard still runs and still
blocks/decides exactly as before; only its disclosure UI is hidden"* — that was false. With the
pin force-set false, `sg3aAppliedFriction` already collapsed every escalated tier to `.disclose`,
and `.disclose` never gated anything: no SG text rendered and no SG tier blocked delivery. The
escalated tiers were already fully inert before this retirement, which is what made deleting them
behavior-free. Retiring this gate is honestly "giving up the *option* to re-arm friction the app
was not applying" — not "removing dead code that was still protecting something."
`sg3aAppliedFriction` now returns `.disclose` unconditionally instead of reading the pin.
`Packages/faBolusCore/Sources/faBolusCore/StackingGuard.swift` itself is **not touched** —
`StackingGuard.escalation`'s own computation, `StackingGuardTests`, and the retargeted
`StackingGuardDeliverInvariantTests` stay **byte-identical and green**. Preserved on the
`dev/stacking-guard` branch.

### 7. alert-rules-engine-removal  (Phase 7, complete)
The one row that becomes a real removal rather than a pure runtime gate. **§6d precondition:** before
deleting the custom-rule path (`AlertRulesView.swift` + the rules engine), confirm that **no safety
alert routes through the custom-rule path**: only non-safety convenience auto-rules may. §6d PASSED
(07-05-PLAN.md) and the custom-rule engine has since been deleted from `main` (preserved on
`dev/alert-rules`); the glucose LOW/HIGH/urgent-low safety alerts and the core safety trio
(pump-disconnect / CGM-data-loss / bolus-reconciliation) never routed through it and remain on `main`,
unaffected. Named check: the alert-routing audit + the alert suites stay green; no safety alert lost its
delivery path.

---

## The assembled phase exit gate (INV-01 / INV-02 / INV-03; D-09)

Every phase (0 through 9.5) runs this **identical** sequence at its exit gate, assembled from the
reusable pieces this capstone stood up. Run from the faBolus repo root:

```bash
# (1) TAG CURRENCY: baseline annotated + ancestor + not-behind on all 3 repos
./scripts/verify-pre-narrow-tags.sh

# (2) DOSE/SIGNED RE-PROOF: the cross-branch byte-identity freeze is retired (see the top of this
#     doc). The dose re-proof is the TandemKit JDK-21 oracle byte-parity run plus the named suites in
#     step (3) below — there is no standalone script to invoke here.

# (3) GREEN MAIN + full safety suite
swift test --package-path Packages/faBolusCore            # BolusMathParity + oracle-parity + guards
./scripts/generate-project.sh >/dev/null                  # default gates present (byte-identical spec)
./scripts/test-ios.sh                                     # full app XCTest (D-09 *ScopeGuard/*BoundaryTests/
                                                          #   KeyboardShortcutDoseGuardTests), or
                                                          #   -only-testing:faBolusAppTests/SettingsCatalogTests
                                                          #   when no app/dose source was touched
./scripts/check-schema-drift.sh                           # RemoteCommand ↔ schema (faBolus + faBolusGarmin)
# TandemKit: `swift test` in the TandemKit repo, byte-exact cliparser-JAR oracle parity (INV-03)

# (4) NO-DANGLING-REFS (§6c): CompileGateAudit helper in SettingsCatalogTests (green; nothing orphaned)
# (5) PER-ITEM BOUNDARY: each new compile toggle strips its surface at =0, present at default
# (6) NO-GO for real insulin unchanged; nothing marked verified.
```

**Cost note (no-op phases):** when a phase touches **no** app/dose source (e.g. Phase 0, which only
adds build-config, scripts, tests, and docs), the full `test-ios.sh` result is definitionally unchanged
from the known-green milestone baseline; run the targeted `-only-testing:faBolusAppTests/SettingsCatalogTests`
plus `swift test --package-path Packages/faBolusCore` rather than burning a full ~10-minute rebuild to
prove a no-op. Any phase that DOES touch app/dose source runs the full suite.

**Namespace note:** sub-branches live under `dev/<surface>` (not `experimental/<surface>`). Git cannot
create `refs/heads/experimental/mac` while the `experimental` integration branch exists (ref
file-vs-directory conflict), so the owner ratified the `dev/` namespace in 00-01. The scripts and the
CI trigger glob (`dev/**`) both use it. The operative baseline tag is `pre-narrow/2026-08-20` (annotated;
supersedes the lightweight, ~130-commit-stale `pre-narrow/2026-08-18`).
