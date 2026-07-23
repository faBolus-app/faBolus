# Software Bill of Materials (faBolus, non-Nudge)

Machine-checkable provenance for every third-party / vendored component the faBolus Apple app ships or
builds against (audit L-01). `scripts/check-sbom.sh` fails CI if a local/vendored package is missing a
`LICENSE` file or a row here. The **faBolusNudge** advisory SDK maintains its own SBOM (model weights +
datasets); it is referenced here as an external pinned dependency only.

Format per row: component · version/revision · SPDX license · source · how faBolus uses it.

## Local packages (in this repo)

| Component | Version | License (SPDX) | Source | Usage |
|---|---|---|---|---|
| faBolusCore | in-repo | MIT | `Packages/faBolusCore` | Pump/host-agnostic contracts, models, BolusMath, transports |
| HistoryStore | in-repo | MIT | `Packages/HistoryStore` | SwiftData glucose/insulin/carb history |

## Vendored source (copied in, LoopKit lineage — all MIT)

| Component | Upstream | License (SPDX) | Source | Usage |
|---|---|---|---|---|
| G7SensorKit | LoopKit/G7SensorKit | MIT | `Packages/G7SensorKit` (LICENSE incl.) | Dexcom G7/ONE+ BLE decoders (passive) |
| DexcomG6Kit | LoopKit/CGMBLEKit | MIT | `Packages/DexcomG6Kit` | Dexcom G5/G6/ONE passive decoders |
| ShareClient | LoopKit/dexcom-share-client-swift | MIT | `Packages/ShareClient` (LICENSE incl.) | Dexcom Share follower core |

## Local path dependency (separate repo)

| Component | Version | License (SPDX) | Source | Usage |
|---|---|---|---|---|
| PumpX2Kit | `../PumpX2Kit` | MIT | github.com/faBolus-app/PumpX2Kit | Tandem BLE protocol / auth / messages |

PumpX2Kit in turn vendors (see its own `NOTICE`):

| Component | Upstream | License (SPDX) | Usage |
|---|---|---|---|
| pumpx2-oracle | jwoglom/pumpx2 (© James Woglom) | MIT | Reverse-engineered protocol reference + parity fixtures |
| Mbed TLS | Mbed-TLS/mbedtls | `Apache-2.0 OR GPL-2.0` | EC-JPAKE pairing |

## Optional / credential-gated (not committed, not in the open-source build)

| Component | Version | License (SPDX) | Notes |
|---|---|---|---|
| Garmin Connect IQ Mobile SDK | 1.8.0 | LicenseRef-Garmin-Proprietary | Binary xcframework; only when the Garmin companion is built |
| faBolusNudge | rev `c3d1e228` | MIT (code) | Advisory SDK; **owns its own SBOM** (model weights/datasets). Pinned pre-eating-detection. |

## Trademarks

"faBolus" is a trademark of Tia Geri (code is MIT; the name is not licensed). Tandem, t:slim X2, Mobi,
Dexcom, Garmin are trademarks of their respective owners; faBolus is independent and unaffiliated. See
`NOTICE.md` for the full attribution prose.
