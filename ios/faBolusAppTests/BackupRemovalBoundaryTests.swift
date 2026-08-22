import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// **D-08 boundary test (Phase 6, 06-03).** Proves BOTH halves of the owner-adopted carve-out in one
/// UNGATED suite (NOT wrapped in `#if FABOLUS_BACKUP`) that runs as a permanent regression guard on
/// every narrow-`main` build:
///
/// (1) ABSENCE (A5) — the backup/restore/export/iCloud-sync/SiteAtlas engine is gone from narrow
///     `main`. The 9 app-layer files git rm'd in 06-02 (`SettingsBackup.swift`, `PrivacyDataExport.swift`,
///     `BackupRestoreView.swift`, `ICloudSync.swift`, `SiteAtlasStore.swift`, the 3 SiteAtlas view files,
///     the vendored `SiteAtlas_Models.swift`) declare types this file — UNGATED — could not even name
///     without a compile error, so their absence from the compiled target is a structural fact this
///     file's own successful compilation already proves; `removedBackupFilesAreAbsentFromWorkingTree`
///     below adds an independent source-level check (mirrors
///     `NudgeDeliveryBoundaryTests.nudgeSourceContainsNoDeliverySeamSymbols`'s file-scan idiom) that a
///     future re-add would be caught even before a fresh `xcodegen` regenerates the project. The handful
///     of `AppModel.swift` members kept (not deleted) under `#if FABOLUS_BACKUP` — `siteAtlasBackup`,
///     `restoreSiteAtlas`, `trackersBackup`/`restoreTrackers`, `buildPrivacyExport`/
///     `exportPrivacyDataJSON` — are pinned OFF by `backupSurfaceIsCompiledOutByDefault`.
///
/// (2) ERASE-STAYS-REACHABLE (D-08 §4) — `AppModel.eraseAllOnDeviceHealthData()` and
///     `eraseEverythingFullReset()` remain callable on narrow `main` and return the expected `.erased`
///     outcome. This is a coarse CAPABILITY smoke-check, complementary to (not redundant with) the 4
///     detailed behavior tests in `PrivacyDataTests.swift` — this suite proves the capability survived
///     the `FABOLUS_BACKUP=0` compile-gate flip end-to-end; `PrivacyDataTests` proves its detailed
///     refuse/wipe/unpair semantics.
///
/// Two non-interference checks (A5) exercise still-present code that sits immediately beside the
/// removed/guarded members: `AppModel.deliveryGloballyBlocked` (the exact signal the erase gate itself
/// consults) and `CredentialStore.cgmSecretAccounts` (the D-08 relocation target for
/// `eraseEverythingFullReset()`'s one dependency on backup-adjacent code, at `AppModel.swift:1327`).
///
/// Do NOT copy `NudgeDeliveryBoundaryTests`' "an estimate never reaches the signed delivery seam"
/// framing here — backup was never on the dose path (A5); that assertion would test nothing real.
@MainActor
@Suite(.serialized) struct BackupRemovalBoundaryTests {

    // MARK: - ABSENCE (A5): the compile gate itself defaults OFF

    /// Structural pin: if a future edit ever flips `generate-project.sh`'s `FABOLUS_BACKUP` default back
    /// to 1 (or an explicit env override forces it on), this test — UNGATED, so it always compiles and
    /// runs regardless of the flag's state — fails LOUDLY rather than silently letting the backup engine
    /// reappear on narrow `main`. The body is empty (and the test passes trivially) at the correct
    /// `FABOLUS_BACKUP=0` default; the `Issue.record` call only enters the compiled program at all when
    /// the flag is on, which is itself the failure being reported.
    @Test func backupSurfaceIsCompiledOutByDefault() {
#if FABOLUS_BACKUP
        Issue.record("FABOLUS_BACKUP is compiled IN on this build — narrow main's default must be 0 (D-08)")
#endif
    }

    /// Independent, source-level proof: the 9 git-rm'd backup/restore/SiteAtlas app-layer files
    /// (06-02) are absent from the working tree this test binary was built from — not merely gated.
    /// Their full, still-compiling copies are preserved on `dev/backup`.
    @Test func removedBackupFilesAreAbsentFromWorkingTree() {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()   // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()   // → .../ios
            .deletingLastPathComponent()   // → repo root
        let removedRelativePaths = [
            "ios/faBolus/Data/SettingsBackup.swift",
            "ios/faBolus/Data/PrivacyDataExport.swift",
            "ios/faBolus/Views/BackupRestoreView.swift",
            "ios/faBolus/Data/ICloudSync.swift",
            "ios/faBolus/Data/SiteAtlasStore.swift",
            "ios/faBolus/Views/SiteAtlas/SiteAtlasBodyMapView.swift",
            "ios/faBolus/Views/SiteAtlas/SiteAtlasLogEntrySheet.swift",
            "ios/faBolus/Views/SiteAtlas/SiteAtlasRootView.swift",
            "ios/faBolus/Vendor/LoopPowerPack/SiteAtlas/SiteAtlas_Models.swift",
        ]
        for relative in removedRelativePaths {
            let url = repoRoot.appendingPathComponent(relative)
            #expect(!FileManager.default.fileExists(atPath: url.path),
                     "\(relative) must be absent from narrow main (git rm'd in 06-02, preserved on dev/backup)")
        }
    }

    // MARK: - NON-INTERFERENCE (A5): still-present paths beside the removed/guarded members keep working

    /// `deliveryGloballyBlocked` is the exact signal `eraseAllOnDeviceHealthData`/
    /// `eraseEverythingFullReset` consult before wiping anything — proving it still reads correctly on a
    /// fresh model shows the erase gate's own dependency survived the removal untouched.
    @Test func deliveryGloballyBlockedStaysReachableOnAFreshModel() {
        let model = AppModel(source: MockBackend())
        #expect(!model.deliveryGloballyBlocked)
    }

    /// `CredentialStore.cgmSecretAccounts` is the D-08 relocation target for
    /// `eraseEverythingFullReset()`'s one dependency on backup-adjacent code (`AppModel.swift:1327`) —
    /// moved out of the now-gated `SettingsBackup.swift` into the always-present `CredentialStore.swift`
    /// so the erase path never depends on a `#if FABOLUS_BACKUP`-guarded type. Proving it is non-empty
    /// and reachable here is the non-interference check for that relocation.
    @Test func credentialStoreCgmSecretAccountsRelocationStaysReachable() {
        #expect(!CredentialStore.cgmSecretAccounts.isEmpty)
        #expect(CredentialStore.cgmSecretAccounts.contains("dexcomshare.password"))
    }

    // MARK: - ERASE-STAYS-REACHABLE (D-08 §4): capability smoke-check

    /// Coarse capability proof: `eraseAllOnDeviceHealthData()` is still callable on narrow `main` at the
    /// new `FABOLUS_BACKUP=0` default and still returns `.erased` with no unresolved delivery. Detailed
    /// refuse/wipe semantics are proven by `PrivacyDataTests.eraseSucceedsWipesHealthDataAndKeepsKeychainAndPairing`.
    @Test func eraseAllOnDeviceHealthDataStaysReachableAndReturnsErased() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backup-removal-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(source: MockBackend(), ledgerStoreURL: dir.appendingPathComponent("ledger.json"))
        #expect(!model.deliveryGloballyBlocked)
        #expect(model.eraseAllOnDeviceHealthData() == .erased)
    }

    /// Coarse capability proof: `eraseEverythingFullReset()` is still callable on narrow `main` at the
    /// new `FABOLUS_BACKUP=0` default and still returns `.erased` — this is the path that also exercises
    /// `CredentialStore.cgmSecretAccounts` end-to-end (via `AppModel.swift:1327`). Detailed wipe/unpair
    /// semantics are proven by `PrivacyDataTests.fullResetWipesHealthDataAndUnpairs`.
    @Test func eraseEverythingFullResetStaysReachableAndReturnsErased() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backup-removal-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(source: MockBackend(), ledgerStoreURL: dir.appendingPathComponent("ledger.json"))
        #expect(!model.deliveryGloballyBlocked)
        #expect(model.eraseEverythingFullReset() == .erased)
    }
}
