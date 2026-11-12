# Software Bill of Materials (faBolus)

Machine-checkable provenance for every third-party / vendored component the faBolus Apple app ships or
builds against. `scripts/check-sbom.sh` fails CI if a local/vendored package is missing a `LICENSE` file
or a row here.

Format per row: component · version/revision · SPDX license · source · how faBolus uses it.

## Local packages (in this repo)

| Component | Version | License (SPDX) | Source | Usage |
|---|---|---|---|---|
| faBolusCore | in-repo | MIT | `Packages/faBolusCore` | Pump- and host-agnostic models, the bolus calculator, the dose composer and the remote-bolus ledger |
| faBolusDesign | in-repo | MIT | `Packages/faBolusDesign` | Shared glucose band colours (depends on faBolusCore) |
| HistoryStore | in-repo | MIT | `Packages/HistoryStore` | SwiftData glucose/insulin/carb history |
| GlucoseSources | in-repo | MIT | `Packages/GlucoseSources` | The backup CGM sources (Dexcom Share, direct-Bluetooth G6 and G7), their settings and credentials, and the CGM test |
| PumpSession | in-repo | MIT | `Packages/PumpSession` | The pump session (link, reads, delivery, history, alerts) and `PumpScript`, the scripted pump the tests and the debug mock run on. Its test fixtures (`Tests/PumpSessionTests/Support/Captures.swift`) are message bytes from jwoglom/pumpx2 @ `456018a5` (MIT, © 2022 James Woglom): its tests' captures of Tandem's app and its `scripts/discord-switchkill/2023/btsnoop_hci.csv` capture. |
| Alerts | in-repo | MIT | `Packages/Alerts` | The phone's alert pipeline: the alert engine, the coordinator that posts and withdraws notifications, the in-app banners and the alerts the watch mirrors |
| RemoteProtocol | in-repo | MIT | `Packages/RemoteProtocol` | The phone↔remote protocol, version 2: the typed messages, their wire form, and the contract files a remote vendors (field reference, schema, golden fixtures, the bolus calculator fixtures) |
| PhoneApp | in-repo | MIT | `Packages/PhoneApp` | The phone app's state and wiring (launch order, settings, the first-launch wipe, the bolus screen's flow, diagnostics, the debug-only scripted pump) and `WidgetContent`, what the app publishes for its widgets and Live Activity |
| WatchLink | in-repo | MIT | `Packages/WatchLink` | The phone's link to a remote as a state machine, the host that answers the remote from the pump session, the ledger and the alerts, and the Connect IQ adapter (built only where Garmin's companion SDK is present; the SDK itself isn't in the repository) |

## Vendored source (copied in, LoopKit lineage)

| Component | Upstream | License (SPDX) | Source | Usage |
|---|---|---|---|---|
| ShareClient | LoopKit/dexcom-share-client-swift @ `21d8657` | MIT | `Packages/ShareClient` (LICENSE incl.) | Dexcom Share follower core. Deliberate de-port: `LocalizedString.swift`/`OSLog.swift`/`TimeInterval.swift` (zero `public` declarations, unreachable by construction) were dropped from the vendored set — the remaining source, its package linkage, and its `DexcomShareSource` consumer are unchanged. Modified for Swift 6: the callbacks are `@Sendable` and the session token sits behind a lock (`ShareClient` is `final` and `@unchecked Sendable`). |
| DexcomBLE (G6) | LoopKit/CGMBLEKit @ `c9e6c84` | MIT | `Packages/DexcomBLE/G6` (LICENSE incl.); the shared `Data.swift`, `BluetoothServices.swift` and `AuthChallengeRxMessage.swift` in `Packages/DexcomBLE/Sources/DexcomBLE` (CGMBLEKit's LICENSE at the package root) | Passive-mode G5/G6/ONE decoding. Copied with their headers: `Opcode`, `CalibrationState`, `TransmitterStatus`, `NSData+CRC`, `TransmitterMessage`, `TransmitterTimeRxMessage`, `GlucoseRxMessage`, `GlucoseBackfillMessage`, `Common/Data`, `BluetoothServices`, `AuthChallengeRxMessage`. Edits: the Tx side and LoopKit/HealthKit-only members removed (`TransmitterTxMessage`, `RespondableMessage`, `GlucoseBackfillTxMessage`, `Data.init(for:)`, `TransmitterStatus.localizedDescription`, unused byte helpers and UUID enums, `PeripheralManager.Configuration`); `Sendable` and `package` access added; `Data.to(_:)` assembles bytes instead of loading through a rebound pointer; one `AuthChallengeRxMessage` shared by G6 and G7. `G6Observer` and `DexcomCentral` are new code following `Transmitter`'s passive mode and `BluetoothManager`'s connect rules. `Data(hexadecimalString:)` in `Data.swift` is adapted from Stack Overflow answer 40278391 by Martin R (CC-BY-SA-3.0), as CGMBLEKit carries it. Tests: `G6/Tests/G6MessageTests.swift` ports CGMBLEKit's `GlucoseRxMessageTests`, `TransmitterTimeRxMessageTests` and `GlucoseBackfillMessageTests` with their fixtures, and `G6/Tests/Fixtures/*.log` replay those recorded messages. |
| DexcomBLE (G7) | LoopKit/G7SensorKit @ `aeaec95` | MIT | `Packages/DexcomBLE/G7` (LICENSE incl.) | G7/ONE+ decoding. Copied with their headers: `G7Opcode`, `G7GlucoseMessage`, `G7BackfillMessage`, `AlgorithmState`, `SensorMessage`. Edits: LoopKit `trendType` and `condition` removed; `Sendable` added; `glucoseTimestamp` is optional, `nil` where upstream's `UInt32` subtraction would trap. `G7Observer` is new code following `G7Sensor` and `G7BluetoothManager`. Tests: `G7/Tests/G7Tests.swift` ports G7SensorKit's `G7GlucoseMessageTests` with their fixtures, and `G7/Tests/Fixtures/g7-session.log` replays G7SensorKit's recorded G7 log. |

## Test-only dependencies (never linked into the app or the widgets)

| Component | Version | License (SPDX) | Source | Usage |
|---|---|---|---|---|
| swift-snapshot-testing | 1.19.4 | MIT | github.com/pointfreeco/swift-snapshot-testing | The app's light and dark snapshot tests (`ios/faBolusAppTests`) |
| swift-custom-dump | as resolved (1.x) | MIT | github.com/pointfreeco/swift-custom-dump | Dependency of swift-snapshot-testing |
| xctest-dynamic-overlay | as resolved (1.x) | MIT | github.com/pointfreeco/xctest-dynamic-overlay | Dependency of swift-snapshot-testing |
| swift-syntax | as resolved | Apache-2.0 | github.com/swiftlang/swift-syntax | Dependency of swift-snapshot-testing (its inline-snapshot macros) |

## Package dependency (separate repo)

| Component | Version | License (SPDX) | Source | Usage |
|---|---|---|---|---|
| TandemKit | 0.7.0, `exact:` (`Packages/PumpSession` and `Packages/PhoneApp` `Package.swift`) | MIT | github.com/faBolus-app/TandemKit | Tandem BLE protocol / auth / messages |

TandemKit in turn vendors (see its own `NOTICE`):

| Component | Upstream | License (SPDX) | Usage |
|---|---|---|---|
| pumpx2-oracle | jwoglom/pumpx2 (© James Woglom) | MIT | Reverse-engineered protocol reference + parity fixtures (tests only) |
| Mbed TLS | Mbed-TLS/mbedtls | `Apache-2.0 OR GPL-2.0-or-later` | EC-JPAKE pairing |

## Adapted source inside the local packages

Files in `Packages/` that carry an `Adapted from` attribution, checked by the same `check-sbom.sh` scan.

| File | Upstream | License (SPDX) | What was taken |
|---|---|---|---|
| `Packages/faBolusCore/Sources/faBolusCore/DoseEntry.swift` | LoopKit/LoopKit `a5beee96`, `InsulinKit/DoseEntry.swift` (© 2016 Nathan Racklyeft) | MIT | Field names and the programmed-versus-delivered split; rewritten without HealthKit |
| `Packages/faBolusCore/Sources/faBolusCore/PumpState.swift` | LoopKit/LoopKit `a5beee96`, `DeviceManager/PumpManagerStatus.swift` (© 2018 LoopKit Authors) | MIT | The `basalDeliveryState` / `bolusState` names and their cases |
| `Packages/faBolusCore/Sources/faBolusCore/BolusMath.swift` | jwoglom/pumpx2 `456018a5` (as vendored in TandemKit), `calculator/BolusCalculator.java` (© 2022 James Woglom) | MIT | A port of `BolusCalculator.parse()`'s food, correction and IOB path. The rows it's tested against, `bolus_oracle_fixtures.jsonl` (faBolusCore's test fixtures and the contract copy in `Packages/RemoteProtocol/contract`), are that Java calculator's outputs |
| `Packages/faBolusCore/Sources/faBolusCore/BolusVolume.swift` | LoopKit/LoopKit `a5beee96`, `DeviceManager/PumpManager.swift` (© 2018 LoopKit Authors) and `Extensions/FloatingPoint.swift` (© 2020 LoopKit Authors) | MIT | The round-down rule of `roundToSupportedBolusVolume` and the decimal tolerance of `matchingOrTruncatedValue`, rewritten for a fixed step |
| `Packages/faBolusCore/Sources/faBolusCore/NotificationBroker.swift` | LoopKit/LoopKit `a5beee96`, `Alert.swift` (© 2020 LoopKit Authors) | MIT | `AlertInterruptionLevel`: the alert model carrying iOS's interruption levels (`Alert.InterruptionLevel`), with the passive level added |
| `Packages/Alerts/Sources/Alerts/NotificationScheduling.swift` | LoopKit/Loop `5465bcd`, `Managers/Alerts/UserNotificationAlertScheduler.swift` (© 2020 LoopKit Authors) | MIT | The narrow notification-center protocol for tests, the request built from an alert (content at its interruption level, a time-interval trigger only for a delay), and withdrawal of pending and delivered together |

## Ported / API-derived app-tree source (not a Package — lives in the app target)

Files in the app target (`ios/`) that carry a `Ported from` / `Adapted from` attribution. `check-sbom.sh`
scans the tree for those markers and fails CI if such a file is not listed here with a license token.

None at present.

## Optional / credential-gated (not committed, not in the open-source build)

| Component | Version | License (SPDX) | Notes |
|---|---|---|---|
| Garmin Connect IQ Mobile SDK | 1.8.0 | LicenseRef-Garmin-Proprietary | Binary xcframework; only when the Garmin companion is built |

## Documentation site (fabolus.org, not part of the app)

| Component | Version | License (SPDX) | Source | Usage |
|---|---|---|---|---|
| Material for MkDocs `partials/header.html` | mkdocs-material 9.7.7 | MIT | `overrides/partials/header.html` | Copied unchanged except for one line that includes the safety banner (`overrides/partials/safety-banner.html`) as the sticky header's first child |

## Trademarks

"faBolus" is a trademark of Zev Granowitz (code is MIT; the name is not licensed). Tandem, t:slim X2, Mobi,
Dexcom, Garmin are trademarks of their respective owners; faBolus is independent and unaffiliated. See
`NOTICE.md` for the full attribution prose.
