# Branches

This covers all three repositories: faBolus, [TandemKit](https://github.com/faBolus-app/TandemKit) and
[faBolusGarmin](https://github.com/faBolus-app/faBolusGarmin). Their own `BRANCHES.md` points here.

## Now: `main` and `rebuild`

| Branch | What it is |
| --- | --- |
| `main` | The earlier app, as it was when the rebuild started. It gets no new work. fabolus.org is published from it. |
| `rebuild` | The new app, rebuilt from the ground up. All work happens here, or on short-lived branches merged into it. |

The three repositories move together: build faBolus and faBolusGarmin from the same branch. The two
watch apps don't talk to each other's phone apps, so a `main` phone app needs a `main` watch app, and a
`rebuild` phone app a `rebuild` watch app.

How the three are tied together on `rebuild`:

- faBolus pins a TandemKit release by version, the same one in `Packages/PumpSession/Package.swift` and
  `Packages/PhoneApp/Package.swift`. CONTRIBUTING.md says how to build against a local TandemKit checkout.
- faBolusGarmin vendors the phone↔watch contract from a faBolus commit, recorded in `contract/PIN`, with
  `scripts/sync-contract.sh`. Its CI checks the vendored files against faBolus at that commit, so the
  commit must be pushed.

## After the merge: `main` only

The three `rebuild` branches merge into `main` together, and then:

- `main` is the only long-lived branch in each repository, and `rebuild` is deleted;
- work happens on short-lived branches with a pull request into `main`;
- fabolus.org publishes the new app's docs, from `main`;
- faBolus's TandemKit pin and faBolusGarmin's `contract/PIN` point at release commits;
- this file covers `main` alone.

## Tags

- **`v1-final`**, in each repository: the last `main` before the rebuild. Going back to the earlier app
  means building from `v1-final`, the phone app and the watch app together.
- **`archive/<branch>`**: every side branch, kept as a tag when it was deleted. `archive/dev/*` holds
  features that aren't in the new app, each with a `REINTEGRATION.md` saying what it holds. They're
  reference, not merge candidates.
- **Version tags** mark releases, and each repository's `CHANGELOG.md` lists its own. `v0.1.0` to `v0.3.0`
  are builds of the earlier app; `v0.4.0`, in all three repositories, is the first release of the new one.
- **`deprecated/*`, `safe-baseline/*`, `pre-narrow/*` and similar** are historical snapshots of the earlier
  app, kept for comparison only.
