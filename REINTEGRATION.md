# REINTEGRATION.md — dev/child-mode

## Feature preserved

Child (locked) mode: a PIN-protected mode a parent enables on a child's device. When on, only the
features in `childAllowed` (`ChildFeature`: `bolus`, `cancelBolus`, `dismissAlerts`,
`advancedControl`, `changeSettings`) are permitted — insulin delivery is blocked by default. The
whole editor UI (`ChildModeView.swift`: `PinEntryView`, `ChildModeView`, `SettingsLockGate`), the
Keychain-backed PIN store (`ChildModeStore` in `ios/faBolus/Data/ChildMode.swift`), the 3
`SettingsView.swift` nav sites (sidebar label, `sidebarDestination` router case, main-list
`NavigationLink`) + the `SettingsSidebarItem.childMode` enum case, and the 2 `SettingsCatalog`
descriptors (`childModeEnabled`, `childAllowed`).

## State at removal

This branch was cut from `pre-narrow/2026-08-20` (the annotated, current baseline tag), then synced
to `main`'s current `DOSE_PATHS` state (`AppModel.swift` + the `DoubleToIntTrapGuardTests.swift`
retirement — see this branch's own sync commit) so `check-dose-byte-identity.sh` passes for it too.
`main` has since (Phase 7, 07-04, P-D, FEAT-04):

1. **Runtime-gated + belt-and-suspenders frozen** `ios/faBolus/Data/AppSettings.swift`'s
   `childModeEnabled` and `requireRemoteBolusApproval` to a getter-level constant `false`
   (`{ get { false } set { } }`) — no setter effect, including a restored-from-backup `true`, can
   ever make either `true` again. `requireRemoteBolusApproval`'s local-backup round trip
   (`backupSnapshot`/`applyBackup`) had already been fully removed in Phase 3 (03-02, F-1); this
   branch closes the remaining `childModeEnabled` half of that round trip (its `applyBackup` restore
   line is removed) and adds the getter-level freeze to BOTH properties as the second
   belt-and-suspenders layer (per 07-OWNER-FLAGS.md's FEAT-04 resolution — do BOTH). This branch's
   copies of both properties are the original `didSet`-backed, freely-settable stored properties, with
   their original `UserDefaults` init-restore lines and (for `childModeEnabled`) `backupSnapshot`/
   `applyBackup` participation intact.
2. `git rm`'d `ios/faBolus/Views/ChildModeView.swift` in full (`PinEntryView`, `ChildModeView`, and
   `SettingsLockGate` — all three types lived in this one file). This branch's copy is untouched.
3. **NEW FINDING beyond the plan's stated file list** (found via systematic grep, not in
   07-RESEARCH.md/07-PATTERNS.md): `SettingsLockGate` — defined inside `ChildModeView.swift` — was a
   LIVE wrapper around the ENTIRE Settings screen on `main` (both the iPad split view and the iPhone
   compact `NavigationStack`, `SettingsView.swift`, 2 call sites), gating all of Settings behind the
   child-mode PIN whenever `childModeEnabled && !childAllows(.changeSettings)`. Since
   `childModeEnabled` is now permanently `false`, this wrapper can never lock again — `main` removes
   both `SettingsLockGate(settings: settings) { ... }` call sites (replaced with the wrapped content
   directly) so the now-fully-inert type has no remaining reference and can be deleted along with the
   rest of the file. This branch's copy of `SettingsView.swift` still has both wrapper call sites.
4. `git rm`'d `ios/faBolus/Data/ChildMode.swift` (`ChildModeStore`, the Keychain PIN store) — a SECOND
   **NEW FINDING**: once `ChildModeView.swift`'s `PinEntryView`/`ChildModeView` (its only callers) are
   gone, `ChildModeStore` has zero remaining callers anywhere in the app (confirmed via repo-wide
   grep). This branch's copy is untouched.
5. Deleted the 3 Child Mode nav sites in `SettingsView.swift` (the sidebar `Label`/`.tag`, the
   `sidebarDestination` router `case .childMode: ChildModeView(...)`, the main-list `NavigationLink`)
   + the `SettingsSidebarItem.childMode` enum case + the "Child mode locks this device behind a PIN."
   footer text (reworded, since its Section still hosts Data & history / Privacy & data). This
   branch's copy has all of the above intact.
6. Deleted the `childModeEnabled`/`childAllowed` `SettingsCatalog.swift` descriptors + recomputed the
   `SettingsCatalogTests.swift` descriptor/backed-up-key counts and `gatedOffSearchTokens` live. This
   branch's copy of both files predates the removal.
7. **Retired 4 test blocks that directly asserted the NOW-REMOVED "child mode blocks delivery"
   behavior** (they exercised `AppSettings.shared.childModeEnabled = true` through the real
   `AppModel`/app-layer wiring — a setter that is now permanently a no-op):
   `AppModelBehaviorTests.swift`'s `childModeBlocksRemoteBolus` and `childModeBlocksWidgetBolus` tests
   (deleted in full), the "Fail-closed: fully locked" child-mode block inside
   `surfaceActionMatrixRoutesThroughTheEvaluator` (deleted, the rest of that test — remotesReadOnly +
   peer denial — is untouched), and the "child mode (watch surface)" block inside
   `StaleRemoteDoseHostTests.swift`'s `gatesDenyBeforeResolveEvenWithIncludeStale` (deleted, its
   sibling `remotesReadOnly` block is untouched). **The pure-evaluator coverage of "IF childModeEnabled
   were true, `AccessPolicy` blocks X" is NOT lost** — `Packages/faBolusCore/Tests/faBolusCoreTests/
   AccessPolicyTests.swift` constructs `AccessContext(childModeEnabled: true, ...)` literals directly
   (bypassing `AppSettings` entirely) and is completely unaffected by this branch's removal; it still
   proves the evaluator itself would correctly enforce child mode if it were ever given `true` again.
   This branch's copies of both app-layer test files still have all 4 original blocks.
8. Authored `ChildModeFreezeGuardTests.swift` (new, Wave 0, SAFETY) — asserts
   `applyBackup(["childModeEnabled": .bool(true)])` leaves `childModeEnabled == false`, and that a
   direct `requireRemoteBolusApproval = true` setter call leaves it `false`. This branch has no such
   file (it predates the removal); do not port it over on reintegration, it asserts the opposite of
   what this branch's tree looks like.
9. Registered this surface's tokens in
   `ios/faBolusAppTests/SettingsCatalogTests.swift`'s `CompileGateAudit.gatedOffSearchTokens` (§6c
   no-dangling-refs audit) — this branch's copy predates the addition.

## Reintegration path

1. Cherry-pick (or manually re-apply) `ios/faBolus/Views/ChildModeView.swift` and
   `ios/faBolus/Data/ChildMode.swift` back onto the target tree from this branch's tip.
2. In `AppSettings.swift`, restore `childModeEnabled`/`requireRemoteBolusApproval` to this branch's
   original `didSet`-backed stored-property form (remove the `{ get { false } set { } }` freeze),
   restore the `UserDefaults` init-restore lines, and restore `childModeEnabled`'s
   `backupSnapshot`/`applyBackup` participation (`requireRemoteBolusApproval`'s local-backup round
   trip was removed independently in Phase 3, 03-02 — reintegrating it is a separate decision, not
   part of undoing THIS branch's freeze).
3. In `SettingsView.swift`, restore the 2 `SettingsLockGate(settings: settings) { ... }` wrapper call
   sites (regular-width split view + compact `NavigationStack`) from this branch, restore the 3
   Child Mode nav sites + the `SettingsSidebarItem.childMode` enum case, and restore the "Child mode
   locks this device behind a PIN." footer wording.
4. In `SettingsCatalog.swift`, restore the `childModeEnabled`/`childAllowed` descriptors from this
   branch.
5. In `SettingsCatalogTests.swift`, recompute descriptor/backed-up-key counts and remove this
   surface's tokens from `gatedOffSearchTokens`.
6. Restore the 4 retired test blocks (2 whole tests in `AppModelBehaviorTests.swift` + the 2 embedded
   blocks in `surfaceActionMatrixRoutesThroughTheEvaluator`/`gatesDenyBeforeResolveEvenWithIncludeStale`)
   from this branch's copies.
7. Delete the main-side `ChildModeFreezeGuardTests.swift` (it asserts the frozen state; reintegration
   un-freezes it).
8. `Packages/faBolusCore/{ChildFeature,AccessPolicy,BolusGate,GatedPumpWrite}.swift` were NEVER
   touched by the removal — no action needed there; the evaluator has been byte-identical the whole
   time.
9. Rebuild + run the full suite; `SettingsReachabilityGuardTests`/`SettingsSidebarParityTests`/
   `SettingsCatalogTests` will need their counts recomputed again for the restored descriptors/nav
   case.
