# LoopPowerPack — Vendored Upstream Provenance

This tree holds MIT-licensed feature source copied in from the **LoopPowerPack** fork of Loop, adapted
behind thin faBolus adapters. Vendored source does **not** auto-merge (D-01): the drift detector
surfaces upstream fixes for **manual** application only.

## Pinned upstream

| Field | Value |
|---|---|
| Fork | `LoopPowerPack/Loop` |
| Local mirror | `/Users/zgranowitz/Code/zgranowitz/LoopPowerPack-Loop` |
| Pinned commit (SHA) | `ad4c4d498f936a25e22dd3a8dc93354138458509` (short `ad4c4d4`, `feat/AllFeatures`) |
| License | MIT (© 2015 Nathan Racklyeft, © 2016 LoopKit Authors; SiteAtlas © 2026 LoopKit Authors and Taylor Patterson) |

The `feat/*` branches are **cumulative** — features are isolated by DIRECTORY, not by branch diff.

## Per-feature vendor table

| Feature | Vendored path | Upstream source dir | Status |
|---|---|---|---|
| SiteAtlas | `SiteAtlas/SiteAtlas_Models.swift` | `Loop/Models/SiteAtlas/` | vendored (models only, this slice — 09.18a-01) |
| LoopInsights | `LoopInsights/LoopInsights_EndoReportModels.swift`, `LoopInsights/LoopInsights_CaffeineTracker.swift`, `LoopInsights/LoopInsights_AlcoholTracker.swift`, `LoopInsights/LoopInsights_CaregiverDigestService.swift` | `Loop/Models/LoopInsights/`, `Loop/Services/LoopInsights/` | vendored (benign report DTO shapes ONLY — the analysis-period enum + reduced aggregated-stats struct cherry-picked from `LoopInsights_Models.swift`; AI/advisor/Phase5/biometric/LoopKit-typed fields stripped, D-04/D-14 — 09.18d-01. PLUS the two benign STANDALONE trackers — 09.18d-02: `CaffeineTracker` (log/remove/update/current-state + entry shape; `buildCaffeinePromptContext` + HealthKit sync OMITTED) and `AlcoholTracker` (log/remove/update/current-state + entry shape; `computeHypoRisk` delayed-hypo MEDICAL INFERENCE + `hypoRisk*` state fields + `buildAlcoholPromptContext` OMITTED — D-14). Both re-point persistence from the mirror's UserDefaults to the faBolus SwiftData `GlucoseHistoryStore` (`ingest*`/`caffeine|alcohol(in:)`/`delete*`), so each file's provenance marker reads adapted rather than ported; descriptive readouts only, no risk/directive, no dose symbol). PLUS the benign caregiver-digest builder — 09.18d-03: `CaregiverDigestService` cherry-picks ONLY the `metricRow` summary-assembly, re-expressed as plain text and fed by the faBolus `FaBolusInsightsReport` (`FaBolusInsightsAggregator`) + `InsightsGlucoseUnitContext` in place of the LoopKit `DataAggregator`/`GlucoseUnitContext`; ALL LoopKit stores + `UserNotifications` reminder scheduling + recipient/delivery persistence + HTML email body + MessageUI + the status-sentiment prose OMITTED (D-14/D-15). A past-tense records summary only, negative-grepped by `CaregiverDigestContentTests` for banned directive tokens (§13). NEVER vendored whole (Coordinator/AI/advisor/chat/dashboard/trends/importers/background-monitors/Phase5 EXCLUDED). Named `LoopInsights_EndoReportModels.swift`, NOT `LoopInsights_Models.swift` (the latter is on the 09.18a `LoopInsightsExclusionGuardTests` denylist — benign structs are re-created, not bulk-vendored); the tracker basenames `LoopInsights_CaffeineTracker.swift`/`LoopInsights_AlcoholTracker.swift` are on that guard's benign INCLUDE allow-list. The endo-report aggregator (`FaBolusInsightsAggregator`, HistoryStore) + PDF page (`EndoReportPage`) + view (`LoopInsights_EndoReportView`) + tracker log views (`LoopInsights_CaffeineLogView`/`LoopInsights_AlcoholLogView`) are faBolus REWRITES over `GlucoseHistoryStore` / SwiftUI `ImageRenderer` / faBolusDesign (D-15), not vendored — LoopKit `DataAggregator` + the HTML→UIGraphics generator are NOT ported. 09.18d code-review hardening deltas (local, NOT a re-vendor): `CaffeineTracker`/`AlcoholTracker` dropped the grep-verified-dead `currentState`/`CaffeineState`/`AlcoholState`/`update(id:)` descriptive current-level surface (IN-01 — the alcohol variant also carried the M-01 unbounded metabolism-pool math), so both files now expose only `entries`/`log`/`remove`; and the triplicated `sourceID = "app.loopInsightsTrackers"` literal is hoisted to the single shared `GlucoseHistoryStore.loopInsightsTrackerSourceID` (IN-02) that both trackers and `AppModel` reference. |
| FoodFinder | `FoodFinder/FoodFinder_OpenFoodFactsService.swift`, `FoodFinder/FoodFinder_Models.swift`, `FoodFinder/FoodFinder_ScannerService.swift`, `FoodFinder/FoodFinder_ScannerView.swift`, `FoodFinder/FoodFinder_AIProviderConfig.swift`, `FoodFinder/FoodFinder_AIServiceAdapter.swift` | `Loop/Services/FoodFinder/`, `Loop/Models/FoodFinder/`, `Loop/Views/FoodFinder/` | vendored (pure OFF service + models + barcode scanner + BYO-key AI config/adapter; manual adapter, no auto-merge — 09.18c-01/02/03). OFF adapter deltas: production `world.openfoodfacts.org` + `api/v3` barcode path + faBolus User-Agent (mirror's staging `.net`/`api/v2`/`Loop-iOS-Diabetes-App` UA corrected); text search kept on `cgi/search.pl` (.org); strict tolerant decode + 1 MB byte cap; DEBUG MockURLProtocol dropped; `Nutriments.carbohydrates` made optional (D-03). Scanner adapter deltas (09.18c-02, D-13): AVFoundation/Vision pipeline preserved; Loop `OSLog(category:)` convenience → standard `OSLog(subsystem:category:)` (no LoopKit dep); `BarcodeScanResult`/`BarcodeScanError` inlined into the service (mirror `FoodFinder_InputResults.swift` NOT vendored); camera-denied/no-device → `faBolusDesign.CameraPermissionFallbackView` (never a black view, manual entry never blocked); dropped Loop `.supportedInterfaceOrientations` modifier + "Loop" copy + simulated scan-stage theatrics. AI adapter deltas (09.18c-03, D-13): provider set REDUCED to Anthropic/OpenAI/Google only (Spoonacular OUT, A7); `withKeychainAPIKey()` → faBolus `FoodFinderAIKeyStore`; upstream UserDefaults extension + `AISettingsManager` dropped; `AIServiceAdapter` REWRITTEN self-contained over an injectable `URLSession` (upstream `AIServiceManager`/`AIFoodAnalysisService`/`FoodFinder_AIAnalysis`/Pre-Meal Advisor NOT vendored — D-13/D-14); Foundation/os.log only (no UIKit — image crosses as base64); rejected key (401/403) → distinct `.keyRejected`; 2 MB response byte cap; no dose symbol (D-18.1). 09.18c code-review hardening deltas (local, NOT a re-vendor): `FoodFinder_Models.servingSizeDisplay` now clamps an untrusted `serving_quantity` in Double space before the `Int()` conversion (CR-03 crash guard) and derives the synthetic product id via `UInt(bitPattern:)` instead of `abs(hashValue)` (WR-02 `Int.min` trap); `FoodFinder_ScannerService` now guards `recentlyScannedBarcodes`/`isProcessingScan`/`lastValidFrameTime` behind an `NSLock` to make the `@unchecked Sendable` cross-queue claim honest (WR-01 data race) |

> BodyMap PNG graphics (`BodyMapFront.png` / `BodyMapBack.png`) are **NOT** vendored here — their MIT
> graphics-exception is unresolved and is deferred to 09.18a-04's human-verify checkpoint.

## Policy (D-01 / D-02)

1. **No auto-merge.** Each vendored file is adapted behind a faBolus adapter and will not silently take
   upstream changes. Upstream fixes are applied by hand after the drift detector flags them.
2. **Provenance marker.** Every vendored `.swift` file carries a one-line header naming the upstream
   fork, pinned SHA, and license (the exact marker token `scripts/check-sbom.sh` greps for), plus an
   `SBOM.md` row with an SPDX token.
3. **Drift detection.** `scripts/check-vendor-drift.sh` records a sorted `shasum -a 256` manifest of
   every tracked file under this tree (`.vendor-manifest.sha256`) and fails non-zero if any vendored
   byte changes without a manifest update (`--update`). This is a **source-tree integrity check**, NOT
   a schema-property check — deliberately distinct from `scripts/check-schema-drift.sh` (D-02).

## Re-vendoring from a new upstream SHA

1. Copy the new upstream file(s) in, re-adding the provenance marker line with the new SHA.
2. Update the pinned SHA in this file and the `SBOM.md` / `THIRD_PARTY.md` / `NOTICE.md` rows.
3. Run `bash scripts/check-vendor-drift.sh --update` to regenerate `.vendor-manifest.sha256`.
4. Re-apply any faBolus adapter deltas by hand; never auto-merge.
