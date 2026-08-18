# Attributions

faBolus is an independent, open-source project, licensed under the MIT License (see `LICENSE`).

## The faBolus™ name

**faBolus™** is a trademark of Tia Geri. The MIT License covers this project's **source code**; it
does not grant any right to use the "faBolus" name, logo, or branding. You are free to fork and
reuse the code under the MIT terms, but please do not use the faBolus name in a way that suggests
your fork is the official project or is endorsed by it.

It is built on the Tandem pump Bluetooth protocol as reverse-engineered by the
**[pumpX2](https://github.com/jwoglom/pumpx2)** project (© James Woglom, MIT License). faBolus is an
independent reimplementation for iPhone / Apple Watch / Garmin; it is **not** a fork of, affiliated
with, or endorsed by pumpX2/controlX2.

The protocol/auth/Bluetooth core lives in the separate **TandemKit** package, which vendors
**Mbed TLS** (Apache-2.0 OR GPL-2.0) for its EC-JPAKE implementation — see TandemKit's own `NOTICE`
for that attribution.

## G7SensorKit (Dexcom G7 / ONE+ decoding)

The Dexcom G7 / ONE+ BLE message decoders in `Packages/G7SensorKit` are vendored from
**[LoopKit/G7SensorKit](https://github.com/LoopKit/G7SensorKit)** (© 2022 LoopKit Authors; several
files originate in xDripG5 / CGMBLEKit, © 2015–2016 Nathan Racklyeft), used under the MIT License.
LoopKit-specific coupling has been removed and the decoders are passive/read-only. The reproduced
license and copyright are in `Packages/G7SensorKit/LICENSE`. The independent CGM seam that consumes
them is modeled on LoopKit's `CGMManager` design.

## DexcomG6Kit (Dexcom G5 / G6 / ONE decoding)

The Dexcom G5 / G6 / ONE passive BLE message decoders in `Packages/DexcomG6Kit` are vendored from
**[LoopKit/CGMBLEKit](https://github.com/LoopKit/CGMBLEKit)** (© 2017 LoopKit Authors; portions
© 2015–2016 Nathan Racklyeft), used under the MIT License. LoopKit-specific coupling has been removed
and the decoders are passive/read-only. The reproduced license is in `Packages/DexcomG6Kit/LICENSE`.

## ShareClient (Dexcom Share follower)

The Dexcom Share follower core in `Packages/ShareClient` is vendored from
**[LoopKit/dexcom-share-client-swift](https://github.com/LoopKit/dexcom-share-client-swift)** (MIT).
The reproduced license is in `Packages/ShareClient/LICENSE`.

## XDripAppGroupSource (xDrip4iOS "Share to Loop" App-Group reader)

The xDrip App-Group glucose reader in `ios/faBolus/Data/Sources/XDripAppGroupSource.swift` is ported
from **[JohanDegraeve/xdrip-client-swift](https://github.com/JohanDegraeve/xdrip-client-swift)**, used
under the MIT License. That project descends from the xDripG5 / CGMBLEKit lineage; its license's
original copyright is **© 2016 Mark Wilson**. faBolus's reader is passive and read-only, consuming
xDrip's documented "Share to Loop" App-Group JSON contract.

## LibreLinkUpSource (unofficial LibreLinkUp follower)

The LibreLinkUp follower in `ios/faBolus/Data/Sources/LibreLinkUpSource.swift` is an **independent
Swift implementation** of the unofficial LibreLinkUp REST API. The endpoint/header behaviour was
documented by the community projects
**[nightscout-librelink-up](https://github.com/timoschlueter/nightscout-librelink-up)** (MIT) and
**libre-link-unofficial-api**; faBolus credits them for that API knowledge but copies no upstream
source (a clean reimplementation, so no upstream code license attaches).

See `docs/SBOM.md` for the full machine-checked component inventory (audit L-01).

## LoopPowerPack (SiteAtlas + FoodFinder + LoopInsights feature source)

The benign LoopInsights report DTO shapes in
`ios/faBolus/Vendor/LoopPowerPack/LoopInsights/LoopInsights_EndoReportModels.swift` (the endo-report
analysis-period enum + a reduced aggregated-stats struct) are vendored from the same LoopPowerPack fork
under the MIT License, with the AI/advisor/Phase5/biometric/LoopKit-typed fields stripped — LoopInsights
is never vendored as a whole dir (D-04/D-14). The endo-report aggregator, the SwiftUI `ImageRenderer` PDF
page, and the report view are independent faBolus rewrites over `GlucoseHistoryStore` (not ports of
LoopKit's `DataAggregator` or Loop's HTML→PDF generator, D-15); the report is a records summary only and
never advice or a dose.

The SiteAtlas data models in `ios/faBolus/Vendor/LoopPowerPack/SiteAtlas/` and the FoodFinder
OpenFoodFacts client + models in `ios/faBolus/Vendor/LoopPowerPack/FoodFinder/` are vendored from the
**LoopPowerPack** fork of Loop (`LoopPowerPack/Loop`, pinned at commit
`ad4c4d498f936a25e22dd3a8dc93354138458509`), used under the MIT License. The SiteAtlas and FoodFinder
features are **© 2026 LoopKit Authors and Taylor Patterson** (idea by Taylor Patterson); the surrounding
Loop code is © 2015 Nathan Racklyeft and © 2016 LoopKit Authors. faBolus adapts this source behind thin
adapters and does not auto-merge upstream changes — see `ios/faBolus/Vendor/LoopPowerPack/UPSTREAM.md`
and the `scripts/check-vendor-drift.sh` integrity check. The FoodFinder client is corrected to the
production OpenFoodFacts host + `api/v3` endpoint with a faBolus-identifying User-Agent. The BodyMap PNG
graphics are not vendored here.

## OpenFoodFacts (food product data)

FoodFinder's keyless carb-estimate path reads food-product data from the
**[Open Food Facts](https://world.openfoodfacts.org)** database over its public REST API. Open Food Facts
product data is made available under the **Open Database License (ODbL) v1.0**; individual product
contents are © the Open Food Facts contributors. No Open Food Facts code is vendored — faBolus is an
independent client and is not affiliated with or endorsed by Open Food Facts. Carb estimates derived from
this data are advisory only; the user reviews and confirms every number before it can influence a dose.

## Loop / LoopDocs (design + documentation)

faBolus's visual design draws inspiration from the **[Loop](https://github.com/LoopKit/Loop)** app,
and portions of this project's documentation are adapted from
**[LoopDocs](https://loopkit.github.io/loopdocs/)**. faBolus is an independent project and is not
affiliated with, or endorsed by, the Loop / LoopKit projects.

Not affiliated with, endorsed by, or a product of **Tandem Diabetes Care** or **Dexcom**. Tandem,
t:slim X2, Mobi, and Dexcom are trademarks of their respective owners.
