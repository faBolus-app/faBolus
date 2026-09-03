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
| faBolusDesign | in-repo | MIT | `Packages/faBolusDesign` | Shared §13 band-color tokens (depends on faBolusCore) |
| HistoryStore | in-repo | MIT | `Packages/HistoryStore` | SwiftData glucose/insulin/carb history |

## Vendored source (copied in, LoopKit lineage — all MIT)

| Component | Upstream | License (SPDX) | Source | Usage |
|---|---|---|---|---|
| ShareClient | LoopKit/dexcom-share-client-swift | MIT | `Packages/ShareClient` (LICENSE incl.) | Dexcom Share follower core |

**LoopPowerPack (SiteAtlas / LoopInsights / FoodFinder) — removed from `main`.** The vendored source
files under `ios/faBolus/Vendor/LoopPowerPack/{SiteAtlas,LoopInsights,FoodFinder}` that this table used
to list have been scope-narrowed off `main` along with the features that consumed them ("Backup/restore
incl. iCloud + SiteAtlas" → `dev/backup`; "Retrospective insights" → `dev/retrospective`; "FoodFinder /
food-scanner" → `dev/food-finder`; `BRANCHES.md` §1.2c). Only `UPSTREAM.md` remains as vendored-tree
source on `main`. **Known issue (out of this docs-only plan's scope, logged in
`.planning/WINDOWS.md`):** `.vendor-manifest.sha256` was not regenerated when those files were deleted,
so `scripts/check-vendor-drift.sh` currently fails against the stale manifest.

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

**Currently none on `main`.** Every file this table used to list — `ProfileIntents.swift` (Shortcuts
intent), `GlucoseLiveActivity.swift`/`GlucoseLiveActivityManager.swift` (Live Activity), the vendored
SiteAtlas/FoodFinder/LoopInsights source, and the re-skinned SiteAtlas/LoopInsights views — has been
scope-narrowed off `main` onto its respective `dev/<surface>` branch (Live Activity → `dev/live-activity`;
Siri/Shortcuts → `dev/siri-shortcuts`; backup/SiteAtlas → `dev/backup`; retrospective/LoopInsights →
`dev/retrospective`; FoodFinder → `dev/food-finder`; see `BRANCHES.md` §1.2c). A repo-wide scan for the
`Ported from`/`Adapted from` markers on `main` (`grep -rlE '(^|[^[:alnum:]])[Pp]orted from|...' ios Shared`)
returns nothing. `check-sbom.sh` still runs this scan on every CI run and will re-populate this table if
a future port lands on `main`.

## Optional / credential-gated (not committed, not in the open-source build)

| Component | Version | License (SPDX) | Notes |
|---|---|---|---|
| Garmin Connect IQ Mobile SDK | 1.8.0 | LicenseRef-Garmin-Proprietary | Binary xcframework; only when the Garmin companion is built |
| faBolusNudge | rev `c3d1e228` | MIT (code) | Advisory SDK; publishes its own **code** SBOM (`SBOM.md`+`check-sbom.sh`); model/dataset inventory tracked in the Nudge session. Pinned pre-eating-detection. |

## Trademarks

"faBolus" is a trademark of Tia Geri (code is MIT; the name is not licensed). Tandem, t:slim X2, Mobi,
Dexcom, Garmin are trademarks of their respective owners; faBolus is independent and unaffiliated. See
`NOTICE.md` for the full attribution prose.
