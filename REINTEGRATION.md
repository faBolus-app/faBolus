# REINTEGRATION.md — dev/phone-remote

## What it is

The iPhone-to-iPhone peer remote (Phase 3, REMOTE-02): `PeerRemoteHost.swift`,
`PhoneRemoteClientModel.swift`, `MacRemoteAuthStore.swift`, `Views/RemoteControlView.swift`,
`Views/RemoteRootView.swift`, `Views/RemoteSettingsView.swift`, `Views/QRScannerView.swift` (orphaned
once `RemoteControlView.swift` was gone — its only caller), `Views/MacPairingView.swift` (+ its
embedded `RemotePeerPermissionsView`), and `Shared/AuthenticatingRemoteClientModel.swift`. Also removed
here: the shared "Remote access"/"Remotes" Settings UI (`SettingsView.swift`), the `remoteBluetoothEnabled`
`AppSettings` accessor + `SettingsCatalog` row, and the `[Remote role]` DebugMenu diagnostics section
that read `MacPairingCoordinator`.

**Not preserved here (still live on `main`, changed shape):**
- `Shared/RemoteClientModel.swift` — NOT deleted. It was **moved** to
  `watch/faBolusWatch/RemoteClientModel.swift` (git-mv, not git-rm) because `WatchModel: RemoteClientModel`
  (in the still-live-by-default Watch app target) subclasses it directly, and the Watch target hadn't
  been removed yet when this plan (03-02) landed. It will end up preserved on `dev/watch-remote`, not
  here, when 03-03 removes the whole `watch/faBolusWatch` tree.
- `ios/faBolus/Data/PhoneRemoteHost.swift`, `GarminRemoteBridge.swift`, `RemoteClientAuthStore.swift`,
  `RemoteRoleDiagnostics.swift` — the shared receiver core + kept diagnostics, deliberately untouched
  (D-04 STAY list) as of this branch's own tip. ⚠ **`RemoteClientAuthStore.swift` is stale in THIS
  bullet as of a later `main` removal — see "Update" below; the other three are unaffected.**
- `ios/faBolus/Data/RemotePeerPolicyStore.swift`, `MacPairingCoordinator.swift` — NOT deleted, REPLACED
  with minimal deny-by-default stubs (see "Stubs to un-stub" below) so the byte-frozen `AppModel.swift`
  keeps compiling.
- `requireRemoteBolusApproval`'s `AppSettings` accessor — stays (frozen `AppModel.swift:1871` still
  reads it); only its `SettingsCatalog` row + `ChildModeView.swift` UI were removed (hidden-flag).

## Update (a later `main` removal — the transport/handshake/routing layer, no `dev/*` branch of its own)

A subsequent `main` removal deleted the transport/handshake/routing cluster that the phone-peer surface
above rode on. **None of it is preserved on this branch** — this branch's tip only ever carried the
*consumer* code (`PhoneRemoteClientModel.swift` etc., listed in "What it is" above), never the
transport primitives, so there is nothing to restore from `dev/phone-remote` for these; recover them
from `main` history instead, `git show <pre-removal-sha>:<path>` (pre-removal main tip was
`649e6cce56744fdc593bbf077075201140995132`; re-verify the sha is still an ancestor before relying on it,
and re-derive the path by symbol if `main` has since reorganized `ios/faBolus/Data/Remote/` again):

- `Packages/faBolusCore/Sources/faBolusCore/BLELink.swift` — the phone↔Mac/phone↔phone GATT-server
  transport (470 lines; was never constructed on `main`, "DEAD on main" per its own header comment).
- `Packages/faBolusCore/Sources/faBolusCore/SealedTransport.swift` — the AES-GCM sealed-envelope
  `RemoteTransport` decorator (169 lines).
- `Packages/faBolusCore/Sources/faBolusCore/MacPairing.swift` — the HMAC pairing-handshake primitives
  (131 lines), including `newStrongCode()` (the QR-pairing high-entropy code generator).
- `Packages/faBolusCore/Sources/faBolusCore/PeerPairingPayload.swift` — the pairing-QR payload
  encode/decode struct (40 lines).
- `Packages/faBolusCore/Sources/faBolusCore/RemoteTransport.swift`'s `RemoteSendDisposition` enum +
  `decide(...)` (the never-queue-a-pump-mutating-command classifier that predated
  `RemoteCommand.Kind.mutatesPumpState` becoming the live classifier) — **only this enum**; `protocol
  RemoteTransport` and `onUndeliverable` in the same file are UNCHANGED and still live on `main`.
- `ios/faBolus/Data/Remote/RemoteClientAuthStore.swift` — corrects the bullet above: this file is now
  ALSO gone from `main` (a zero-caller orphan by the time of its removal — the phone-peer consumer that
  used it had already been removed here in 03-02). Its Keychain service
  (`com.fabolus.app.remoteclient.auth`) and `phoneRemoteClientId` UserDefaults key were left as stale,
  harmless, unreadable orphans by that removal (same class as the `com.fabolus.app.macremote` note
  below), not purged by it — treat any surviving entries the same way.
- `ios/faBolus/Views/QRCodeView.swift` — the host-side pairing-QR *generator* (32 lines; its scanner
  counterpart, `Views/QRScannerView.swift`, IS preserved above on this branch — the two were never
  reunited on `main` after 03-02 orphaned the generator).
- `ios/faBolus/Data/Remote/AppRouter.swift` — the single-case `enum Target { case thisPump }` routing
  shell (+ its `@State`/`.environment(router)` wiring in `RootContainerView.swift`) that phone-peer's
  `.remote` `Target` case (see "Callers to re-wire" step 3 below) would have extended, had it survived.
  Re-add the `.remote` case to a fresh router type on reintegration; do not expect this one back.

Reintegrating the phone-peer surface from this branch is therefore NOT sufficient by itself once that
later removal has landed — the transport/handshake layer above must be recovered from `main` history
(there is no `dev/*` branch carrying it verbatim) and re-wired underneath `PhoneRemoteClientModel`
before any of this branch's preserved files will compile.

## State at removal

Phase 3 Plan 02 (03-02) executed the removal in three commits on `main`:

1. **Wave 0 — wire-test fixture** (`test(03-02): Wave 0 phone-side RemoteCommand wire fixture...`):
   before touching `RemoteClientModel`, added `ios/faBolusAppTests/Support/RemoteCommandWireFixture.swift`
   — a byte-for-byte verbatim copy of `RemoteClientModel` (renamed, plus the `asSnapshot` adapter that
   lived in the since-deleted `RemoteControlView.swift`) — and re-pointed the ~16 wire tests that
   directly instantiated `RemoteClientModel(link: FakeLink())` to it instead, so they never depended on
   the production type surviving in the app module.
2. **Atomic peer removal** (`feat(03-02): atomic peer removal — deny-by-default stubs + git rm...`):
   the stubs + `git rm`/`git mv` above + every caller edit (`App.swift`, `AppRouter.swift`,
   `RootContainerView.swift`, `SettingsView.swift`, `DebugMenuView.swift`, `ChildModeView.swift`,
   `AppSettings.swift`, `SettingsCatalog.swift`) landed together — `main` would not build split.
3. **Boundary test + test triage + finalize** (`test(03-02): boundary test + AppModelBehaviorTests/...`):
   extended `GarminVenu3sOnlyBoundaryTests` with `.quickBolusWidget` cases; deleted the
   peer-full-control `@Test`s from `AppModelBehaviorTests.swift`/`StaleRemoteDoseHostTests.swift` that
   the minimal stub made unconstructable; registered "Remote access"/"Pair a remote" in
   `SettingsCatalogTests.gatedOffSearchTokens`; finalized `03-OWNER-FLAGS.md` F-1/F-3.

A real `./scripts/generate-project.sh` + `xcodebuild build` + `./scripts/check-dose-byte-identity.sh` +
the full `faBolusAppTests` target all passed green after every commit — the dose/signed core
(`Packages/faBolusCore`, `AppModel.swift`, `TandemBackend.swift`) was never touched.

**Stubs to un-stub (D-02, D-09):**
- `RemotePeerPolicyStore.swift` — the real store (UserDefaults-backed `remotePeerPolicies` +
  `remotePeerHighEntropy` JSON blobs, `setPolicy`/`setPairedViaQR`/`canGrantControl`/`remove`/
  `ensureDefault`) is preserved on this branch at its pre-removal blob — restore it verbatim.
- `MacPairingCoordinator.swift` — the real, `@Observable` coordinator (pairing-window state, QR/6-digit
  code issuance, `MacRemoteAuthStore`-backed `pairedMacs: [PairedMac]`) is preserved on this branch —
  restore it verbatim. Its real `pairedMacs` element type (`PairedMac { id, name }`) differs from the
  stub's `[String]` — any reintegrating caller must reconcile that shape change.

**Wire tests + peer-full-control scenarios to restore:**
- The ~16 wire-test files (`BolusGateHostFeedTests`, `RemoteClientBolusGateTests`, `StaleCarbClientTests`,
  `CiqLockoutBarWireTests`, `CiqHistoryEventWireTests`, `CrossSurfaceStalenessTests`,
  `ControllerDisclosureWireTests`, `CiqZoneWireTests`, `CiqSmartAssistMirrorTests`, `CiqMaxBasalWireTests`,
  `SentAtStampTests`, `CiqSuspendWireTests`, `CiqSleepExerciseWireTests`, `BatteryChargingCarrierTests`,
  `RemoteBolusAuthWireTests`, `RemotePlotBoundsTests`) are on `main` re-pointed to
  `RemoteCommandWireFixture` (test-only, `ios/faBolusAppTests/Support/`). If `RemoteClientModel` is
  reintroduced as a live production type again, these can be re-pointed BACK to it (they're
  behaviorally identical, since the fixture is a verbatim copy) — restoring `RemoteCommandWireFixture`
  itself is optional at that point.
- The deleted peer-full-control `@Test`s (unconstructable through the minimal stub, F-3 accepted
  coverage loss — restore them once the real `RemotePeerPolicyStore`/`MacPairingCoordinator` are back):
  `AppModelBehaviorTests.swift`'s `readOnlyBlocksWidgetButNotRemotePeer`, `parentRemoteBypassesChildLock`,
  `remotesReadOnlyBlocksPeerBolusEndToEnd`, and the `.macPeer`/`.caregiverPhonePeer` branches trimmed
  from `surfaceActionMatrixRoutesThroughTheEvaluator`/`modeGateRoutesThroughAppModelWiring`;
  `StaleRemoteDoseHostTests.swift`'s `macApprovalPreservesIncludeStaleProvenance`. All are preserved at
  their pre-removal blob on this branch's copy of both test files.

**Stale-Keychain orphan note (03-RESEARCH.md "Runtime State Inventory"):** `MacRemoteAuthStore`'s
Keychain tokens (`service: "com.fabolus.app.macremote"`) and its `macRemotePairedNames` UserDefaults
index, plus `RemotePeerPolicyStore`'s `remotePeerPolicies`/`remotePeerHighEntropy` UserDefaults JSON
blobs, are device-local, per-device-that-ever-paired-a-remote state. They become permanently
unread/unwritten once this branch's files are deleted/stubbed on `main` — no live UI can create new
entries. Treat any surviving entries as **stale, harmless orphans**: never synced off-device, never
read again once no client can present a matching token. An uninstall/reinstall clears them; an
in-place upgrade does not.

## How to reintegrate

1. **Files to restore** — copy every file this branch preserves (see "What it is") back onto `main`
   from this branch's tip (`git checkout dev/phone-remote -- <path>` per file, or an equivalent
   cherry-pick) — this REPLACES the two stub files with their real, preserved implementations.
2. **Gate to re-add** — restore the `PHONE_PEER`/`PHONE_PEER_KEEP` fenced blocks in `project.yml` and
   the `PHONE_PEER` gate var + tri-condition strip + summary/standalone echoes in
   `scripts/generate-project.sh` (this branch's pre-removal copies are the reference shape) — OR skip
   the gate entirely and ship the surface unconditionally, since narrow `main`'s posture by this point
   may prefer delete-on-main over compile-gating (check the milestone's current stance first).
3. **Callers to re-wire** — `App.swift` (`peerHost`/`syncPeerHost`), `AppRouter.swift` (the `.remote`
   `Target` case + `remote`/`controlRemote`), `RootContainerView.swift` (the `.remote` switch case),
   `SettingsView.swift` (the "Remote access"/"Remotes" sections + `ControllingSection()` call),
   `DebugMenuView.swift` (the `[Remote role]` section), `ChildModeView.swift` (un-hide the toggle if
   F-1's disposition is revisited), `AppSettings.swift`/`SettingsCatalog.swift`
   (`remoteBluetoothEnabled` + `requireRemoteBolusApproval`'s row/backup participation).
4. **`Shared/RemoteClientModel.swift`** — this branch's copy lives at the OLD `Shared/` path (pre-move);
   `main`'s current copy lives at `watch/faBolusWatch/RemoteClientModel.swift` (moved in 03-02, may have
   moved again if 03-03 has since git rm'd the whole Watch tree to `dev/watch-remote`). Reconcile by
   diffing `main`'s CURRENT copy (wherever it lives) against this branch's preserved copy — they should
   be byte-identical at the 03-02 boundary; if 03-03 has landed since, check `dev/watch-remote` instead.
   Move it back to `Shared/` if the peer client target needs it there again.
5. **Tests to restore** — see "Wire tests + peer-full-control scenarios to restore" above.
6. **Keychain/UserDefaults** — treat any surviving entries as stale (see note above); no migration
   needed, but do not assume a paired-name list found on a device reflects a currently-valid pairing.
7. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`): tag currency, dose/signed byte-identity,
   green main + full safety suite, schema drift, no-dangling-refs — re-verify the Garmin/widget
   boundary test (`GarminVenu3sOnlyBoundaryTests`) still passes against the real (un-stubbed) stores.
