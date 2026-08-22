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
   excluded upstream files — vacuously true whether or not the 8 benign kept-then-removed files exist).
6. Left `AppModel.therapyInsights()` (`AppModel.swift:1409-1414`) and `SmartAssist.swift` (35 lines)
   COMPLETELY untouched — no dose-file edit, no `SmartAssist.swift` edit. Both become orphaned-but-
   compiled the moment `DataHistoryView.swift`'s consumer is gone; ZERO stub work was needed for this
   surface (RESEARCH: "No stub work is actually required").
7. Authored a new `RetrospectiveAbsenceGuardTests.swift` on `main` (source-scans `DataHistoryView.swift`
   for the absence of `TherapyInsightItem`/`therapyInsights`) — this branch has no such file (it
   predates the removal); do not port it over on reintegration, it asserts the opposite of what this
   branch's tree looks like.

## Reintegration path

1. Re-apply the `insights` `@State` var, the "Insights" `Section`, and the `reload()` assignment line
   into `DataHistoryView.swift` from this branch's copy (a hand merge, not a blind overwrite, if `main`
   has moved since the cut).
2. Cherry-pick (or manually re-apply) the 9 `Views/LoopInsights/*` + `Vendor/LoopPowerPack/LoopInsights/*`
   files from this branch's tip.
3. Re-apply the 4 `AppSettings.swift` properties + their `init`-restore lines, and the 3
   `caregiverDigestNoticeAckAt`-family members (all 4+3=7 members total), from this branch's copy.
4. Re-apply `EndoReportPDFTests.swift` from this branch's tip.
5. Delete the post-removal `RetrospectiveAbsenceGuardTests.swift` case (it asserts absence).
6. Do NOT touch `AppModel.swift` or `SmartAssist.swift` — neither was ever edited by the removal;
   reintegration needs no change to either.
7. Run the full exit gate (`check-dose-byte-identity.sh`, `xcodebuild build`, full test suite) to confirm
   the re-added surface compiles and nothing else regressed.
