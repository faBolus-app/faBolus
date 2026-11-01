import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins that the backup/restore/iCloud/SiteAtlas engine stays gone from narrow `main` (the
/// `FABOLUS_BACKUP` compile-condition token is deleted outright, not merely defaulted off) and that
/// `eraseAllOnDeviceHealthData` / `eraseEverythingFullReset` remain callable. Detailed wipe/unpair
/// semantics live in `PrivacyDataTests`.
@MainActor
@Suite(.serialized) struct BackupRemovalBoundaryTests {

    // MARK: - ABSENCE: the compile-condition token itself is gone

    /// Source-level proof that `FABOLUS_BACKUP` no longer appears on any
    /// `SWIFT_ACTIVE_COMPILATION_CONDITIONS` line in `project.yml`. Deleting the token outright (rather
    /// than leaving it declared-but-defaulted) means there is no longer a live `#if FABOLUS_BACKUP`
    /// guard anywhere to fail loudly if the token were ever re-added — this scan is what would catch it.
    @Test func backupTokenIsAbsentFromEveryCompileConditionsLine() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot =
            testFileURL
            .deletingLastPathComponent()  // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()  // → .../ios
            .deletingLastPathComponent()  // → repo root
        let projectYmlURL = repoRoot.appendingPathComponent("project.yml")
        let source = try String(contentsOf: projectYmlURL, encoding: .utf8)
        #expect(source.count > 200, "project.yml resolved implausibly short — path resolution likely broke")

        let compileConditionsLines =
            source
            .components(separatedBy: "\n")
            .filter { $0.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS:") }

        // Non-vacuity: this scan means nothing if it found zero lines to check — a broken path
        // resolution or a renamed key would otherwise let this test pass for the wrong reason.
        #expect(
            !compileConditionsLines.isEmpty,
            "found zero SWIFT_ACTIVE_COMPILATION_CONDITIONS lines in project.yml — the scan target itself is missing"
        )

        for line in compileConditionsLines {
            #expect(
                !line.contains("FABOLUS_BACKUP"),
                "FABOLUS_BACKUP still declared on a SWIFT_ACTIVE_COMPILATION_CONDITIONS line: '\(line)'"
            )
        }
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
