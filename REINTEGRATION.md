# REINTEGRATION.md — dev/glucose-badge

## Feature preserved

The CGM app-icon glucose badge (Phase 5, FEAT-03): the REAL `ios/faBolus/Data/GlucoseBadge.swift` (a
pure `value(for:now:)` freshness function + the `UNUserNotificationCenter.setBadgeCount` I/O sink,
opt-in-gated behind `AppSettings.shared.glucoseBadgeEnabled`), its Settings UI (the `Binding` wrapper +
the enable button/explainer in `SettingsView.swift`), its `SettingsCatalog.swift` descriptor, its
`AppSettings.swift` `backupSnapshot`/`applyBackup` entries, and `ios/faBolusAppTests/
BadgePublisherTests.swift` (12 tests pinning the real value/freshness logic — e.g.
`GlucoseBadge.value(for: snap, now: ...) == 142`).

## State at removal

This branch was cut from `pre-narrow/2026-08-20` (the annotated, current baseline tag) — the pristine
pre-removal tip, identical to `main` before Phase 7 Plan 02 (07-02, P-B) ran. Both the real
`GlucoseBadge.swift` and `BadgePublisherTests.swift` were already present, unmodified, at this branch
point — no extra commit was needed to preserve either. `main` has since:

1. `git rm`'d the real `GlucoseBadge.swift` and replaced it IN-PLACE (same path, exactly one
   `GlucoseBadge` symbol on main — no duplicate) with a main-only minimal NO-OP stub: `apply(_:now:)`/
   `clear()` do nothing, `value(for:now:)` always returns `0`, `import Foundation` only (no
   `UserNotifications`/`UNUserNotificationCenter`/`setBadgeCount`). The stub drops the `setBadge`
   injection parameter both real methods had (it existed only for `BadgePublisherTests`, which moves to
   this branch) — the 2 surviving call sites (`WidgetPublisher.swift`'s `GlucoseBadge.apply(snap)`,
   `AppModel.swift:1774`'s `GlucoseBadge.clear()`) never passed that parameter, so dropping it is
   compile-safe. `AppModel.swift:1774` stays completely BYTE-IDENTICAL — it calls the exact same
   `clear()` selector, now resolving to the stub's no-op body instead of the real zero-and-notify body.
2. `git rm`'d `BadgePublisherTests.swift` (it pins the removed REAL value/freshness logic — e.g.
   `#expect(GlucoseBadge.value(for: freshSnap, now: ...) == 142)` — and cannot stay green against a
   no-op stub that always returns `0`; Phase-1 D-07 move idiom). This branch's copy is untouched.
3. Deleted the badge Settings UI (the `Binding` wrapper + the enable button/explainer) from
   `SettingsView.swift` and the `glucoseBadgeEnabled` descriptor from `SettingsCatalog.swift`.
4. Removed the `glucoseBadgeEnabled` entry from `AppSettings.backupSnapshot()`/`applyBackup()` (so a
   restored backup never re-populates a key with no descriptor) and from `SettingsCatalogTests`'
   `ambientSurfaceFlags` set, and recomputed the two live descriptor/backed-up-key counts.
   `glucoseBadgeEnabled`'s property declaration + its `didSet` (still calling the stub's no-op `clear()`)
   + its default-`false` restore line are left in place, orphaned-but-compiled — no getter-freeze is
   needed since the stub itself is now the inertness mechanism (a restored `glucoseBadgeEnabled: true`
   simply has no effect, since `apply()` is a no-op regardless of the setting's value).
5. Added a FEAT-03 stub-inert case to `FeatureSurfaceAbsenceGuardTests.swift` (source-scans
   `GlucoseBadge.swift` for absence of `UNUserNotificationCenter`/`setBadgeCount`/
   `import UserNotifications`, and confirms `SettingsCatalog.swift`/`SettingsView.swift` have no
   `glucoseBadgeEnabled` reference) — this branch predates that file's FEAT-03 case; do not port it
   over, it asserts the opposite of what this branch's tree looks like.

## Reintegration path

1. `git rm` the main-only stub and restore this branch's real `GlucoseBadge.swift` at the same path
   (a hand merge if `main`'s call sites have moved since the cut — the stub's dropped `setBadge`
   parameter would need re-adding to match the real signature again).
2. Restore `BadgePublisherTests.swift` from this branch's tip.
3. Re-add the badge Settings UI to `SettingsView.swift` and the descriptor to `SettingsCatalog.swift`
   from this branch's copies.
4. Re-add the `glucoseBadgeEnabled` `backupSnapshot`/`applyBackup` entries and the
   `SettingsCatalogTests` `ambientSurfaceFlags` membership; recompute the live counts back up.
5. Delete the post-removal FEAT-03 case from `FeatureSurfaceAbsenceGuardTests.swift`.
6. `AppModel.swift:1774`'s `GlucoseBadge.clear()` call needs NO change either direction — verify it
   still compiles against the restored real `clear()` signature (it takes no required args either way).
7. Run the full exit gate (`check-dose-byte-identity.sh`, `xcodebuild build`, full test suite,
   `-only-testing:faBolusAppTests/BadgePublisherTests`) to confirm the re-added surface compiles and the
   12 real-freshness assertions pass again.
