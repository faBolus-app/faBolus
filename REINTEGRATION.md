# REINTEGRATION.md — dev/mac

## What it is

The Mac menu-bar remote (Phase 3, REMOTE-01): the `faBolusMac`/`faBolusMacWidgets` Xcode targets
(`mac/faBolusMac/**`, `mac/faBolusMacWidgets/**` — 25 files: app sources, widget bundle, entitlements,
Info.plist, asset catalogs), plus the `project.yml` fenced target block that declared both targets and
the `FABOLUS_MAC`/`strip_block MAC` gate machinery in `scripts/generate-project.sh` that used to strip
them at `=0`. It never touched the pump directly: it displayed the status the phone relayed over BLE
and sent bolus/cancel/dismiss commands the phone executed.

**Not preserved here (still live on `main`):** the shared BLE-peer receiver
(`ios/faBolus/Data/MacRemoteAuthStore.swift`, `PeerRemoteHost.swift`, `MacPairingCoordinator.swift`)
that served BOTH the Mac client and the phone-peer surface — it is deliberately left untouched by
Phase 3's Mac-removal plan (03-01) because phone-peer (03-02) still needs it live; 03-02 does that
shared-receiver teardown + introduces stubs. Also not preserved here: the Mac/peer "Remote access"
Settings UI (`SettingsView.swift`/`SettingsCatalog.swift`), which is shared with phone-peer and removed
in 03-02.

## State at removal

Phase 3 Plan 01 (03-01) executed the removal in two commits on `main`:

1. **Gate retirement** — deleted the entire `# >>> MAC ... # <<< MAC` fenced target block from
   `project.yml` (both target defs, one edit), and in `scripts/generate-project.sh` retired the
   `FABOLUS_MAC` gate var, the `if [ "$MAC" = 0 ]; then strip_block MAC; fi` conditional, the
   `Mac=$MAC` combined-summary echo field, and the standalone Mac diagnostic echo — no dangling `$MAC`
   reference remains under `set -euo pipefail`.
2. **Tree deletion** — `git rm -r`'d `mac/faBolusMac/` and `mac/faBolusMacWidgets/` from `main`
   outright (delete-on-main, not an `APP_SOURCE_EXCLUDES` entry — the gate was already retired in
   step 1, so there is nothing left to gate). Both trees are preserved here on `dev/mac`, byte-identical
   to their state at removal.

A real `./scripts/generate-project.sh` + `xcodebuild build` + `./scripts/check-dose-byte-identity.sh`
all passed green after both steps — the dose/signed core (`Packages/faBolusCore`, `AppModel.swift`,
`TandemBackend.swift`) was never touched.

**Stale-Keychain orphan note (03-RESEARCH.md "Runtime State Inventory"):** `MacRemoteAuthStore`'s
Keychain tokens (`service: "com.fabolus.app.macremote"`) and its `macRemotePairedNames` UserDefaults
index are device-local, per-device-that-ever-paired-a-Mac state that is NOT touched by this removal
(the store itself is still live code on `main`, serving phone-peer — see "Not preserved here" above).
If/when the shared receiver is eventually torn down (03-02) or reintegrated here, any surviving
`com.fabolus.app.macremote` Keychain entries on a device must be treated as **stale, harmless orphans**:
they are never synced off-device and nothing reads them again once no client can present a matching
token. An uninstall/reinstall of the app clears them; an in-place upgrade does not.

## How to reintegrate

1. **Gate to re-add** — restore the `FABOLUS_MAC` gate var (`MAC="${FABOLUS_MAC:-1}"`) and its comment
   block in `scripts/generate-project.sh`, restore the `if [ "$MAC" = 0 ]; then strip_block MAC; fi`
   conditional, and restore the `Mac=$MAC`/standalone diagnostic echo lines — this branch's copy of
   `scripts/generate-project.sh` (pre-removal) is the reference shape.
2. **Tree to restore** — copy `mac/faBolusMac/` and `mac/faBolusMacWidgets/` back onto `main` from this
   branch (`git checkout dev/mac -- mac/faBolusMac mac/faBolusMacWidgets` or an equivalent cherry-pick),
   and restore the `# >>> MAC ... # <<< MAC` fenced target block in `project.yml` (this branch's copy is
   the reference shape — both target defs, unchanged since removal).
3. **Tests to restore** — no dedicated Mac-target test suite existed at removal time (none of
   `SettingsView.swift`/`SettingsCatalog.swift`/`SettingsCatalogTests.swift` were touched by 03-01 — see
   "Not preserved here"); re-verify against whatever the shared-receiver/Settings-UI surface looks like
   at reintegration time, since 03-02 (and possibly later plans) will have changed it in the meantime.
4. **Keychain/UserDefaults** — treat any surviving `com.fabolus.app.macremote` Keychain entries and
   `macRemotePairedNames` UserDefaults index as stale (see note above); no migration is needed, but do
   not assume a paired-name list found on a device reflects a currently-valid pairing.
5. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`): tag currency, dose/signed byte-identity,
   green main + full safety suite, schema drift, no-dangling-refs.
