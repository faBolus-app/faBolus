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
| GlucoseSources | in-repo | MIT | `Packages/GlucoseSources` | The backup CGM sources (Dexcom Share, direct-Bluetooth G6 and G7), their settings and credentials, and the CGM test |

## Vendored source (copied in, LoopKit lineage — all MIT)

| Component | Upstream | License (SPDX) | Source | Usage |
|---|---|---|---|---|
| ShareClient | LoopKit/dexcom-share-client-swift | MIT | `Packages/ShareClient` (LICENSE incl.) | Dexcom Share follower core. Deliberate de-port: `LocalizedString.swift`/`OSLog.swift`/`TimeInterval.swift` (zero `public` declarations, unreachable by construction) were dropped from the vendored set — the remaining source, its package linkage, and its `DexcomShareSource` consumer are unchanged. Modified for Swift 6: the callbacks are `@Sendable` and the session token sits behind a lock (`ShareClient` is `final` and `@unchecked Sendable`). |
| DexcomBLE (G6) | LoopKit/CGMBLEKit @ `c9e6c84` | MIT | `Packages/DexcomBLE/G6` (LICENSE incl.); the shared `Data.swift`, `BluetoothServices.swift` and `AuthChallengeRxMessage.swift` in `Packages/DexcomBLE/Sources/DexcomBLE` (CGMBLEKit's LICENSE at the package root) | Passive-mode G5/G6/ONE decoding. Copied with their headers: `Opcode`, `CalibrationState`, `TransmitterStatus`, `NSData+CRC`, `TransmitterMessage`, `TransmitterTimeRxMessage`, `GlucoseRxMessage`, `GlucoseBackfillMessage`, `Common/Data`, `BluetoothServices`, `AuthChallengeRxMessage`. Edits: the Tx side and LoopKit/HealthKit-only members removed (`TransmitterTxMessage`, `RespondableMessage`, `GlucoseBackfillTxMessage`, `Data.init(for:)`, `TransmitterStatus.localizedDescription`, unused byte helpers and UUID enums, `PeripheralManager.Configuration`); `Sendable` and `package` access added; `Data.to(_:)` assembles bytes instead of loading through a rebound pointer; one `AuthChallengeRxMessage` shared by G6 and G7. `G6Observer` and `DexcomCentral` are new code following `Transmitter`'s passive mode and `BluetoothManager`'s connect rules. |
| DexcomBLE (G7) | LoopKit/G7SensorKit @ `aeaec95` | MIT | `Packages/DexcomBLE/G7` (LICENSE incl.) | G7/ONE+ decoding. Copied with their headers: `G7Opcode`, `G7GlucoseMessage`, `G7BackfillMessage`, `AlgorithmState`, `SensorMessage`. Edits: LoopKit `trendType` and `condition` removed; `Sendable` added; `glucoseTimestamp` is optional, `nil` where upstream's `UInt32` subtraction would trap. `G7Observer` is new code following `G7Sensor` and `G7BluetoothManager`. |

**LoopPowerPack (SiteAtlas / LoopInsights / FoodFinder) — removed from `main`.** The vendored source
files under the `ios/faBolus/Vendor/` LoopPowerPack tree's `{SiteAtlas,LoopInsights,FoodFinder}` subdirs that this table used
to list have been scope-narrowed off `main` along with the features that consumed them ("Backup/restore
incl. iCloud + SiteAtlas" → `dev/backup`; "Retrospective insights" → `dev/retrospective`; "FoodFinder /
food-scanner" → `dev/food-finder`; `BRANCHES.md` §1.2c). Only `UPSTREAM.md` remains as vendored-tree
source on `main`.

## Local path dependency (separate repo)

| Component | Version | License (SPDX) | Source | Usage |
|---|---|---|---|---|
| TandemKit | `../TandemKit` | MIT | github.com/faBolus-app/TandemKit | Tandem BLE protocol / auth / messages |

TandemKit in turn vendors (see its own `NOTICE`):

| Component | Upstream | License (SPDX) | Usage |
|---|---|---|---|
| pumpx2-oracle | jwoglom/pumpx2 (© James Woglom) | MIT | Reverse-engineered protocol reference + parity fixtures |
| Mbed TLS | Mbed-TLS/mbedtls | `Apache-2.0 OR GPL-2.0` | EC-JPAKE pairing |

## Adapted source inside the local packages

Files in `Packages/` that carry an `Adapted from` attribution, checked by the same `check-sbom.sh` scan.

| File | Upstream | License (SPDX) | What was taken |
|---|---|---|---|
| `Packages/faBolusCore/Sources/faBolusCore/DoseEntry.swift` | LoopKit/LoopKit `a5beee96`, `InsulinKit/DoseEntry.swift` (© 2016 Nathan Racklyeft) | MIT | Field names and the programmed-versus-delivered split; rewritten without HealthKit |
| `Packages/faBolusCore/Sources/faBolusCore/PumpState.swift` | LoopKit/LoopKit `a5beee96`, `DeviceManager/PumpManagerStatus.swift` (© 2018 LoopKit Authors) | MIT | The `basalDeliveryState` / `bolusState` names and their cases |
| `Packages/faBolusCore/Sources/faBolusCore/BolusVolume.swift` | LoopKit/LoopKit `a5beee96`, `DeviceManager/PumpManager.swift` (© 2018 LoopKit Authors) and `Extensions/FloatingPoint.swift` (© 2020 LoopKit Authors) | MIT | The round-down rule of `roundToSupportedBolusVolume` and the decimal tolerance of `matchingOrTruncatedValue`, rewritten for a fixed step |

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

"faBolus" is a trademark of Zev Granowitz (code is MIT; the name is not licensed). Tandem, t:slim X2, Mobi,
Dexcom, Garmin are trademarks of their respective owners; faBolus is independent and unaffiliated. See
`NOTICE.md` for the full attribution prose.
