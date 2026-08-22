# REINTEGRATION.md — dev/food-finder

## Feature preserved

FoodFinder / food-scanner (Phase 7, FEAT-07): barcode scan + OpenFoodFacts lookup, the opt-in
BYO-key AI carb-estimate path (photo/text → a user-connected AI provider, `FoodFinderAICarbParse`),
the on-device Keychain key store (`FoodFinderAIKeyStore`), and the `BolusEntryView` "Find food"
carb-seam entry point (a UI text-field write into `carbsText` that the user still confirms — never a
store/calculator path). The whole surface: `ios/faBolus/Data/FoodFinder/*` (3 files),
`ios/faBolus/Views/FoodFinder/*` (2 files), `ios/faBolus/Vendor/LoopPowerPack/FoodFinder/*` (6 files).

## State at removal

This branch was cut from `pre-narrow/2026-08-20` (the annotated, current baseline tag) — the pristine
pre-removal tip, identical to `main` before Phase 7 Plan 01 (07-01, P-A) ran. `main` has since:

1. `git rm`'d all 3 FoodFinder directories (13 source files total) — this branch's copies are
   untouched.
2. Deleted the `BolusEntryView.swift` carb-seam: the `showFoodFinder` `@State` var, the "Find food"
   entry-point button/row, and the `.sheet(isPresented: $showFoodFinder) { ... FoodFinderView(...) }`
   modifier. This branch's copy of `BolusEntryView.swift` still has all three.
3. Deleted the 4 now-orphaned `AppSettings.swift` FoodFinder-AI members that had zero remaining
   reader once `Views/FoodFinder/*` went: `foodFinderAIEnabled`, `foodFinderAINoticeAckAt`,
   `hasAcknowledgedFoodFinderAINotice`, `acknowledgeFoodFinderAINotice` (+ their two
   `init`-restore lines). None of these were ever a `SettingsCatalog` row or in `backupSnapshot`
   (device-local, same idiom as `graphDetailEnabled`) — deleting them required no catalog/backup
   change. This branch's copy of `AppSettings.swift` still has all 4.
4. Surgically edited the SHARED `NSCameraUsageDescription` string (`project.yml`'s
   `info.properties`, which generates `ios/faBolus/Info.plist`) to drop ONLY the food-barcode
   clause, keeping the peer-remote QR-pairing clause verbatim (that scanner is a separate,
   independently-scheduled removal — Phase 3/REMOTE-02 — and is not affected by this branch's
   cut). This branch's copy of `project.yml`/`Info.plist` still has the combined string:
   `"faBolus uses the camera to scan a pairing QR code when connecting to another phone as a
   remote, and to scan food barcodes for a carb estimate you review — it never doses for you."`
5. Converted the `FABOLUS_FOODFINDER` compile gate to delete-on-main: removed the
   `# >>> FOODFINDER … # <<< FOODFINDER` fence from `project.yml` and retired every reference site
   of the `FOODFINDER` variable in `scripts/generate-project.sh` (its declaration, its
   `strip_block FOODFINDER` call inside the app-source-excludes `if`/`else`, and its two `echo`
   lines) in one edit — `bash -n` + a real `./scripts/generate-project.sh` run confirmed no
   unbound-variable abort under `set -euo pipefail`. This branch's copy of both files still has the
   full `FABOLUS_FOODFINDER=${FABOLUS_FOODFINDER:-1}` gate, unconditional-present-by-default,
   exactly as it was pre-removal — a real, working `=0`/`=1` compile toggle if you check this
   branch out and generate.
6. `git rm`'d the 3 now-obsolete FoodFinder test files (they test deleted code, not code that "stays
   green" — `FoodFinderCarbSeamGuardTests.foodFinderVendorDirectoryIsLiveAndNonEmpty` specifically
   REQUIRES the vendor dir to exist and non-emptily so it would FAIL, not pass, post-removal):
   `FoodFinderAIParseTests.swift`, `FoodFinderCarbSeamGuardTests.swift`, `FoodFinderOFFDecodeTests.swift`.
   This branch's copies of all 3 are untouched.
7. Authored a new `FoodFinderAbsenceGuardTests.swift` on `main` (source-scans for the absence of the
   3 directories and the `showFoodFinder`/`FoodFinderView` seam) — this branch has no such file
   (it predates the removal); do not port it over on reintegration, it asserts the opposite of what
   this branch's tree looks like.
8. Registered `"foodfinder"`, `"find food"`, and `"barcode"` in
   `ios/faBolusAppTests/SettingsCatalogTests.swift`'s `CompileGateAudit.gatedOffSearchTokens` (§6c
   no-dangling-refs audit) — this branch's copy of that file predates the addition.

## Reintegration path

1. Cherry-pick (or manually re-apply) the 3 FoodFinder directories back onto the target tree from
   this branch's tip.
2. Restore the `BolusEntryView.swift` carb-seam: the `showFoodFinder` state var, the "Find food"
   entry-point button, and the `.sheet` modifier presenting `FoodFinderView` — re-derive the exact
   insertion point against the target's current `BolusEntryView.swift` rather than pasting back
   verbatim, since the surrounding code may have moved on (Phase 4's CIQ-readout removal already
   touched this same file once).
3. Restore the 4 `AppSettings.swift` FoodFinder-AI members (`foodFinderAIEnabled`,
   `foodFinderAINoticeAckAt`, `hasAcknowledgedFoodFinderAINotice`, `acknowledgeFoodFinderAINotice`)
   + their 2 `init`-restore lines. No catalog/backup change needed — they were never registered.
4. Restore the FULL `NSCameraUsageDescription` string (this branch's copy has it verbatim) in
   `project.yml`'s `info.properties` — but re-check whether the peer-remote QR-pairing clause is
   STILL live on the target at reintegration time; if Phase 3/REMOTE-02 has since removed the QR
   scanner too, the restored string should drop the QR clause instead of blindly pasting both back.
5. Restore the `FABOLUS_FOODFINDER` compile gate: re-add the `# >>> FOODFINDER … # <<< FOODFINDER`
   fence to `project.yml` (this branch's copy has the exact original text) and re-add the
   `FOODFINDER="${FABOLUS_FOODFINDER:-1}"` declaration + its `strip_block FOODFINDER` call + its 2
   `echo` lines to `scripts/generate-project.sh` (same shape as this branch's copy). Run a real
   `./scripts/generate-project.sh` at both `FABOLUS_FOODFINDER=1` and `=0` to re-prove the toggle
   before declaring reintegration complete.
6. Restore or re-derive the 3 test files (`FoodFinderAIParseTests.swift`,
   `FoodFinderCarbSeamGuardTests.swift`, `FoodFinderOFFDecodeTests.swift`) — re-derive against the
   target's current fixtures rather than pasting back verbatim if other phases have since changed
   shared test helpers. Remove or re-scope `main`'s `FoodFinderAbsenceGuardTests.swift` — it is
   written to assert ABSENCE; a full reintegration would make its assertions fail by design, which
   is the correct signal that the boundary test itself must be retired/rewritten as part of undoing
   this removal, not silently left red.
7. Reconcile `CompileGateAudit.gatedOffSearchTokens` — remove `"foodfinder"`, `"find food"`,
   `"barcode"` from the gated-off set once the row/seam they described is live again, or the §6c
   orphan audit will (correctly) start flagging live FoodFinder UI as a dangling reference to a
   "removed" feature that no longer is one.
8. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`). This branch's removal never touched
   `Packages/faBolusCore`, `ios/faBolus/Data/AppModel.swift`, or
   `ios/faBolus/Data/TandemBackend.swift` — `check-dose-byte-identity.sh` should need no reconciling
   step; FoodFinder was a NO-dose-set-stub, clean-delete surface throughout (D-03).
