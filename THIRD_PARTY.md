# Third-party components (faBolus)

By-name index of every third-party / vendored / ported component the faBolus Apple app ships or builds
against, satisfying §3.1 deliverable-3 "produce `THIRD_PARTY.md` per repo". This is a human summary; the
**machine-checked** source of truth is [`docs/SBOM.md`](docs/SBOM.md) (enforced by
`scripts/check-sbom.sh`, audit L-01), and the attribution prose is in [`NOTICE.md`](NOTICE.md). faBolus
itself is MIT (see `LICENSE`).

| Component | License | Kind | Where |
|---|---|---|---|
| faBolusCore, HistoryStore | MIT (in-repo) | first-party package | `Packages/` |
| ShareClient | MIT | vendored (LoopKit/dexcom-share-client-swift) | `Packages/ShareClient` |
| **LoopPowerPack (SiteAtlas, FoodFinder, LoopInsights)** — removed from `main` | **MIT** (© 2026 LoopKit Authors and Taylor Patterson) | vendored (LoopPowerPack/Loop MIT feature source @ `ad4c4d4`). LoopInsights: benign report DTO shapes ONLY — the endo-report aggregator/PDF were faBolus rewrites, the excluded AI/advisor/coordinator surfaces were never vendored | `dev/retrospective` (LoopInsights), `dev/backup` (SiteAtlas), `dev/food-finder` (FoodFinder) — see `NOTICE.md`, `docs/SBOM.md` |
| **OpenFoodFacts** (product data) | **ODbL 1.0** (database) / product data © OpenFoodFacts contributors | keyless public REST API — no code vendored; FoodFinder carb-estimate default path (D-03) | `world.openfoodfacts.org` (`api/v3` + `cgi/search.pl`) |
| TandemKit | MIT | local-path dependency (separate repo; vendors pumpX2-oracle MIT + Mbed TLS `Apache-2.0 OR GPL-2.0`) | `../TandemKit` |
| **XDripAppGroupSource.swift** | **MIT** (© 2016 Mark Wilson, via JohanDegraeve/xdrip-client-swift) | **ported app-tree source** | `ios/faBolus/Data/Sources/` |
| **LibreLinkUpSource.swift** | independent Swift impl (API knowledge from nightscout-librelink-up MIT + libre-link-unofficial-api; no upstream code copied) | **API-derived app-tree source** | `ios/faBolus/Data/Sources/` |
| Garmin Connect IQ Mobile SDK | proprietary (`LicenseRef-Garmin-Proprietary`) | binary xcframework, credential-gated | Garmin companion build only |
| faBolusNudge | MIT (code); model/dataset out of scope | pinned advisory SDK (separate repo) | rev `c3d1e228` |

**Trademarks.** "faBolus" is a trademark of Zev Granowitz (the code is MIT; the name is not licensed).
Tandem, t:slim X2, Mobi, Control-IQ, Dexcom, Garmin, FreeStyle Libre are trademarks of their respective
owners; faBolus is independent and unaffiliated.
