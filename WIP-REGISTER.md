# WIP register — faBolus

**Created:** 2026-08-04, per §0.1 of `faBolus-handoff-v3.md` (capture in-progress work *before* any
branch operation or restructuring).

**Preservation actions already taken, before anything else:**

| Action | Detail |
|---|---|
| Uncommitted work committed | `8c34223` — R3-C durable acknowledged bolus-ID. Compiles; faBolusCore's 109 tests pass. Commit body states plainly that the deterministic test matrix is **not** written. |
| Auditor handoffs committed | `37ec0d3` — the two previously-untracked `claude-round{2,3}-audit-remediation-handoff-*.md` files. |
| Stash tagged | `wip/stash-0-stale-display-options` → the `stash@{0}` commit, so it survives any future `stash drop`. The stash itself is left in place. |
| `git status` | clean |

**Disposition key:** **R** = resume after restructuring · **F** = fold into the v3 plan · **A** = abandon
(with reason) · **N** = not our WIP (vendored upstream, platform requirement, or deliberate permanent design).

---

## 1. Branches and stashes

| # | Item | State | Disp. | Note |
|---|---|---|---|---|
| 1 | `remediation/audit-round3-2026-07-24` | 3 commits ahead of `main`, unmerged; 2 unpushed | **F** | Round-3 auditor remediation = v3 deliverables 6/7. Must land before or as group B. |
| 2 | `8c34223` R3-C — durable acknowledged bolus-ID | code complete, **tests absent** | **F** | Deliverable 7. Blocks nothing else, but must not be called done. |
| 3 | `remediation/audit-2026-07` | local-only, 0 ahead, fully merged | **A** | Stale pointer. Delete after `deprecated` is tagged (its content is in `main`). |
| 4 | local `main` has no upstream configured | identical to `origin/main` | **F** | Fix during §1 restructuring (`git branch -u`). |
| 5 | `stash@{0}` — 1-line `TandemBackend.swift` change | superseded on HEAD at `TandemBackend.swift:1344`; base branch deleted; reflog cites nonexistent `b50ab5d` | **A** | Zero value. Tagged, not dropped. |

## 2. Documented-but-unbuilt work (ROADMAP)

| # | Item | Disp. | Note |
|---|---|---|---|
| 6 | `ROADMAP.md:81-98` configurable max bolus (pump-max default + fallback + custom cap) | **R** | Owner deferred this deliberately on 2026-07-24. Interacts with v3 §2.3's optional remote-only dose ceiling — resolve together. |
| 7 | `ROADMAP.md:100-113` chained remotes | **R** | "Designed, NOT enabled", 3 named blockers. |
| 8 | `ROADMAP.md:115-130` Apple Watch host / phone-as-remote swap | **R** | Related to item 20 (the direct-pump watch), and to v3 C9. |
| 9 | `ROADMAP.md:71-75` docs/build-instruction refresh | **F** | Unmarked; fold into the v3 documentation work. |
| 10 | `EatingTrigger.swift:171-176` CGM unannounced-meal metrics are a literature placeholder (`cgmBaseFA = 1.5`, `cgmBaseRecall = 0.55`) | **R** | Belongs to the separate eating-model workstream; do not touch here. v3 §3.2 also asks whether UAM detection should exist at all — that is a product question for the owner. |
| 11 | Garmin official store listing dormant; default target `beta` (`GarminRemoteBridge.swift:32`, `AppSettings.swift:335`) | **R** | Intentional hold. |
| 12 | `DebugMenuView.swift:5-7` factory reset / shelf mode / raw-message console ported but deliberately unwired | **N** | Permanent by design. |

## 3. Test and verification gaps

| # | Item | Disp. | Note |
|---|---|---|---|
| 13 | `Packages/HistoryStore` tests never run — CI runs only `swift test --package-path Packages/faBolusCore` (`ci.yml:25`) | **F** | One-line CI fix. |
| 14 | `Packages/G7SensorKit` tests never run in CI | **F** | Same. |
| 15 | `Packages/DexcomG6Kit` tests never run in CI | **F** | Same. |
| 16 | `Packages/ShareClient` has no test target at all (`Package.swift:11`) | **N** | Vendored LoopKit; upstream shipped it untested. |
| 17 | `project.yml:439-440` — pump-transaction drop/timeout (A-03) and glucose single-flight (C-05) have no automated coverage | **F** | Now reachable via the R3-A `PumpTransport` seam + `FakePumpTransport`. Deliverable 7. |
| 18 | `docs/RELEASE-GATES.md:11-62` — 5 on-hardware gate categories open; `:39` IDP CRUD + backup-restore "unproven end-to-end" | **R** | Hardware-gated; unblocked only on the bench. |
| 19 | 39 unchecked acceptance criteria across the two committed auditor handoffs | **F** | Deliverables 6/7 close these. |

## 4. Feature flags and excluded targets

| # | Item | Disp. | Note |
|---|---|---|---|
| 20 | `FABOLUS_NUDGE` — 12 `#if` sites; **on locally, off in CI** (`ci.yml:53,104`) | **F** | Consequence: Smart Assist, the oref0 autotune adapter, the eating pipeline and personalization are **never compiled by CI**. Either compile them in CI or state that they are unbuilt. See the Reconciliation Report on §3.2. |
| 21 | `GARMIN` — `GarminRemoteBridge.swift:3,204,216`; on locally, off in CI | **F** | The Garmin bridge — a base feature per v3 §1.3 — is never compiled by CI. |
| 22 | `FABOLUS_ONWATCH_EATING` wraps all of `WatchEatingSensor.swift`; default OFF, stripped from the generated project | **R** | Compiled by nothing, anywhere. Eating-model workstream. |
| 23 | `ICLOUD_SYNC` — **no build configuration sets it** | **F** | So `ICloudSettingsSync` (`ICloudSync.swift:12-38`) is dead in every build and the no-op `#else` stub is what `App.swift:46,57` calls. iCloud settings sync does **not** work today despite the settings UI. Either wire the flag + entitlement or remove the UI. |
| 24 | `faBolusWidgets` (iOS) is **not embedded** in the `faBolus` target and is in no scheme | **F** | v3 N4 lists widgets as `main`/Simple/on and defect A4 is about widget staleness — but the extension does not ship. Fix before A4 can mean anything. |
| 25 | `faBolusWatchWidgets` **not embedded** (`project.yml:284-286`, needs the watch App Group registered) | **F** | The CI step named "Build watch app + complication" (`ci.yml:108`) does not build the complication. Rename the step or embed the target. |
| 26 | `faBolusMac` + `faBolusMacWidgets` in no scheme and no CI job | **F** | The macOS app is never compiled by CI; v3 §1.5 asks whether it is `main`-ready. It cannot be until CI builds it. |
| 27 | `hosts/loop/` — "design scaffold, not built"; `RemoteHost.swift.example` deliberately uncompilable | **N** | Open contribution placeholder. |
| 28 | `project.yml:114-115,126,129-130` — commented-out xDrip App Groups, ubiquity-kvstore, HealthKit entitlements | **R** | All gated on a paid Apple team. |
| 29 | `WATCH_EMBEDDED` (`project.yml:187,189`) | **N** | Working build switch. |

## 5. Half-finished code

| # | Item | Disp. | Note |
|---|---|---|---|
| 30 | ~~`watch/faBolusWatch/WatchPumpClient.swift` + `WatchDirectView.swift` — Phase-1 direct-to-pump watch, reachable from `WatchApp.swift:24`~~ **RESOLVED 2026-08-04** | **F** | Was: a second pump-connection holder bypassing the `PumpBackend` seam, shipping and user-visible, in direct conflict with v3 C9. Owner decision: **hide behind a default-off build flag**, matching `faBolusGarmin/direct-pump/`. Done — the five files moved to `watch/faBolusWatch/direct-pump/` (see its `STATUS.md`), excluded from the target unless `FABOLUS_WATCH_DIRECT_PUMP=1`, with the `PumpX2Messages`/`Auth`/`BLE` deps dropped alongside. `WatchPumpClient.swift` was the only watch file importing those, so a shipping watch build now **links no pump BLE stack at all** — verified in the generated project, and both flag states compile. |
| 31 | `watch/README.md:13-14` standalone phone-less watch build "designed but not built … paused" | **R** | Same decision as 30. |
| 32 | `ICloudSync.swift:41-46` — the live implementation in every build is an empty stub | **F** | Duplicate of 23; listed here because the code, not just the flag, is the artifact. |

## 6. Not our WIP

| # | Item | Note |
|---|---|---|
| 33 | `Packages/ShareClient/…/ShareClient.swift:55` `// TODO use an HTTP library…` | Vendored LoopKit. The **only** strict TODO/FIXME/HACK/XXX marker in the whole repo. |
| 34 | ~50 `.disabled(` hits in `ios/faBolus/Views/*` | SwiftUI view modifiers, not test gates. |
| 35 | WidgetKit `placeholder(in:)` implementations | Required by the API. |

---

## Negative results (recorded so they are not re-investigated)

- No `FIXME`, `HACK`, or `XXX` anywhere in the repo.
- No `XCTSkip*`, `func x_test`, `@Test(.disabled`, or commented-out test bodies anywhere.
- No `fatalError` / `preconditionFailure` / `assertionFailure` / `unimplemented` in any Swift source,
  including `Packages/faBolusCore`.
- Zero genuine commented-out code blocks over 5 lines.
- No open or closed pull requests in this repository.
- Scans covered git-tracked files only, so `build/`, `DerivedData/`, `.build/`, `*.xcodeproj/`, `site/`,
  `project.generated.yml` and `LocalConfig.xcconfig` were out of scope by construction.
