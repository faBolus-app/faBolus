# Narrow-main gates — the removal convention (Phase 0 capstone)

**Status:** convention + pattern spec. Phase 0 authors this; it implements **none** of the runtime
gates below. Later phases (1–9.5) implement removals against this single convention instead of
inventing their own shapes.

The v0.5.0 "narrow main" milestone subtracts surfaces from `main` one at a time. Every removal takes
**exactly one of two shapes**, and which shape is allowed is decided by whether the surface is
dose-adjacent:

| Shape | Used for | Mechanism | The invariant it must preserve |
|-------|----------|-----------|--------------------------------|
| **Compile gate** (`FABOLUS_*` + `# >>> TAG … # <<< TAG`) | Self-contained, **non**-dose surfaces (a whole target, package, or source-dir set) | `scripts/generate-project.sh` strips the block from a copy of `project.yml` before `xcodegen` runs | The surface is absent at `=0`, present at default; the default spec stays byte-identical to today |
| **Runtime gate** (settings-forced-value + UI-hide) | **Dose-adjacent** surfaces | Force the existing setting to its safe value + hide the UI; the evaluator/core is **NOT touched** | The dose/signed evaluator/core is **byte-identical across every branch** (INV-01/INV-03) |

**Why dose-adjacent surfaces get a runtime gate, never a compile-deletion (D-03):** every one of the
7 hides below touches code the `check-dose-byte-identity.sh` invariant protects (`AccessPolicy`,
`GatedPumpWrite`, `StackingGuard`, `deliverExtendedBolus`, the `PumpResponseApplier` time anchor). A
`#if FABOLUS_*` around any of it would make the dose/signed core diverge between branches — the exact
drift the exit gate forbids. So a dose-adjacent surface is removed by **forcing its setting off and
hiding its UI**, leaving the evaluator byte-identical and its named test suite green. Compile-deleting
dose-adjacent code before its dedicated, oracle-re-run phase is Pitfall 5.

---

## The 7 dose-adjacent runtime gates (documentation only — implemented in Phases 7/8)

Each spec below is the same shape: **settings-forced-value + UI-hide; evaluator/core byte-identical;
the named test suite stays green.** Phase 0 flips none of them.

### 1. extended-bolus-hide  (Phase 8)
Force `extendedBolusEnabled` OFF and hide the extended-bolus section of `BolusEntryView` plus its
Settings row. The delivery core — `AppModel.deliverExtendedBolus` and `GatedPumpWrite` — stays
**byte-identical**; nothing about how an extended bolus is signed/delivered changes, the surface is
merely unreachable. Named suites that must stay green: `BolusMathParityTests`, the `GatedPumpWrite`
guards, `KeyboardShortcutDoseGuardTests`.

### 2. history-24h-lock  (Phase 8)
Cap `HistoryStore` retention (settings-forced-value on `historyRetentionDays`) and remove the
Data & History settings UI. The read path and any IOB/dose computation stay **byte-identical**; a gate
assertion confirms no IOB/dose read reaches back beyond 24h. Named suites: `BolusMathParityTests`,
`HistoryLogSyncDeliveryBoundaryTests`.

### 3. clock-sync-removal  (Phase 8)
Drop the `autoSyncPumpTime` write path (`GatedPumpWrite.syncTimeToNow`) and its settings UI, but
**keep the read-side `PumpResponseApplier` time anchor byte-identical** — the app must still interpret
pump-reported timestamps correctly even when it no longer *writes* the clock. This is the one gate with
an explicit "keep the read side" caveat; removing the anchor would corrupt dose/IOB timing. Named
suites: `BolusMathParityTests`, the `GatedPumpWrite` guards.

### 4. units-mgdl-lock  (Phase 8)
Force `glucoseDisplayUnit = .mgdl` and hide the unit picker. Dose math is already mg/dL-canonical and
unit-internal, so the evaluator/core is **byte-identical** — this gate is purely a display-surface
lock. Named suite: `BolusMathParityTests` (proves the dose path never read the display unit).

### 5. mode-lock-advanced  (Phase 8)
Pin `appMode = .advanced` (settings-forced-value) and hide the mode picker in `ModeViews.swift`. The
`AccessPolicy` / `GatedPumpWrite` / `BolusGate` evaluators stay **byte-identical** — locking the mode
changes which surfaces are shown, never how a command is authorized. Named suites: `BolusMathParityTests`,
the relevant `*ScopeGuard` suites, `KeyboardShortcutDoseGuardTests`.

### 6. stacking-guard-hide  (Phase 8)
Suppress the SG1/SG2/SG3a stacking-guard disclosures in `BolusEntryView` (a UI-hide of the escalating
friction presentation). `StackingGuard.swift` and its `StackingGuardDeliverInvariantTests` /
`StackingGuardTests` stay **byte-identical and green** — the guard still runs and still blocks/decides
exactly as before; only its disclosure UI is hidden. Hiding the disclosure must never weaken the guard.

### 7. alert-rules-engine-removal  (Phase 7)
The one row that becomes a real removal rather than a pure runtime gate. **§6d precondition:** before
deleting the custom-rule path (`AlertRulesView.swift` + the rules engine), confirm that **no safety
alert routes through the custom-rule path** — only non-safety convenience auto-rules may. Until that
confirmation passes, this is a UI-hide of `alertRules`, not a deletion. Named check: the alert-routing
audit + the alert suites stay green; no safety alert loses its delivery path.

---

## The assembled phase exit gate (INV-01 / INV-02 / INV-03; D-09)

Every phase (0 through 9.5) runs this **identical** sequence at its exit gate, assembled from the
reusable pieces this capstone stood up. Run from the faBolus repo root:

```bash
# (1) TAG CURRENCY — baseline annotated + ancestor + not-behind on all 3 repos
./scripts/verify-pre-narrow-tags.sh

# (2) DOSE/SIGNED BYTE-IDENTICAL — main vs every dev/<surface> sub-branch (empty diff)
./scripts/check-dose-byte-identity.sh

# (3) GREEN MAIN + full safety suite
swift test --package-path Packages/faBolusCore            # BolusMathParity + oracle-parity + guards
./scripts/generate-project.sh >/dev/null                  # default gates → present (byte-identical spec)
./scripts/test-ios.sh                                     # full app XCTest (D-09 *ScopeGuard/*BoundaryTests/
                                                          #   KeyboardShortcutDoseGuardTests) — or
                                                          #   -only-testing:faBolusAppTests/SettingsCatalogTests
                                                          #   when no app/dose source was touched
./scripts/check-schema-drift.sh                           # RemoteCommand ↔ schema (faBolus + faBolusGarmin)
# TandemKit: `swift test` in the TandemKit repo — byte-exact cliparser-JAR oracle parity (INV-03)

# (4) NO-DANGLING-REFS (§6c) — CompileGateAudit helper in SettingsCatalogTests (green; nothing orphaned)
# (5) PER-ITEM BOUNDARY — each new compile toggle strips its surface at =0, present at default
# (6) NO-GO for real insulin unchanged; nothing marked verified.
```

**Cost note (no-op phases):** when a phase touches **no** app/dose source (e.g. Phase 0, which only
adds build-config, scripts, tests, and docs), the full `test-ios.sh` result is definitionally unchanged
from the known-green milestone baseline — run the targeted `-only-testing:faBolusAppTests/SettingsCatalogTests`
plus `swift test --package-path Packages/faBolusCore` rather than burning a full ~10-minute rebuild to
prove a no-op. Any phase that DOES touch app/dose source runs the full suite.

**Namespace note:** sub-branches live under `dev/<surface>` (not `experimental/<surface>`). Git cannot
create `refs/heads/experimental/mac` while the `experimental` integration branch exists (ref
file-vs-directory conflict), so the owner ratified the `dev/` namespace in 00-01. The scripts and the
CI trigger glob (`dev/**`) both use it. The operative baseline tag is `pre-narrow/2026-08-20` (annotated;
supersedes the lightweight, ~130-commit-stale `pre-narrow/2026-08-18`).
