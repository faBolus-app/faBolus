# Changelog

All notable changes to **faBolus** are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/) for its user-facing `MARKETING_VERSION` (single-sourced in
`Config.xcconfig`; see [`BRANCHES.md`](BRANCHES.md) §1.3).

**Disposition:** faBolus is experimental and **NOT FDA-cleared**. The delivery disposition is
**NO-GO for real insulin** — saline bench only. Nothing recorded here changes that.

Two kinds of git tag track this repo (see [`BRANCHES.md`](BRANCHES.md)): **version** tags (`vX.Y.Z`)
mark releases and appear as sections below; **process** tags — the *moving* `safe-baseline/*`
last-known-good pointer and the *immovable* `deprecated/*` pre-fix snapshot — are rollback / forensic
markers rather than releases, and are listed under Unreleased until a version is cut.

## [Unreleased]

### Added
- Root `CHANGELOG.md` (this file), in Keep a Changelog format (P16).
- Standing safety-guard test (`RescueCarbGuardTests`, faBolusCore) enforcing P16 §8-H: the app must
  **never** surface a suggested rescue-carbohydrate amount for treating a low. It scans the app +
  faBolusCore sources on every `swift test` run and fails if such an API/string is reintroduced.
- **§1.3 versioning + cross-repo contract** documented in `BRANCHES.md`: app-version single-sourcing,
  the backend (PumpX2Kit) version-pinning contract, the Garmin lockstep clause, an
  app × faBolusGarmin × `RemoteCommand` schema **compatibility matrix**, and the published **minimum
  Garmin device set** (`venu3s` hardware-validated; the `manifest.xml` `iq:products` build-target set).
  Cross-referenced from `AGENTS.md` and `CONTRIBUTING.md`.

### Changed
- App `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` are now **single-sourced in `Config.xcconfig`** and
  inherited by all six targets (`faBolus`, `faBolusWatch`, `faBolusWatchWidgets`, `faBolusWidgets`,
  `faBolusMac`, `faBolusMacWidgets`); the per-target version literals were removed from `project.yml`.
  Docs/config only — no delivery, dosing, or alerting behavior changes.

### Removed
Prohibited advisory/experimental features removed per P16 §3.2 (`faBolus-internal` Reconciliation
Report R1/R2/R5/R6). All were advisory display/alerting only and off (or not toggle-gated) —
**none disabled, blocked, or clamped a dose**, and the delivery disposition (**NO-GO for real
insulin**) is unchanged.
- **Predictive-low (hypo) banner** (R5) — the in-app "low likely soon" advisory banner and its
  *Predictive-low alerts* toggle. It was a glucose forecast (prohibited); off by default. If you had
  it enabled it no longer appears.
- **Bolus guardrail** (R6) — the advisory guardrail warnings on the bolus screen (predicted-low /
  stacking / oversized) and their *Bolus guardrail* toggle. Advisory-only and off by default; **no
  dose was ever blocked or changed**. If you had it enabled the advisory strings no longer appear.
- **Data & History "Settings suggestions"** (R1 + R2) — the oref0 *autotune* basal/ISF/carb-ratio
  suggestions, the autosens-style *insulin-sensitivity* assessment, and the *suggested ISF / carb
  ratio / basal* advice. All derived a personalized recommendation from your own data (prohibited).
  Retrospective **Insights** (time-in-range, recurring patterns) are unaffected and remain.

### Declared unmet
- **Backend version-pinning is declared UNMET** (§1.3): faBolus still consumes PumpX2Kit by
  `path: ../PumpX2Kit` because the backend's crypto target uses `.unsafeFlags`, which SwiftPM forbids in
  a URL+version dependency, and the in-progress M1 driver depends on path-consumption. Declared here per
  the plan rather than silently satisfied by the local path. See `BRANCHES.md` §1.3.

### Accepted gaps (owner decision 2026-08-09)
- **§2.1(7) validated-firmware WRITE gate — NOT built (accepted).** No general firmware-version
  write-allowlist was added across therapy writes. Pump capabilities are already derived from the pump's
  own op-79 feature bitmask (narrow-only), so an unsupported write is refused at the capability funnel and
  NACKed by the pump; and the disposition is **NO-GO for real insulin** (saline bench). The Control-IQ
  config compatibility pre-flight (`setControlIQ`, P14 S11) is the one firmware/CIQ-version check that IS
  enforced. Recorded (not silently skipped); reconsider under §13 if real-insulin distribution is pursued.
  Authoritative record: `faBolus-internal/REMEDIATION.md` ("Accepted gaps").

### Baseline pointers advanced since 0.1.0 (development, not yet cut as a release)
- `safe-baseline/2026-08-04` — P13a-1 capability channel (`supportsRemoteAlertDismiss`).
- `safe-baseline/2026-08-06-p14` — P14 complete (S1–S12) + P15 partial.
- `safe-baseline/2026-08-07-p15` — P15 complete: §2.3 remote-bolus auth + Addendum B stale-CGM bolus
  prompt. NO-GO for real insulin.

## [0.1.0] — 2026-07-20

Initial tagged build: an experimental remote-bolus + status app for the Tandem t:slim X2 / Mobi, with
iPhone, Apple Watch, macOS, Garmin, and widget surfaces speaking the versioned `RemoteCommand` wire
contract (schema version 1). Delivery disposition: **NO-GO for real insulin.**

- `deprecated/2026-08-04-v0.1.0-build1` freezes `main` as it stood on 2026-08-04, **before** the round-3
  safety fixes. It is a forensic snapshot, **not** a supported fallback — rolling back to it reintroduces
  every known P0. See `BRANCHES.md`.

[Unreleased]: https://github.com/faBolus-app/faBolus/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/faBolus-app/faBolus/releases/tag/v0.1.0
