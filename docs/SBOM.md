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
| SiteAtlasRootView.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Views/SiteAtlas/SiteAtlasRootView.swift` | Re-skinned SiteAtlas root (front/back body-map + history list) derived from the LoopPowerPack SiteAtlas layout; rebound to faBolusDesign/`AppTheme` + the `StoredSite` CRUD (09.18a-04, D-10/D-11) |
| SiteAtlasBodyMapView.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Views/SiteAtlas/SiteAtlasBodyMapView.swift` | Re-skinned SiteAtlas body-map + age-faded markers derived from the LoopPowerPack SiteAtlas layout; VECTOR/SF-Symbol body-outline fallback (mirror BodyMap PNGs NOT bundled pending owner license-verify of the LICENSE graphics exception) (09.18a-04, D-11) |
| SiteAtlasLogEntrySheet.swift | LoopPowerPack/Loop @ ad4c4d4 (© 2026 LoopKit Authors and Taylor Patterson) | MIT | `ios/faBolus/Views/SiteAtlas/SiteAtlasLogEntrySheet.swift` | Re-skinned SiteAtlas log-entry sheet derived from the LoopPowerPack SiteAtlas layout; rebound to faBolusDesign + `SiteAtlasStore` (advisory reuse-window note, non-blocking) (09.18a-04, D-10) |

## Optional / credential-gated (not committed, not in the open-source build)

| Component | Version | License (SPDX) | Notes |
|---|---|---|---|
| Garmin Connect IQ Mobile SDK | 1.8.0 | LicenseRef-Garmin-Proprietary | Binary xcframework; only when the Garmin companion is built |
| faBolusNudge | rev `c3d1e228` | MIT (code) | Advisory SDK; publishes its own **code** SBOM (`SBOM.md`+`check-sbom.sh`); model/dataset inventory tracked in the Nudge session. Pinned pre-eating-detection. |

## Trademarks

"faBolus" is a trademark of Tia Geri (code is MIT; the name is not licensed). Tandem, t:slim X2, Mobi,
Dexcom, Garmin are trademarks of their respective owners; faBolus is independent and unaffiliated. See
`NOTICE.md` for the full attribution prose.
