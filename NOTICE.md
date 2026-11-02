# Attributions

faBolus is an independent, open-source project, licensed under the MIT License (see `LICENSE`).

## The faBolus™ name

**faBolus™** is a trademark of Zev Granowitz. The MIT License covers this project's **source code**; it
does not grant any right to use the "faBolus" name, logo, or branding. You are free to fork and
reuse the code under the MIT terms, but please do not use the faBolus name in a way that suggests
your fork is the official project or is endorsed by it.

## pumpX2

faBolus is built on the Tandem pump Bluetooth protocol as reverse-engineered by the
**[pumpX2](https://github.com/jwoglom/pumpx2)** project (© James Woglom, MIT License). faBolus is an
independent reimplementation for iPhone and Garmin; it is **not** a fork of, affiliated with, or endorsed
by pumpX2 or controlX2. Captured pumpX2 message bytes are copied as test fixtures in
`Packages/PumpSession/Tests/PumpSessionTests/Support/Captures.swift`, and the bolus calculator in
`Packages/faBolusCore/Sources/faBolusCore/BolusMath.swift` is a port of pumpX2's `BolusCalculator`, tested
against rows that calculator computed.

The protocol, pairing and Bluetooth core lives in the separate **TandemKit** package, which vendors
**Mbed TLS** (Apache-2.0 OR GPL-2.0-or-later) for its EC-JPAKE implementation; see TandemKit's own `NOTICE.md` for
that attribution.

## ShareClient (Dexcom Share follower)

The Dexcom Share follower core in `Packages/ShareClient` is vendored from
**[LoopKit/dexcom-share-client-swift](https://github.com/LoopKit/dexcom-share-client-swift)** `21d8657` (MIT,
© 2016 Mark Wilson). The license is reproduced in `Packages/ShareClient/LICENSE`.

## Dexcom Bluetooth readers

The direct Dexcom readers in `Packages/DexcomBLE` are copied from LoopKit's MIT code, each folder keeping
its upstream license:

- `G6/` and the shared files in `Sources/DexcomBLE`: **[CGMBLEKit](https://github.com/LoopKit/CGMBLEKit)**
  passive mode (© 2015 Nathan Racklyeft);
- `G7/`: **[G7SensorKit](https://github.com/LoopKit/G7SensorKit)** (© 2022 LoopKit Authors).

Their message tests are ported with the upstream fixtures. `Data(hexadecimalString:)` in
`Sources/DexcomBLE/Data.swift` is adapted from a
[Stack Overflow answer](https://stackoverflow.com/a/40278391) by Martin R (CC BY-SA 3.0), as CGMBLEKit carries it.

## LoopKit and Loop, adapted

These files in faBolus adapt names, shapes or rules from **[LoopKit](https://github.com/LoopKit/LoopKit)**
and **[Loop](https://github.com/LoopKit/Loop)** (MIT), rewritten without HealthKit:

- `Packages/faBolusCore`: `DoseEntry.swift` (`DoseEntry`, © 2016 Nathan Racklyeft), `PumpState.swift`
  (`PumpManagerStatus`, © 2018 LoopKit Authors), `BolusVolume.swift` (the bolus-volume rounding, © 2018
  and © 2020 LoopKit Authors) and `NotificationBroker.swift` (the alert interruption level, © 2020 LoopKit
  Authors);
- `Packages/Alerts`: `NotificationScheduling.swift` (Loop's `UserNotificationAlertScheduler`, © 2020
  LoopKit Authors).

## Garmin Connect IQ Mobile SDK

The phone app's Garmin support links Garmin's Connect IQ Mobile SDK for iOS, which is licensed by Garmin
and isn't in this repository. A self-builder downloads it and accepts Garmin's license.

## Loop / LoopDocs (design + documentation)

faBolus's visual design draws inspiration from the **[Loop](https://github.com/LoopKit/Loop)** app,
and portions of this project's documentation are adapted from
**[LoopDocs](https://loopkit.github.io/loopdocs/)**. faBolus is an independent project and is not
affiliated with, or endorsed by, the Loop / LoopKit projects.

## License texts

The license notices that go with the code ported or adapted from these projects are in `LICENSES/`:
`pumpx2.txt` (pumpX2), `LoopKit.txt` (LoopKit) and `Loop.txt` (Loop). CGMBLEKit's, G7SensorKit's and
ShareClient's are the `LICENSE` files in their package folders.

See `docs/SBOM.md` for the full component inventory, checked by `scripts/check-sbom.sh`.

Not affiliated with, endorsed by, or a product of **Tandem Diabetes Care** or **Dexcom**. Tandem,
t:slim X2, Mobi, and Dexcom are trademarks of their respective owners.
