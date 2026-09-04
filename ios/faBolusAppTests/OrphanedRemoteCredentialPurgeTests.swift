import Testing
import Foundation
@testable import faBolus

/// `AppModel.purgeOrphanedRemoteCredentialsIfNeeded()` is the mandatory one-shot launch purge of the
/// Keychain services + `UserDefaults` keys orphaned by the deleted peer/Mac remote transport
/// (`RemoteClientAuthStore`, `MacRemoteAuthStore`, `AppRouter`). The real Keychain is non-functional
/// under the xctest host (no keychain-sharing entitlement — `PairingStore.swift` documents the same
/// limit for `SecItemAdd`), so these tests assert the purge's TARGET SET and its idempotence via the
/// `orphanedRemotePurgeSpyForTests` seam, never real stored Keychain contents.
@MainActor
struct OrphanedRemoteCredentialPurgeTests {

    private func freshSuiteName() -> String { "OrphanedRemoteCredentialPurgeTests.\(UUID().uuidString)" }

    /// The purge targets exactly the two named Keychain services and the three named `UserDefaults`
    /// keys, and nothing else.
    @Test func purgeTargetsExactlyTheNamedServicesAndKeys() {
        let suiteName = freshSuiteName()
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AppModel.orphanedRemotePurgeSpyForTests = nil

        AppModel.purgeOrphanedRemoteCredentialsIfNeeded(defaults: defaults)

        let spy = AppModel.orphanedRemotePurgeSpyForTests
        #expect(spy?.services.sorted() == ["com.fabolus.app.macremote", "com.fabolus.app.remoteclient.auth"])
        #expect(spy?.defaultsKeys.sorted() == ["appTarget", "macRemotePairedNames", "phoneRemoteClientId"])
    }

    /// A second launch is a no-op: once the done-key is set, a second call performs no further
    /// `SecItemDelete` (observed via the spy staying at a sentinel instead of being overwritten).
    @Test func secondCallIsANoOpOnceTheDoneKeyIsSet() {
        let suiteName = freshSuiteName()
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AppModel.orphanedRemotePurgeSpyForTests = nil

        AppModel.purgeOrphanedRemoteCredentialsIfNeeded(defaults: defaults)
        #expect(AppModel.orphanedRemotePurgeSpyForTests != nil, "precondition: the first call ran the purge")
        #expect(defaults.bool(forKey: AppModel.orphanedRemoteCredentialPurgeDoneKey), "precondition: done-key set")

        // Poison the spy with a sentinel the real purge would never produce, so a second run
        // overwriting it (instead of returning early) is unambiguously detectable.
        let sentinel: (services: [String], defaultsKeys: [String]) = (["sentinel"], ["sentinel"])
        AppModel.orphanedRemotePurgeSpyForTests = sentinel

        AppModel.purgeOrphanedRemoteCredentialsIfNeeded(defaults: defaults)

        #expect(
            AppModel.orphanedRemotePurgeSpyForTests?.services == ["sentinel"],
            "a second call must not re-run the purge once the done-key is set")
    }

    /// Removing the three orphaned defaults keys must not remove any OTHER key already in the suite.
    @Test func purgeDoesNotTouchUnrelatedDefaultsKeys() {
        let suiteName = freshSuiteName()
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("keepMe", forKey: "unrelatedKey")

        AppModel.purgeOrphanedRemoteCredentialsIfNeeded(defaults: defaults)

        #expect(defaults.string(forKey: "unrelatedKey") == "keepMe")
        #expect(defaults.object(forKey: "phoneRemoteClientId") == nil)
        #expect(defaults.object(forKey: "macRemotePairedNames") == nil)
        #expect(defaults.object(forKey: "appTarget") == nil)
    }
}
