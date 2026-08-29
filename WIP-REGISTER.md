# Standing open work — faBolus

This is **not** a phase diary. Capture-day archaeology (2026-08-04) and later RESOLVED/SUPERSEDED rows live in git history of this file.

Branch model and promotion: [`BRANCHES.md`](BRANCHES.md). Product backlog: [`ROADMAP.md`](ROADMAP.md). Hardware NO-GO: [`docs/RELEASE-GATES.md`](docs/RELEASE-GATES.md).

Apple Watch host / remote / widgets are **not on `main`**. They live on `dev/watch-host` and `dev/watch-remote`. Do not treat `watch/` as a live tree here.

## Open

| Item | Why it stays listed |
|---|---|
| Hardware release gates | `docs/RELEASE-GATES.md` — NO-GO for real insulin until saline-bench categories close. Software CI is not a substitute. |
| Configurable max bolus / remote dose ceiling | Owner-deferred. Interacts with a remote-only cap. See ROADMAP. |
| Chained remotes | Designed, not enabled. Mac → parent phone → child host still needs a three-device bench. |
| Apple Watch host / phone-as-remote swap | Tracked on ROADMAP; code is on preservation branches, not `main`. |
| Eating-model UAM placeholders | `EatingTrigger` literature placeholders (`cgmBaseFA` / `cgmBaseRecall`). Eating-model workstream; not this app's insulin path. |
| Garmin official listing | Dormant; the app defaults to beta. Do not publish. |
| Debug factory reset / shelf / raw console | Ported, deliberately unwired. Permanent. |
| `FABOLUS_NUDGE` | Off in CI. Smart Assist / eating pipeline are not compiled on the CI path. |
| `FABOLUS_GARMIN` | Off in CI (ConnectIQ xcframework uncommitted). The compile flag is `GARMIN`. |
| `FABOLUS_ICLOUD` | Default off so a free-account clone signs. Real KV store only when the flag is on. |
| `hosts/loop/` | Design scaffold, not a build. `RemoteHost.swift.example` is deliberately uncompilable. |
| Commented Apple-team entitlements | Paid-team gated (xDrip App Groups, ubiquity-kvstore, HealthKit extras). |
| Vendored `ShareClient` TODO | LoopKit upstream; the only strict TODO in-tree. |

CI already runs `faBolusCore`, `HistoryStore`, `G7SensorKit`, and `DexcomG6Kit` tests. Do not re-open those as missing.

## Do not "fix"

- Do not set `PUMPX2_ALLOW_ORACLE_SKIP` (lives in TandemKit) or weaken fail-closed tests to green a build.
- Do not put Watch trees back on `main`.
