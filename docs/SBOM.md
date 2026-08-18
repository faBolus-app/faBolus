# Software Bill of Materials (faBolus, non-Nudge)

Machine-checkable provenance for every third-party / vendored component the faBolus Apple app ships or
builds against (audit L-01). `scripts/check-sbom.sh` fails CI if a local/vendored package is missing a
`LICENSE` file or a row here. The **faBolusNudge** advisory SDK is referenced here as an external pinned
dependency only. **NU-01/NU-02:** faBolusNudge now publishes its own **code-dependency** SBOM
(`SBOM.md` + `scripts/check-sbom.sh` in that repo). Its **model/dataset** inventory remains out of scope
here and is tracked in the separate Nudge remediation session.

Format per row: component · version/revision · SPDX license · source · how faBolus uses it.

## Local packages (in this repo)

| Component | Version | License (SPDX) | Source | Usage |
|---|---|---|---|---|
| faBolusCore | in-repo | MIT | `Packages/faBolusCore` | Pump/host-agnostic contracts, models, BolusMath, transports |
| faBolusDesign | in-repo | MIT | `Packages/faBolusDesign` | Shared §13 band-color tokens + icon+word BandIndicator primitive (depends on faBolusCore) |
| HistoryStore | in-repo | MIT | `Packages/HistoryStore` | SwiftData glucose/insulin/carb history |

## Vendored source (copied in, LoopKit lineage — all MIT)

| Component | Upstream | License (SPDX) | Source | Usage |
|---|---|---|---|---|
| G7SensorKit | LoopKit/G7SensorKit | MIT | `Packages/G7SensorKit` (LICENSE incl.) | Dexcom G7/ONE+ BLE decoders (passive) |
| DexcomG6Kit | LoopKit/CGMBLEKit | MIT | `Packages/DexcomG6Kit` | Dexcom G5/G6/ONE passive decoders |
| ShareClient | LoopKit/dexcom-share-client-swift | MIT | `Packages/ShareClient` (LICENSE incl.) | Dexcom Share follower core |
| LoopPowerPack (SiteAtlas) | LoopPowerPack/Loop @ ad4c4d4 | MIT | `ios/faBolus/Vendor/LoopPowerPack` | Vendored MIT feature source (infusion-site/CGM body-map tracker), adapted behind a thin faBolus adapter |
| LoopPowerPack (LoopInsights) | LoopPowerPack/Loop @ ad4c4d4 | MIT | `ios/faBolus/Vendor/LoopPowerPack/LoopInsights` | Vendored MIT report DTO shapes ONLY (benign analysis-period enum + reduced aggregated-stats struct for the endo-visit PDF); NEVER the whole dir (Coordinator/AI/advisor excluded, D-04/D-14). The aggregator + PDF render + view are faBolus rewrites over GlucoseHistoryStore / ImageRenderer (D-15), not vendored |

## Local path dependency (separate repo)

| Component | Version | License (SPDX) | Source | Usage |
|---|---|---|---|---|
| TandemKit | `../TandemKit` | MIT | github.com/faBolus-app/TandemKit | Tandem BLE protocol / auth / messages |

TandemKit in turn vendors (see its own `NOTICE`):

| Component | Upstream | License (SPDX) | Usage |
|---|---|---|---|
| pumpx2-oracle | jwoglom/pumpx2 (© James Woglom) | MIT | Reverse-engineered protocol reference + parity fixtures |
| Mbed TLS | Mbed-TLS/mbedtls | `Apache-2.0 OR GPL-2.0` | EC-JPAKE pairing |

## Ported / API-derived app-tree source (not a Package — lives in the app target)

CGM feed readers that originate from a documented upstream. `check-sbom.sh` scans the app tree for a
`Ported from` / `Adapted from` attribution comment and fails CI if such a file is not listed here with a
license token (§3.1 / plan Q4).

| Component | Upstream | License (SPDX) | Source | Usage |
|---|---|---|---|---|
| XDripAppGroupSource.swift | JohanDegraeve/xdrip-client-swift (© 2016 Mark Wilson) | MIT | `ios/faBolus/Data/Sources/XDripAppGroupSource.swift` | Passive reader of xDrip's "Share to Loop" App-Group JSON |
| LibreLinkUpSource.swift | community LibreLinkUp API — timoschlueter/nightscout-librelink-up (MIT) + libre-link-unofficial-api | MIT (API knowledge; independent Swift impl, no upstream code copied) | `ios/faBolus/Data/Sources/LibreLinkUpSource.swift` | Independent Swift client of the unofficial LibreLinkUp REST API |
| ProfileIntents.swift | Apple official `EntityQuery` Developer-documentation sample | LicenseRef-Apple-Sample-Code (API pattern; independent Swift impl, no upstream code copied) | `ios/faBolus/Intents/ProfileIntents.swift` | AppEntity/EntityQuery pattern for the profile picker in the Activate Profile Shortcuts intent (Phase 6 / 06-02; refuse-when-headless, D-02) |
| GlucoseLiveActivity.swift | kylebshr/luka-ios (© 2024 Kyle Bashour) + LoopKit/Loop (© 2015 Nathan Racklyeft, © 2016 LoopKit Authors) | MIT | `ios/faBolusWidgets/GlucoseLiveActivity.swift` | Dynamic Island region split + optional-arrow pattern (luka-ios) and the iOS-18 CarPlay `.small` availability-branch pattern (Loop) rebound to faBolus's own `WidgetSnapshot` projection; content faBolus-original (see 05-REFERENCE-COMPARISON.md §2/§5) |
| GlucoseLiveActivityManager.swift | LoopKit/Loop (© 2015 Nathan Racklyeft, © 2016 LoopKit Authors) | MIT | `ios/faBolus/Data/GlucoseLiveActivityManager.swift` | App-driven `Activity.update`/re-arm structure only — NOT Loop's APNs push-token flow (faBolus never uses APNs, D-04); see 05-REFERENCE-COMPARISON.md §5 |
| SiteAtlas_Models.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Vendor/LoopPowerPack/SiteAtlas/SiteAtlas_Models.swift` | Vendored SiteAtlas data models (site-rotation tracking); pure Foundation/SwiftUI, adapted behind a faBolus adapter (drift-checked via `scripts/check-vendor-drift.sh`) |
| FoodFinder_OpenFoodFactsService.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Vendor/LoopPowerPack/FoodFinder/FoodFinder_OpenFoodFactsService.swift` | Vendored keyless OpenFoodFacts client (product search + barcode lookup); pure Foundation/os.log, corrected to production `world.openfoodfacts.org`/`api/v3` + faBolus User-Agent, strict decode + byte cap (drift-checked; OFF data itself is ODbL — see `THIRD_PARTY.md`/`NOTICE.md`) (09.18c-01, D-03) |
| FoodFinder_Models.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Vendor/LoopPowerPack/FoodFinder/FoodFinder_Models.swift` | Vendored OpenFoodFacts response/product models; pure Foundation, reduced to the carb-estimate fields with `carbohydrates` optional for strict decode (09.18c-01, D-03) |
| FoodFinder_ScannerService.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Vendor/LoopPowerPack/FoodFinder/FoodFinder_ScannerService.swift` | Vendored barcode-scanner service (AVFoundation capture + Vision `VNDetectBarcodesRequest`); produces only a barcode string, Loop `OSLog(category:)` → standard `OSLog(subsystem:category:)`, `BarcodeScanResult`/`BarcodeScanError` inlined (mirror `FoodFinder_InputResults` not vendored); no dose symbol (drift-checked, D-18.1) (09.18c-02, D-13) |
| FoodFinder_ScannerView.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Vendor/LoopPowerPack/FoodFinder/FoodFinder_ScannerView.swift` | Vendored barcode-scanner camera view (AVFoundation preview + reticle); camera-denied/no-device → `faBolusDesign.CameraPermissionFallbackView` (never a black view), dropped Loop `.supportedInterfaceOrientations` + "Loop" copy; hands a barcode string to the OFF lookup only (drift-checked, D-18.1) (09.18c-02, D-13) |
| FoodFinder_AIProviderConfig.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Vendor/LoopPowerPack/FoodFinder/FoodFinder_AIProviderConfig.swift` | Vendored BYO-key AI provider config, REDUCED to Anthropic/OpenAI/Google only (Spoonacular OUT, A7); pure Foundation/os.log, `apiKey` transient (loaded from `FoodFinderAIKeyStore`, never persisted), upstream UserDefaults ext + `AISettingsManager` dropped; no dose symbol (drift-checked, D-18.1) (09.18c-03, D-13) |
| FoodFinder_AIServiceAdapter.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Vendor/LoopPowerPack/FoodFinder/FoodFinder_AIServiceAdapter.swift` | Vendored AI carb-estimate adapter, REWRITTEN self-contained over an injectable `URLSession` (upstream `AIServiceManager`/`AIFoodAnalysisService`/Pre-Meal Advisor NOT vendored, D-13/D-14); Foundation/os.log only (image crosses as base64), rejected key → distinct `.keyRejected`, 2 MB byte cap; returns only raw text (parsed by `FoodFinderAICarbParse`), no dose symbol (drift-checked, D-18.1) (09.18c-03, D-13) |
| LoopInsights_EndoReportModels.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Vendor/LoopPowerPack/LoopInsights/LoopInsights_EndoReportModels.swift` | Vendored benign LoopInsights report DTO shapes ONLY — the analysis-period enum + reduced aggregated-stats struct (GlucoseStats/InsulinStats/CarbStats) cherry-picked from `LoopInsights_Models.swift`; AI/advisor/Phase5/biometric/`hourlyAverages`/LoopKit-typed fields stripped (D-04/D-14). Named to avoid the excluded `LoopInsights_Models.swift` basename; drift-checked via `scripts/check-vendor-drift.sh` (09.18d-01, D-15) |
| LoopInsights_CaffeineTracker.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Vendor/LoopPowerPack/LoopInsights/LoopInsights_CaffeineTracker.swift` | Vendored benign caffeine tracker — ONLY the log/remove/update/current-state APIs + entry field shape cherry-picked; `buildCaffeinePromptContext` (AI-feeding) + HealthKit sync OMITTED (D-14). Persistence re-pointed from UserDefaults to the faBolus SwiftData `GlucoseHistoryStore`; descriptive half-life readout only, no risk/directive; no dose symbol (drift-checked, D-14/D-17) (09.18d-02) |
| LoopInsights_AlcoholTracker.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Vendor/LoopPowerPack/LoopInsights/LoopInsights_AlcoholTracker.swift` | Vendored benign alcohol tracker — ONLY the log/remove/update/current-state APIs + entry field shape cherry-picked; `computeHypoRisk` (delayed-hypo MEDICAL INFERENCE) + `hypoRisk*` state fields + `buildAlcoholPromptContext` (AI-feeding) OMITTED (D-14). Persistence re-pointed from UserDefaults to the faBolus SwiftData `GlucoseHistoryStore`; descriptive linear-metabolism readout only, no risk/directive; no dose symbol (drift-checked, D-14/D-17) (09.18d-02) |
| LoopInsights_CaregiverDigestService.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Vendor/LoopPowerPack/LoopInsights/LoopInsights_CaregiverDigestService.swift` | Vendored benign caregiver-digest builder — ONLY the `metricRow` summary-assembly cherry-picked, re-expressed as plain text. Fed by the faBolus `FaBolusInsightsReport` (`FaBolusInsightsAggregator` over `GlucoseHistoryStore`) + `InsightsGlucoseUnitContext` in place of the LoopKit `DataAggregator`/`GlucoseUnitContext`. ALL LoopKit stores + `UserNotifications` reminder scheduling + recipient/delivery persistence + HTML email body + MessageUI + the status-sentiment prose OMITTED (D-14/D-15). Past-tense records summary only — no directive/prediction/dose suggestion; the `CaregiverDigestContentTests` §13 gate negative-greps this file (drift-checked, D-14/D-17) (09.18d-03, D-14/D-15/D-17) |
| SiteAtlasRootView.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Views/SiteAtlas/SiteAtlasRootView.swift` | Re-skinned SiteAtlas root (front/back body-map + history list) derived from the LoopPowerPack SiteAtlas layout; rebound to faBolusDesign/`AppTheme` + the `StoredSite` CRUD (09.18a-04, D-10/D-11) |
| SiteAtlasBodyMapView.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Views/SiteAtlas/SiteAtlasBodyMapView.swift` | Re-skinned SiteAtlas body-map + age-faded markers derived from the LoopPowerPack SiteAtlas layout; VECTOR/SF-Symbol body-outline fallback (mirror BodyMap PNGs NOT bundled pending owner license-verify of the LICENSE graphics exception) (09.18a-04, D-11) |
| SiteAtlasLogEntrySheet.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Views/SiteAtlas/SiteAtlasLogEntrySheet.swift` | Re-skinned SiteAtlas log-entry sheet derived from the LoopPowerPack SiteAtlas layout; rebound to faBolusDesign + `SiteAtlasStore` (advisory reuse-window note, non-blocking) (09.18a-04, D-10) |
| LoopInsights_CaffeineLogView.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Views/LoopInsights/LoopInsights_CaffeineLogView.swift` | Re-skinned caffeine tracker log list + "Log caffeine" entry sheet adapted from the LoopPowerPack CaffeineLogView layout; rebound to faBolusDesign + the benign `LoopInsights_CaffeineTracker` over `GlucoseHistoryStore`, with a glucose-context readout from `FaBolusInsightsAggregator`. Informational-only §13 copy, no risk/AI (09.18d-02, D-14/D-17) |
| LoopInsights_AlcoholLogView.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Views/LoopInsights/LoopInsights_AlcoholLogView.swift` | Re-skinned alcohol tracker log list + "Log a drink" entry sheet adapted from the LoopPowerPack AlcoholLogView layout; rebound to faBolusDesign + the benign `LoopInsights_AlcoholTracker` over `GlucoseHistoryStore`, with a glucose-context readout. The mirror's delayed-hypo RISK copy is NOT reproduced; informational-only §13 copy, no risk/AI (09.18d-02, D-14/D-17) |

## Optional / credential-gated (not committed, not in the open-source build)

| Component | Version | License (SPDX) | Notes |
|---|---|---|---|
| Garmin Connect IQ Mobile SDK | 1.8.0 | LicenseRef-Garmin-Proprietary | Binary xcframework; only when the Garmin companion is built |
| faBolusNudge | rev `c3d1e228` | MIT (code) | Advisory SDK; publishes its own **code** SBOM (`SBOM.md`+`check-sbom.sh`); model/dataset inventory tracked in the Nudge session. Pinned pre-eating-detection. |

## Trademarks

"faBolus" is a trademark of Tia Geri (code is MIT; the name is not licensed). Tandem, t:slim X2, Mobi,
Dexcom, Garmin are trademarks of their respective owners; faBolus is independent and unaffiliated. See
`NOTICE.md` for the full attribution prose.
