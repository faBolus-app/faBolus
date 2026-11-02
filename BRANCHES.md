# Branches

This covers all three repositories: faBolus, [TandemKit](https://github.com/faBolus-app/TandemKit) and
[faBolusGarmin](https://github.com/faBolus-app/faBolusGarmin). Their own `BRANCHES.md` points here.

## `main`

`main` is the only long-lived branch in each repository. Work happens on short-lived branches with a
pull request into `main`. fabolus.org publishes the docs from faBolus's `main`.

The three repositories move together: build faBolus and faBolusGarmin from `main`, or from the same
release tag. A phone app and a watch app from different releases may not talk to each other.

How the three are tied together:

- faBolus pins a TandemKit release by version, the same one in `Packages/PumpSession/Package.swift` and
  `Packages/PhoneApp/Package.swift`. CONTRIBUTING.md says how to build against a local TandemKit checkout.
- faBolusGarmin vendors the phone↔watch contract from a faBolus commit, recorded in `contract/PIN`, with
  `scripts/sync-contract.sh`. Its CI checks the vendored files against faBolus at that commit, so the
  commit must be pushed.

## Tags

- **Version tags** mark releases, and each repository's `CHANGELOG.md` lists its own. `v0.4.0`, in all
  three repositories, is the first release of the rebuilt app. `v0.1.0` to `v0.3.0` are builds of the
  earlier app.
- **`v1-final`**, in each repository: the last `main` of the earlier app, before the rebuild. Going back
  to the earlier app means building from `v1-final`, the phone app and the watch app together: the
  earlier watch app doesn't talk to the new phone app, or the other way round.
- **`archive/<branch>`**: every side branch, kept as a tag when it was deleted. `archive/dev/*` holds
  features that aren't in the new app, each with a `REINTEGRATION.md` saying what it holds. They're
  reference, not merge candidates.
- **`deprecated/*`, `safe-baseline/*`, `pre-narrow/*` and similar** are historical snapshots of the earlier
  app, kept for comparison only.
