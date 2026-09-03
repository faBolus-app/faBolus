# REINTEGRATION.md — dev/retrospective

## Feature preserved

The Retrospective insights display (Phase 09.18b/09.18d, FEAT-06): the `DataHistoryView.swift`
"Insights" section (dawn-phenomenon / recurring-lows / TIR pattern insights, `AppModel.therapyInsights()`
→ `SmartAssist.insights` → `faBolusCore.PatternInsights`), PLUS the separate `Views/LoopInsights/*` (5
files) + `Vendor/LoopPowerPack/LoopInsights/*` (4 files) sub-features that happen to share the
"LoopInsights" name: the EndoReport PDF export, the caffeine/alcohol benign trackers, and the
caregiver-digest PHI-sharing surface — each gated behind its OWN (Smart-Assist-submenu, Phase-4-owned)
toggle.

## State at removal

This branch was cut from `pre-narrow/2026-08-20` (the annotated, current baseline tag) — the pristine
pre-removal tip, identical to `main` before Phase 7 Plan 02 (07-02, P-B) ran. `main` has since:

1. Deleted `DataHistoryView.swift`'s `insights` `@State` var (`:12`), the `if !insights.isEmpty { ... }`
   "Insights" `Section` (`:37-46`), and the `insights = model.therapyInsights()` line inside `reload()`
   (`:122`). This branch's copy still has all three — the actual Retrospective-insights DISPLAY surface,
   per the RESEARCH correction (`Views/LoopInsights/*` is a separate set of sub-features, not this one).
2. `git rm`'d the 9 `Views/LoopInsights/*` + `Vendor/LoopPowerPack/LoopInsights/*` files (EndoReport PDF,
   caffeine/alcohol log views + engines, caregiver-digest view + service).
3. Fully deleted the 4 backing `AppSettings.swift` properties (`endoReportEnabled`,
   `caffeineTrackerEnabled`, `alcoholTrackerEnabled`, `caregiverDigestEnabled`) + their 4 `init`-restore
   lines — dead once the 9 files above AND `SmartAssistSettingsView.swift` (Phase 4's earlier removal)
   are both gone; none was ever a `SettingsCatalog` row or in `backupSnapshot`.
4. Rule 1/2 (same idiom as 07-01's FoodFinder-AI members): also deleted the 3 now-orphaned
   `caregiverDigestNoticeAckAt`/`hasAcknowledgedCaregiverDigestNotice`/`acknowledgeCaregiverDigestNotice()`
   members — their only reader was the Phase-4-deleted `SmartAssistSettingsView.swift`, not the caregiver
   digest view itself (a pre-existing gap this task's own deletion surfaced, not a plan-listed file).
5. `git rm`'d `EndoReportPDFTests.swift` (tests the deleted PDF render path). Kept
   `LoopInsightsExclusionGuardTests.swift` completely UNMODIFIED (it only asserts the ABSENCE of
   excluded upstream files — vacuously true whether or not the 8 benign kept-then-removed files exist;
   remains a KEEP as of Phase 31, C-KEPT, still non-vacuous — 8 of 11 `LoopInsights` matches survive).
6. **Phase 31 unit 3 (31-03, this correction) deleted the rest of the chain outright.** `main` no
   longer has `AppModel.therapyInsights()`, `SmartAssist.swift` (the file that held `TherapyInsightItem`
   + `enum SmartAssist` — it died whole once Phase 31 unit 2 had already removed its other member,
   `EatingAlert`), `Packages/HistoryStore/Sources/HistoryStore/FaBolusInsightsAggregator.swift`,
   `Packages/faBolusCore/Sources/faBolusCore/InsightsGlucoseUnitContext.swift`, or
   `Packages/faBolusCore/Sources/faBolusCore/PatternInsights.swift` — none survive on `main`, all four
   plus `SmartAssist.swift` and `AppModel.therapyInsights()` are on this branch's tip, untouched.
   ⚠ Supersedes the earlier "COMPLETELY untouched, ZERO stub work needed" note below, which was accurate
   only up to Phase 31 unit 2 — as of unit 3 there IS work required (see the reintegration path).
7. No file named `RetrospectiveAbsenceGuardTests.swift` was ever authored on `main` — the note
   previously here claiming one was is corrected; it never existed in `git ls-files` at any point in
   this branch's history against `main`. The absence-guard `main` actually carries for this surface is
   `ios/faBolusAppTests/FeatureSurfaceAbsenceGuardTests.swift` (Phase 31 unit 3, D-23), which scans
   `GlucoseChartView.swift` for the absence of `GraphDetailReadout` and asserts
   `Packages/faBolusCore/Sources/faBolusCore/GraphDetailReadout.swift` does not exist on disk — it does
   not scan `DataHistoryView.swift` or reference `TherapyInsightItem`/`therapyInsights` at all, so there
   is no case to delete on reintegration for this branch's feature.

## GraphDetailReadout dependency (owner decision 2026-08-31, D-21)

This branch's tree (cut from the same pre-narrow baseline as `dev/graph-detail`) also carries
`ios/faBolus/Views/GraphDetailView.swift` and the un-carved `GlucoseChartView.swift` scrubber section,
both of which reference `Packages/faBolusCore/Sources/faBolusCore/GraphDetailReadout.swift`.
`GraphDetailReadout.swift` was deleted from `main` outright by Phase 31 unit 3 (no compile shim) — so
**this branch fails to compile at its next sync from `main` independent of whether the Retrospective
feature itself is reintegrated.** `GraphDetailReadout.swift` must return to `main` (via `dev/graph-detail`
reintegrating, or a standalone re-add) before or alongside this branch's own reintegration; see
`dev/graph-detail:REINTEGRATION.md` for that file's own restore path. `BRANCHES.md` records that
`experimental` needs the same fix-up on its next sync, for the same reason.

## Reintegration path

1. Re-apply the `insights` `@State` var, the "Insights" `Section`, and the `reload()` assignment line
   into `DataHistoryView.swift` from this branch's copy (a hand merge, not a blind overwrite, if `main`
   has moved since the cut).
2. Cherry-pick (or manually re-apply) the 9 `Views/LoopInsights/*` + `Vendor/LoopPowerPack/LoopInsights/*`
   files from this branch's tip.
3. Re-apply the 4 `AppSettings.swift` properties + their `init`-restore lines, and the 3
   `caregiverDigestNoticeAckAt`-family members (all 4+3=7 members total), from this branch's copy.
4. Re-apply `EndoReportPDFTests.swift` from this branch's tip.
5. There is no post-removal absence-guard case naming this surface to delete (see item 7 above) — the
   file the earlier version of this note described was never authored.
6. **Re-apply, from this branch's tip:** `AppModel.therapyInsights()`, `SmartAssist.swift` (whole file —
   `TherapyInsightItem` + `enum SmartAssist`), `Packages/HistoryStore/Sources/HistoryStore/
   FaBolusInsightsAggregator.swift` (+ its tests), `Packages/faBolusCore/Sources/faBolusCore/
   InsightsGlucoseUnitContext.swift` (+ its tests), and `Packages/faBolusCore/Sources/faBolusCore/
   PatternInsights.swift` (+ its tests) — all six deleted from `main` by Phase 31 unit 3. Re-apply
   `GraphDetailReadout.swift` (+ its tests) too if `dev/graph-detail` has not already restored it (see
   the dependency note above) — this branch's own scrubber-adjacent files need it independent of the
   Retrospective feature.
7. Run the full exit gate (`xcodebuild build`, full test suite, TandemKit JDK-21 oracle) to confirm the
   re-added surface compiles and nothing else regressed. `check-dose-byte-identity.sh` no longer exists
   on `main` (Phase 34 wave 1, D-47) — it is not part of the gate to re-run.
