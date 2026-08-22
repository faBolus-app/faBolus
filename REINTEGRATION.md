# REINTEGRATION.md — dev/graph-detail

## Feature preserved

The GraphDetailView scrubbable-readout overlay (Phase 09.18b, FEAT-02): `ios/faBolus/Views/GraphDetailView.swift`
(the `GraphDetailReadoutModel`/`GraphDetailViewModel`/`GraphDetailCard` types, whole file), the
`GlucoseChartView.swift` scrubber section (state vars, `.chartOverlay`/`.sensoryFeedback` wiring, the
`detailViewModel`/`a11yValue`/`scrubberLayer`/`resolvedHeartRate` functions), the 3 view params that fed
it (`basalUnitsPerHour`, `heartRateContextEnabled` the PARAM, `latestGarminHeartRate`), the matching 3
arguments at both `GlucoseChartView(...)` call sites in `MainHUDView.swift`, and the `graphDetailEnabled`
device-local settings toggle in `AppSettings.swift`.

## State at removal

This branch was cut from `pre-narrow/2026-08-20` (the annotated, current baseline tag) — the pristine
pre-removal tip, identical to `main` before Phase 7 Plan 02 (07-02, P-B) ran. `main` has since:

1. `git rm`'d `ios/faBolus/Views/GraphDetailView.swift` (whole file, 194 lines) — this branch's copy is
   untouched.
2. Surgically carved the scrubber section out of `GlucoseChartView.swift`: the scrubber state vars
   (`scrubX`, `scrubbedPointDate`, `a11yIndex`), the `.chartOverlay`/`.sensoryFeedback` wiring (the
   `if AppSettings.shared.graphDetailEnabled { scrubberLayer(...) }` block + the `.sensoryFeedback`
   line), and the entire "GraphDetailView scrubber" `// MARK:` section (`detailViewModel`, `a11yValue`,
   `scrubberLayer(proxy:size:)`, `resolvedHeartRate(at:)`). The chart itself (glucose/IOB/bolus plot)
   is untouched and still renders. This branch's copy has the full scrubber.
3. Deleted the 3 now-orphaned `GlucoseChartView` params (`basalUnitsPerHour`, `heartRateContextEnabled`
   the PARAM, `latestGarminHeartRate`) and correspondingly dropped the matching 3 arguments from BOTH
   `GlucoseChartView(...)` call sites in `MainHUDView.swift` (a caller-side edit required for
   compilation, not optional — RESEARCH NEW FINDING). This branch's copies of both files still have all
   3 params/args. `ios/faBolus/Views/RemoteControlView.swift` (a 3rd call site RESEARCH named) had
   already been removed by Phase 3 before this plan ran, on both `main` and this branch — no edit was
   needed or possible there.
4. Fully `git rm`'d the `graphDetailEnabled` device-local settings property (declaration + its
   `init`-restore line) from `AppSettings.swift` — it was read by NOTHING outside the deleted scrubber
   section (never a `SettingsCatalog` row, never in `backupSnapshot`), so it was safe to delete outright
   rather than freeze. This branch's copy still has the property. Two adjacent doc-comments (on the
   KEPT `heartRateContextEnabled` SETTING and the `endoReportEnabled` property) that cross-referenced
   `graphDetailEnabled`/`GraphDetailView` by name were reworded to drop the now-dangling mention — purely
   textual, no behavior change; this branch's copies still say the original text.
5. Left `Packages/faBolusCore/Sources/faBolusCore/GraphDetailReadout.swift` (72 lines) COMPLETELY
   byte-identical — it is inside `Packages/faBolusCore`, a `DOSE_PATHS` entry, so the whole package must
   stay byte-identical across every branch even though its only 2 consumers (the deleted view + the
   carved scrubber section) are both gone on `main`. It is orphaned-but-compiled on `main`, exactly as
   it is on this branch.
6. Left `AppSettings.shared.heartRateContextEnabled` the SETTING (distinct from the deleted view PARAM
   of the same name) and its `AppModel.swift:115` reader (background HR sensing) COMPLETELY untouched —
   that is HEALTH-01/Phase-5 territory, not FEAT-02.
7. Authored a new `FeatureSurfaceAbsenceGuardTests.swift` on `main` (source-scans `GlucoseChartView.swift`
   for the absence of `scrubber`/`GraphDetailReadout` and confirms `GraphDetailView.swift` is absent) —
   this branch has no such file (it predates the removal); do not port it over on reintegration, it
   asserts the opposite of what this branch's tree looks like.

## Reintegration path

1. Cherry-pick (or manually re-apply) `ios/faBolus/Views/GraphDetailView.swift` from this branch's tip
   back onto the target tree.
2. Re-apply the scrubber section + the 3 params into `GlucoseChartView.swift` from this branch's copy
   (the file otherwise evolved independently on `main` since the cut — a hand merge, not a blind
   overwrite, is required if `main` has moved).
3. Re-apply the matching 3 arguments at both `GlucoseChartView(...)` call sites in `MainHUDView.swift`.
4. Re-apply the `graphDetailEnabled` property declaration + its `init`-restore line into `AppSettings.swift`,
   and revert the two doc-comment rewordings on `heartRateContextEnabled`/`endoReportEnabled` if desired
   (cosmetic only, safe to leave either way).
5. Delete the post-removal `FeatureSurfaceAbsenceGuardTests.swift` FEAT-02 case (it asserts absence).
6. Do NOT touch `Packages/faBolusCore/Sources/faBolusCore/GraphDetailReadout.swift` — it was never
   removed from `main`, only its consumers were; reintegration needs no change there.
7. Run the full exit gate (`check-dose-byte-identity.sh`, `xcodebuild build`, full test suite) to confirm
   the re-added surface compiles and nothing else regressed.
