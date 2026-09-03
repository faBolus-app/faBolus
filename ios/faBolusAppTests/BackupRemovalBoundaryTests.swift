import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins that the backup/restore/iCloud/SiteAtlas engine stays compiled out on narrow `main`
/// (`FABOLUS_BACKUP` default 0) and that `eraseAllOnDeviceHealthData` / `eraseEverythingFullReset`
/// remain callable. Detailed wipe/unpair semantics live in `PrivacyDataTests`.
@MainActor
@Suite(.serialized) struct BackupRemovalBoundaryTests {

    // MARK: - ABSENCE: the compile gate itself defaults OFF

    /// Fails if this build compiled `FABOLUS_BACKUP` on. The body is empty at the correct default.
    @Test func backupSurfaceIsCompiledOutByDefault() {
        #if FABOLUS_BACKUP
        Issue.record("FABOLUS_BACKUP is compiled IN on this build — narrow main's default must be 0")
        #endif
    }

    // MARK: - NON-INTERFERENCE: still-present paths beside the gated members keep working

    /// `deliveryGloballyBlocked` is the signal erase consults before wiping anything.
    @Test func deliveryGloballyBlockedStaysReachableOnAFreshModel() {
        let model = AppModel(source: MockBackend())
        #expect(!model.deliveryGloballyBlocked)
    }

    /// `CredentialStore.cgmSecretAccounts` must stay on the always-present store so erase never
    /// depends on a `#if FABOLUS_BACKUP`-guarded type.
    @Test func credentialStoreCgmSecretAccountsRelocationStaysReachable() {
        #expect(!CredentialStore.cgmSecretAccounts.isEmpty)
        #expect(CredentialStore.cgmSecretAccounts.contains("dexcomshare.password"))
        #expect(CredentialStore.cgmSecretAccounts.contains("nightscout.token"))
        #expect(CredentialStore.cgmSecretAccounts.contains("nightscout.apisecret"))
        #expect(CredentialStore.cgmSecretAccounts.contains("librelinkup.password"))
    }

    // MARK: - ERASE STAYS REACHABLE

    /// `eraseAllOnDeviceHealthData()` stays callable on narrow `main` and returns `.erased`.
    @Test func eraseAllOnDeviceHealthDataStaysReachableAndReturnsErased() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backup-removal-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(source: MockBackend(), ledgerStoreURL: dir.appendingPathComponent("ledger.json"))
        #expect(!model.deliveryGloballyBlocked)
        #expect(model.eraseAllOnDeviceHealthData() == .erased)
    }

    /// `eraseEverythingFullReset()` stays callable and returns `.erased` (also exercises
    /// `CredentialStore.cgmSecretAccounts`).
    @Test func eraseEverythingFullResetStaysReachableAndReturnsErased() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backup-removal-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(source: MockBackend(), ledgerStoreURL: dir.appendingPathComponent("ledger.json"))
        #expect(!model.deliveryGloballyBlocked)
        #expect(model.eraseEverythingFullReset() == .erased)
    }
}
