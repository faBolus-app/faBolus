# Narrow-main gates: the removal convention (Phase 0 capstone)

**Status:** convention + pattern spec. Phase 0 authors this; it implements **none** of the runtime
gates below. Later phases (1–9.5) implement removals against this single convention instead of
inventing their own shapes.

> **⛔ RETIRED — the cross-branch dose/signed byte-identity freeze does not resume.**
> The requirement that `Packages/faBolusCore`, `ios/faBolus/Data/AppModel.swift`, and
> `ios/faBolus/Data/TandemBackend.swift` stay **byte-identical between `main` and every `dev/<surface>`
> sub-branch** was paused in 2026-08 for the `AppModel` / `TandemBackend` god-object refactor, and it is
> now retired outright. It was never a byte-parity oracle — the enforced mode is a cross-branch
> `git diff` — and it is unrecoverably red: 21 sub-branches, 18 of them at 132 files / 6132+ / 9130−
> and 3 more at 129 files with different totals, so a re-baseline would be per-branch and would prove
> nothing about wire bytes. Nothing should be replayed across the sub-branches to satisfy it.
>
> **The dose re-proof that replaces it, for every phase:** the TandemKit **JDK-21 cliparser-JAR oracle
> byte-parity** run (INV-03) plus the named suites — `BolusMathParity`, `GatedPumpWrite`, `AccessPolicy`,
> `StackingGuard`, `DeliverySurfaceOutcomeGuard`, `LedgerBlockPrecedence`, `R3CLedgerFault`,
> `PhoneWidgetDoubleDose`, `TandemDeliveryOutcome` — and `check-schema-drift.sh`. See the list at the end.

The v0.5.0 "narrow main" milestone subtracts surfaces from `main` one at a time. Every removal takes
**exactly one of two shapes**, and which shape is allowed is decided by whether the surface is
dose-adjacent:

| Shape | Used for | Mechanism | The invariant it must preserve |
|-------|----------|-----------|--------------------------------|
| **Compile gate** (`FABOLUS_*` + `# >>> TAG … # <<< TAG`) | Self-contained, **non**-dose surfaces (a whole target, package, or source-dir set) | `scripts/generate-project.sh` strips the block from a copy of `project.yml` before `xcodegen` runs | The surface is absent at `=0`, present at default; the default spec stays byte-identical to today |
| **Runtime gate** (settings-forced-value + UI-hide) | **Dose-adjacent** surfaces | Force the existing setting to its safe value + hide the UI; the evaluator/core is **NOT touched** | The dose/signed evaluator/core is **not edited at all**; the oracle + named suites re-prove it (INV-03) |

**Why dose-adjacent surfaces get a runtime gate, never a compile-deletion (D-03):** every one of the
7 hides below touches a file in the dose-path set at the end of this document (`AccessPolicy`,
`GatedPumpWrite`, `StackingGuard`, `deliverExtendedBolus`, the `PumpResponseApplier` time anchor). A
`#if FABOLUS_*` around any of it edits the dose/signed core in order to remove a *surface*, which is the
one mechanism these gates exist to avoid. So a dose-adjacent surface is removed by **forcing its setting
off and hiding its UI**, leaving the evaluator untouched and its named test suite green. Compile-deleting
dose-adjacent code before its dedicated, oracle-re-run phase is Pitfall 5.

---

## The 7 dose-adjacent runtime gates (documentation only; implemented in Phases 7/8)

Each spec below is the same shape: **settings-forced-value + UI-hide; evaluator/core byte-identical;
the named test suite stays green.** Phase 0 flips none of them.

### 1. extended-bolus-hide  (Phase 8)
Force `extendedBolusEnabled` OFF and hide the extended-bolus section of `BolusEntryView` plus its
Settings row. The delivery core (`AppModel.deliverExtendedBolus` and `GatedPumpWrite`) stays
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
**keep the read-side `PumpResponseApplier` time anchor byte-identical**: the app must still interpret
pump-reported timestamps correctly even when it no longer *writes* the clock. This is the one gate with
an explicit "keep the read side" caveat; removing the anchor would corrupt dose/IOB timing. Named
suites: `BolusMathParityTests`, the `GatedPumpWrite` guards.

### 4. units-mgdl-lock  (Phase 8)
Force `glucoseDisplayUnit = .mgdl` and hide the unit picker. Dose math is already mg/dL-canonical and
unit-internal, so the evaluator/core is **byte-identical**; this gate is purely a display-surface
lock. Named suite: `BolusMathParityTests` (proves the dose path never read the display unit).

### 5. mode-lock-advanced  (Phase 8)
Pin `appMode = .advanced` (settings-forced-value) and hide the mode picker in `ModeViews.swift`. The
`AccessPolicy` / `GatedPumpWrite` / `BolusGate` evaluators stay **byte-identical**: locking the mode
changes which surfaces are shown, never how a command is authorized. Named suites: `BolusMathParityTests`,
the relevant `*ScopeGuard` suites, `KeyboardShortcutDoseGuardTests`.

### 6. stacking-guard-hide  (Phase 8)
Suppress the SG1/SG2/SG3a stacking-guard disclosures in `BolusEntryView` (a UI-hide of the escalating
friction presentation). `StackingGuard.swift` and its `StackingGuardDeliverInvariantTests` /
`StackingGuardTests` stay **byte-identical and green**; the guard still runs and still blocks/decides
exactly as before; only its disclosure UI is hidden. Hiding the disclosure must never weaken the guard.

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

## The assembled phase exit gate (INV-02 / INV-03; D-09 — INV-01 retired, see the banner)

Every phase (0 through 9.5) runs this **identical** sequence at its exit gate, assembled from the
reusable pieces this capstone stood up. Run from the faBolus repo root:

```bash
# (1) TAG CURRENCY: baseline annotated + ancestor + not-behind on all 3 repos
./scripts/verify-pre-narrow-tags.sh

# (2) DOSE RE-PROOF: the TandemKit JDK-21 cliparser-JAR oracle byte-parity run (INV-03) plus the named
#     dose suites listed at the end of this doc. There is no cross-branch byte-identity step any more —
#     see the RETIRED banner at the top. Run in the TandemKit repo, with the cliparser JAR built:
#       ./gradlew :cliparser:shadowJar   (in vendor/pumpx2-oracle)   &&   swift test

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

---

## The dose-path file set (the membership marker)

Every removal or simplification phase decides **how hard its re-proof has to be** by asking one question:
does the change touch a dose-path file? This list is the answer and it is the canonical definition. It was
previously buried inside `scripts/check-dose-byte-identity.sh`, which the cleanup programme removes along
with the retired freeze; the list moves here so the marker outlives the script.

- **`Packages/faBolusCore/`** — the whole package: `BolusMath`, the oracle-parity fixtures,
  `GatedPumpWrite`, `AccessPolicy`, `StackingGuard`, `RemoteCommand` — the signed/dose core.
- **`ios/faBolus/Data/AppModel.swift`** — the app-side dose and delivery paths.
- **`ios/faBolus/Data/TandemBackend.swift`** — the signed pump-write backend.

**Membership is by file, not by symbol.** Any edit inside one of the three gets the full dose re-proof —
the JDK-21 oracle run plus the named suites in the banner at the top — whether or not the edited lines
look dose-adjacent. That is deliberately over-inclusive: `Packages/faBolusCore` is the whole signed/dose
core plus everything filed alongside it. Narrowing the rule to *"any file declaring a type read by
`AccessPolicy.evaluate`, `GatedPumpWrite`, `BolusMath`, `StackingGuard` or `RemoteBolusLedger`"* is the
right shape but is **an open owner question**, not something a phase may assume; until it is answered, the
three entries above are the rule.

⚠ **The oracle is version-blind today, and it is now the only dose proof there is.** In TandemKit,
`Tests/TandemMessagesTests/OracleRunner.swift:53-56` computes `isAvailable` as "the JAR exists **and** a
`java` binary is executable" — with no version check — while `:44-49` prefers an unpinned homebrew
`openjdk@21` path and otherwise falls back to `/usr/bin/java`. The JAR's `Main.class` is class-file major
58 (Java 14), so on an older JVM every parity suite throws and is misattributed as a byte-parity failure;
and `Tests/TandemMessagesTests/OracleAvailabilityGateTests.swift:12-13` opens with
`if OracleRunner.isAvailable { return }`, so the gate that exists to catch an unavailable oracle cannot see
a present-but-wrong one.
**That fix runs FIRST, before any phase of the cleanup programme** — `isAvailable` gains a JVM-version
requirement (≥ 21, or an assertion on the loaded class-file version), the availability gate gains a case
that fails on a present-but-wrong Java, and the CI workflow asserts the version too so a runner without the
unpinned homebrew path fails loudly instead of silently skipping parity. Until that lands, an oracle pass is
not a dose re-proof unless the JVM was confirmed by hand.
