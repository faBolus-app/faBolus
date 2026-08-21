<!--
faBolus is experimental software controlling an insulin pump. The delivery disposition is NO-GO for
real insulin delivery; keep it that way unless changing it is the explicit subject of this PR.
Fill in what applies; delete what doesn't. See CONTRIBUTING.md and BRANCHES.md.
-->

## What & why

<!-- One or two sentences. What changes, and the problem it solves. -->

## Branch target

- [ ] `main` — meets every §1.4 promotion criterion (see BRANCHES.md)
- [ ] `experimental` — fires on a threshold / automates a decision / produces output not verifiable
      against the pump (§1.2), or otherwise not yet promotable

## Safety

- [ ] Does **not** weaken a safety interlock (confirmation, max-bolus clamp, single-flight, the
      idempotency ledger, fail-closed transport gating)
- [ ] Delivery disposition unchanged (**NO-GO for real insulin delivery**) — or this PR's explicit
      subject is changing it, and says so
- [ ] No glucose value reaches a display layer without a source timestamp; no client-derived trend
      arrow; no locally-invented IOB or therapy parameter (C4/C7/C8)
- [ ] If this touches dosing guidance, thresholds, or automation copy: the clinical-review gate
      (BRANCHES.md) is noted — such work does not reach anyone but the developer until that review lands

## Contract

- [ ] Did **not** touch `schema/command.schema.json`
- [ ] — or did, and: bumped `version`, updated the Swift `RemoteCommand` **and** the Monkey C mirror in
      faBolusGarmin, kept changes additive/optional, and `scripts/check-schema-drift.sh` passes in both repos

## Verification

<!-- Paste the commands you ran and their result. CI's Xcode is stricter than a typical local one, so
     "builds locally" is necessary but not sufficient — say what you expect CI to confirm. -->

- [ ] `swift test --package-path Packages/faBolusCore` (and HistoryStore / G7SensorKit / DexcomG6Kit if touched)
- [ ] `./scripts/build-sim.sh` / `./scripts/test-ios.sh` as applicable
- [ ] Shared-code changes build cleanly (watch/Mac remotes are removed from `main` — delete-on-main;
      see `dev/watch-remote`/`dev/watch-host`/`dev/mac` if you're restoring one of them)
- [ ] Hardware-tested vs. compile-only noted

## Cross-repo

- [ ] N/A — single repo
- [ ] Touches the contract or a shared constant → sibling PR(s) linked, and the branch-aware CI resolved
      the matching sibling branch (check the `resolve-refs` / `fbref` log line for the ref **and SHA**)
