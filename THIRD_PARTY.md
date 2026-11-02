# Third-party components (faBolus)

By-name index of every third-party / vendored / ported component the faBolus Apple app ships or builds
against. This is a human summary; the **machine-checked** source of truth is [`docs/SBOM.md`](docs/SBOM.md)
(enforced by `scripts/check-sbom.sh`), and the attribution prose is in [`NOTICE.md`](NOTICE.md). faBolus
itself is MIT (see `LICENSE`).

| Component | License | Kind | Where |
|---|---|---|---|
| faBolusCore, faBolusDesign, HistoryStore, GlucoseSources, PumpSession, Alerts, RemoteProtocol, WatchLink, PhoneApp | MIT (in-repo) | first-party package | `Packages/` |
| swift-snapshot-testing (+ swift-custom-dump, xctest-dynamic-overlay MIT; swift-syntax Apache-2.0) | MIT | test-only package dependency, never shipped | `ios/faBolusAppTests` (`project.yml`) |
| pumpx2 captured message bytes | MIT (© 2022 James Woglom) | copied as test fixtures (jwoglom/pumpx2 `456018a5`) | `Packages/PumpSession/Tests/PumpSessionTests/Support/Captures.swift` |
| ShareClient | MIT | vendored (LoopKit/dexcom-share-client-swift), modified for Swift 6 | `Packages/ShareClient` |
| CGMBLEKit (G5/G6/ONE passive mode) | MIT (© 2015 Nathan Racklyeft) | copied (LoopKit/CGMBLEKit `c9e6c84`), trimmed to the passive read path | `Packages/DexcomBLE/G6`, `Packages/DexcomBLE/Sources/DexcomBLE` |
| G7SensorKit (G7/ONE+) | MIT (© 2022 LoopKit Authors) | copied (LoopKit/G7SensorKit `aeaec95`), LoopKit dependencies removed | `Packages/DexcomBLE/G7` |
| LoopKit `DoseEntry`, `PumpManagerStatus` naming | MIT (© 2016 Nathan Racklyeft, © 2018 LoopKit Authors) | adapted (names and shape, rewritten; LoopKit `a5beee96`) | `Packages/faBolusCore` `DoseEntry.swift`, `PumpState.swift` |
| LoopKit bolus-volume rounding (`roundToSupportedBolusVolume`, `matchingOrTruncatedValue`) | MIT (© 2018, © 2020 LoopKit Authors) | adapted (the round-down rule and its tolerance, rewritten for a fixed step; LoopKit `a5beee96`) | `Packages/faBolusCore` `BolusVolume.swift` |
| LoopKit `Alert` interruption level and Loop `UserNotificationAlertScheduler` | MIT (© 2020 LoopKit Authors) | adapted (the interruption-level model and the notification-center protocol and request shape, rewritten; LoopKit `a5beee96`, Loop `5465bcd`) | `Packages/faBolusCore` `NotificationBroker.swift`, `Packages/Alerts` `NotificationScheduling.swift` |
| TandemKit | MIT | local-path dependency (separate repo; vendors pumpX2-oracle MIT + Mbed TLS `Apache-2.0 OR GPL-2.0`) | `../TandemKit` |
| Garmin Connect IQ Mobile SDK | proprietary (`LicenseRef-Garmin-Proprietary`) | binary xcframework, credential-gated | Garmin companion build only |

**Trademarks.** "faBolus" is a trademark of Zev Granowitz (the code is MIT; the name is not licensed).
Tandem, t:slim X2, Mobi, Control-IQ, Dexcom and Garmin are trademarks of their respective
owners; faBolus is independent and unaffiliated.
