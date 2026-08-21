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
(with reason) · **N** = not our WIP (vendored upstream, platform requirement, or deliberate permanent design)
· **RESOLVED** = landed since this register was written (cited to the phase/commit; reconciled at the P16
close-out, 2026-08-07).

---

## 1. Branches and stashes

| # | Item | State | Disp. | Note |
|---|---|---|---|---|
| 1 | ~~`remediation/audit-round3-2026-07-24` — 3 commits ahead of `main`, unmerged~~ | **RESOLVED (P85 / V3-P3)** | Round-3 auditor remediation (v3 deliverables 6/7) landed via the TandemKit→faBolus→Garmin merge chain — `git branch --merged origin/main` lists the branch, so it is fully contained in `main`. The stale local pointer may be deleted. |
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
| 18 | `docs/RELEASE-GATES.md:11-62` — 5 on-hardware gate categories open; `:39` IDP CRUD + backup-restore "unproven end-to-end" | **R — standing NO-GO hold** | Hardware-gated; unblocked only on the saline bench. **Kept OPEN at P16 close-out** — these gates are the safety boundary (NO-GO for real insulin) and must not be reclassified as done-in-software. |
| 19 | 39 unchecked acceptance criteria across the two committed auditor handoffs | **F** | Deliverables 6/7 close these. |

## 4. Feature flags and excluded targets

| # | Item | Disp. | Note |
|---|---|---|---|
| 20 | `FABOLUS_NUDGE` — 12 `#if` sites; **on locally, off in CI** (`ci.yml:53,104`) | **F** | Consequence: Smart Assist, the oref0 autotune adapter, the eating pipeline and personalization are **never compiled by CI**. Either compile them in CI or state that they are unbuilt. See the Reconciliation Report on §3.2. |
| 21 | `GARMIN` — `GarminRemoteBridge.swift:3,204,216`; on locally, off in CI | **F** | The Garmin bridge — a base feature per v3 §1.3 — is never compiled by CI. |
| 22 | `FABOLUS_ONWATCH_EATING` wraps all of `WatchEatingSensor.swift`; default OFF, stripped from the generated project | **R** | Compiled by nothing, anywhere. Eating-model workstream. |
| 23 | `ICLOUD_SYNC` — **no build configuration sets it** | **RESOLVED (P14 S5)** | Was: dead in every build (no-op `#else` stub). Fixed in P14 S5 — renamed to `FABOLUS_ICLOUD`, gated by `generate-project.sh` (default OFF strips the entitlement + flag so a free-account clone signs; `FABOLUS_ICLOUD=1` compiles the real store). No in-app toggle (owner 2026-08-06): automatic when signed in, silent local-only fallback via `ubiquityIdentityToken`. Syncs only the C5-safe subset (`SettingsCatalog.iCloudSyncedKeys` — excludes the five command-adjacent flags). |
| 24 | ~~`faBolusWidgets` (iOS) is **not embedded** in the `faBolus` target and is in no scheme~~ | **RESOLVED (P4 / P86)** | Now embedded as a target dependency of `faBolus` (`project.yml:99` `- target: faBolusWidgets`) and built by the primary `faBolus` scheme; the A4 widget-staleness work now has a shipping extension to act on. |
| 25 | ~~`faBolusWatchWidgets` **not embedded**; CI step name misleading~~ | **SUPERSEDED (Phase 3, 03-03, 2026-08-21)** | Was RESOLVED (P16 verify): embedded as a target dependency of `faBolusWatch`, built by the `WatchCI` scheme. Now moot — the whole `faBolusWatch`/`faBolusWatchWidgets` target tree + the `WatchCI` scheme are delete-on-main (REMOTE-03), preserved on `dev/watch-remote`. |
| 26 | ~~`faBolusMac` + `faBolusMacWidgets` in no scheme and no CI job~~ | **RESOLVED (P4 / P86)** | The `mac-build` CI job (`ci.yml:176-212`) builds the `faBolusMac` scheme, which embeds `faBolusMacWidgets`. §1.5 macOS main-readiness is now answerable in software (green in CI); remaining gaps are hardware-only. |
| 27 | `hosts/loop/` — "design scaffold, not built"; `RemoteHost.swift.example` deliberately uncompilable | **N** | Open contribution placeholder. |
| 28 | `project.yml:114-115,126,129-130` — commented-out xDrip App Groups, ubiquity-kvstore, HealthKit entitlements | **R** | All gated on a paid Apple team. |
| 29 | ~~`WATCH_EMBEDDED` (`project.yml:187,189`)~~ | **SUPERSEDED (Phase 3, 03-03, 2026-08-21)** | Was **N** (working build switch). The whole Watch target it gated is delete-on-main (REMOTE-03) — the flag no longer exists in project.yml at all; `#if !WATCH_EMBEDDED` fallbacks are now the permanent (only) state. |

## 5. Half-finished code

| # | Item | Disp. | Note |
|---|---|---|---|
| 30 | ~~`watch/faBolusWatch/WatchPumpClient.swift` + `WatchDirectView.swift` — Phase-1 direct-to-pump watch, reachable from `WatchApp.swift:24`~~ **RESOLVED 2026-08-04** | **SUPERSEDED (Phase 3, 03-03, 2026-08-21)** | Was RESOLVED 2026-08-04 (hidden behind the default-off `FABOLUS_WATCH_DIRECT_PUMP` build flag). Now moot — the whole `watch/faBolusWatch/` tree (incl. `direct-pump/`) is delete-on-main (REMOTE-04), preserved on `dev/watch-host`; see `dev/watch-host`'s `REINTEGRATION.md` and `ROADMAP.md`'s "Apple Watch host / phone-as-remote swap" for the reintegration path. |
| 31 | ~~`watch/README.md:13-14` standalone phone-less watch build "designed but not built … paused"~~ | **SUPERSEDED (Phase 3, 03-03, 2026-08-21)** | Same disposition as 30 — `watch/README.md` itself is delete-on-main along with the rest of `watch/`, preserved on `dev/watch-remote`. |
| 32 | ~~`ICloudSync.swift:41-46` — the live implementation in every build is an empty stub~~ | **RESOLVED (P14 S5)** | Resolved with item 23 via the `FABOLUS_ICLOUD` gate: default OFF compiles the no-op stub (so a free-account clone signs); `FABOLUS_ICLOUD=1` compiles the real KV store. The stub is now the deliberate free-account path, not dead code. |

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
