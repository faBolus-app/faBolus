# LoopPowerPack — Vendored Upstream Provenance

This tree holds MIT-licensed feature source copied in from the **LoopPowerPack** fork of Loop, adapted
behind thin faBolus adapters. Vendored source does **not** auto-merge (D-01): the drift detector
surfaces upstream fixes for **manual** application only.

## Pinned upstream

| Field | Value |
|---|---|
| Fork | `LoopPowerPack/Loop` |
| Local mirror | `/Users/zgranowitz/Code/zgranowitz/LoopPowerPack-Loop` |
| Pinned commit (SHA) | `ad4c4d498f936a25e22dd3a8dc93354138458509` (short `ad4c4d4`, `feat/AllFeatures`) |
| License | MIT (© 2015 Nathan Racklyeft, © 2016 LoopKit Authors; SiteAtlas © 2026 LoopKit Authors and Taylor Patterson) |

The `feat/*` branches are **cumulative** — features are isolated by DIRECTORY, not by branch diff.

## Per-feature vendor table

| Feature | Vendored path | Upstream source dir | Status |
|---|---|---|---|
| SiteAtlas | `SiteAtlas/SiteAtlas_Models.swift` | `Loop/Models/SiteAtlas/` | vendored (models only, this slice — 09.18a-01) |

> BodyMap PNG graphics (`BodyMapFront.png` / `BodyMapBack.png`) are **NOT** vendored here — their MIT
> graphics-exception is unresolved and is deferred to 09.18a-04's human-verify checkpoint.

## Policy (D-01 / D-02)

1. **No auto-merge.** Each vendored file is adapted behind a faBolus adapter and will not silently take
   upstream changes. Upstream fixes are applied by hand after the drift detector flags them.
2. **Provenance marker.** Every vendored `.swift` file carries a one-line header naming the upstream
   fork, pinned SHA, and license (the exact marker token `scripts/check-sbom.sh` greps for), plus an
   `SBOM.md` row with an SPDX token.
3. **Drift detection.** `scripts/check-vendor-drift.sh` records a sorted `shasum -a 256` manifest of
   every tracked file under this tree (`.vendor-manifest.sha256`) and fails non-zero if any vendored
   byte changes without a manifest update (`--update`). This is a **source-tree integrity check**, NOT
   a schema-property check — deliberately distinct from `scripts/check-schema-drift.sh` (D-02).

## Re-vendoring from a new upstream SHA

1. Copy the new upstream file(s) in, re-adding the provenance marker line with the new SHA.
2. Update the pinned SHA in this file and the `SBOM.md` / `THIRD_PARTY.md` / `NOTICE.md` rows.
3. Run `bash scripts/check-vendor-drift.sh --update` to regenerate `.vendor-manifest.sha256`.
4. Re-apply any faBolus adapter deltas by hand; never auto-merge.
