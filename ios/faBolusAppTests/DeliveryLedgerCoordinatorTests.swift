import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// The three unresolved-dose states that used to stay blocked SILENTLY now each disclose an app-own
/// notification the moment the state engages: the `.unavailable` reconcile arm, the sent-but-no-id
/// arm, and the unreadable-ledger path. A genuinely-empty-but-readable ledger still says nothing. The
/// block is unchanged on every genuinely-unresolved state — reconciliation, not this notification, is the
/// dose interlock.
@Suite(.serialized) @MainActor
struct DeliveryLedgerCoordinatorTests {

    /// A durable store preloaded with a fixed ledger, so an unresolved state is seeded directly (no
    /// delivery path, no gating dependency). Mirrors `SafetyNotificationTests.SeedLedgerStore`.
    final class SeedLedgerStore: RemoteBolusLedgerPersisting, @unchecked Sendable {
        private var persisted: Data?
        init(seed: RemoteBolusLedger) { persisted = try? JSONEncoder().encode(seed) }
        func loadOutcome() -> RemoteBolusLedgerStore.LoadOutcome {
            if let persisted, let l = try? JSONDecoder().decode(RemoteBolusLedger.self, from: persisted) {
                return .init(ledger: l, failedClosed: false)
            }
            return .init(ledger: RemoteBolusLedger(), failedClosed: false)
        }
        func save(_ ledger: RemoteBolusLedger) throws { persisted = try JSONEncoder().encode(ledger) }
        func saveBestEffort(_ ledger: RemoteBolusLedger) { try? save(ledger) }
    }

    private func withCleanSettings(_ body: () async throws -> Void) async rethrows {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled
        s.phoneReadOnly = false
        s.childModeEnabled = false
        defer {
            s.phoneReadOnly = ro
            s.childModeEnabled = child
        }
        try await body()
    }

    private func tempLedgerURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("29-05-ledger-\(UUID().uuidString).json")
    }

    // MARK: - The `.unavailable` reconcile arm (id-bearing, pump can't confirm it)

    /// An id-bearing entry the pump cannot resolve (`reconcile(bolusId:)` → `.unavailable`) must disclose a
    /// durable `.bolusIndeterminate` keyed on the reconcile family — and stay blocked. Before this the arm
    /// only recorded telemetry and stayed blocked with no notification at all.
    @Test func unavailableArmPostsADurableUnknownOutcomeNotificationAndKeepsTheBlockOn() async {
        await withCleanSettings {
            let backend = MockBackend()
            await backend.connect()
            backend.forceIndeterminateNextDelivery = true  // no reconcileResultsById ⇒ reconcile → .unavailable
            let model = AppModel(source: backend, ledgerStoreURL: tempLedgerURL())
            await model.remoteDeliver(requestId: "unavail-1", units: 1.0, peerId: "watch")
            #expect(model.deliveryGloballyBlocked)  // an id-bearing indeterminate entry blocks

            // Capture ONLY the reconcile-pass post (the send-time indeterminate-* post already happened).
            var posted: [NotificationBroker.Message] = []
            model.notificationSink = { msg, _, _ in posted.append(msg) }
            await model.reconcileUnresolvedDeliveries()

            let disclosures = posted.filter {
                $0.category == .bolusIndeterminate
                    && RemoteBolusLedger.isReconciliationDedupeKey($0.dedupeKey)
            }
            #expect(disclosures.count >= 1, "the .unavailable arm must disclose the unknown outcome")
            #expect(disclosures.first?.dedupeKey == "reconcile-watch-unavail-1")
            #expect(model.deliveryGloballyBlocked, "a genuinely-unresolved state stays blocked")
        }
    }

    // MARK: - The sent-but-no-id arm (sentToPump == true, no bolusId)

    /// A ledger entry that is `sentToPump == true` yet carries no `bolusId` (the rare interrupted-mid-commit
    /// record) must ALSO disclose rather than `continue` silently, keyed on the reconcile family, and stay
    /// blocked. Seeded via a hand-crafted ledger blob because no public mutator produces that exact phase.
    @Test func sentButNoIdArmPostsADurableUnknownOutcomeNotificationAndKeepsTheBlockOn() async {
        await withCleanSettings {
            // `key(peerId, requestId)` joins the two with U+001F; JSON-escape it so the decoded dict key
            // matches the ledger's own composite key exactly.
            let json =
                "{\"entries\":{\"watch\\u001fnoid-1\":"
                + "{\"doseKey\":\"u:1.0000|c:-|bg:-\",\"state\":\"delivering\",\"sentToPump\":true}},"
                + "\"order\":[\"watch\\u001fnoid-1\"],\"cap\":256}"
            let seed = try! JSONDecoder().decode(RemoteBolusLedger.self, from: Data(json.utf8))
            // Sanity: the seed is a sent-but-no-id unresolved entry.
            let u = seed.unreconciled()
            #expect(u.count == 1 && u.first?.sentToPump == true && u.first?.bolusId == nil)

            let backend = MockBackend()
            await backend.connect()
            let model = AppModel(source: backend, ledgerStore: SeedLedgerStore(seed: seed))
            var posted: [NotificationBroker.Message] = []
            model.notificationSink = { msg, _, _ in posted.append(msg) }

            await model.reconcileUnresolvedDeliveries()

            let disclosures = posted.filter {
                $0.category == .bolusIndeterminate
                    && RemoteBolusLedger.isReconciliationDedupeKey($0.dedupeKey)
            }
            #expect(disclosures.count >= 1, "the sent-but-no-id arm must disclose the unknown outcome")
            #expect(disclosures.first?.dedupeKey == "reconcile-watch-noid-1")
            #expect(model.deliveryGloballyBlocked, "the sent-but-no-id entry stays blocked")
        }
    }

    // MARK: - The unreadable-ledger path (fail-closed, no entry)

    /// An unreadable/corrupt ledger (no entry, so no peerId/requestId) must disclose the unknown outcome
    /// under the FIXED family key — distinguished from a genuinely-empty-but-readable ledger via
    /// `ledgerFailedClosed` — and stay blocked.
    @Test func unreadableLedgerPathPostsAFixedKeyUnknownOutcomeNotificationAndStaysBlocked() async {
        await withCleanSettings {
            let store = R3CLedgerFaultTests.FakeLedgerStore()
            store.reportCorruptLoad = true
            let backend = MockBackend()
            await backend.connect()
            let model = AppModel(source: backend, ledgerStore: store)
            var posted: [NotificationBroker.Message] = []
            model.notificationSink = { msg, _, _ in posted.append(msg) }

            await model.reconcileUnresolvedDeliveries()

            let disclosures = posted.filter { $0.category == .bolusIndeterminate }
            #expect(
                disclosures.contains { $0.dedupeKey == RemoteBolusLedger.unreadableLedgerReconciliationDedupeKey },
                "the unreadable-ledger path must disclose under the fixed family key")
            #expect(model.deliveryGloballyBlocked, "an unreadable ledger stays fail-closed blocked")
        }
    }

    // MARK: - A genuinely-empty-but-readable ledger stays silent

    /// A readable ledger with nothing unresolved posts NOTHING — the disclosure is scoped to genuine
    /// unresolved states, never a clean launch.
    @Test func aReadableButEmptyLedgerPostsNoUnknownOutcomeNotification() async {
        await withCleanSettings {
            let backend = MockBackend()
            await backend.connect()
            let model = AppModel(source: backend, ledgerStoreURL: tempLedgerURL())
            var posted: [NotificationBroker.Message] = []
            model.notificationSink = { msg, _, _ in posted.append(msg) }

            await model.reconcileUnresolvedDeliveries()

            #expect(
                posted.allSatisfy { $0.category != .bolusIndeterminate },
                "a clean, readable ledger must never disclose an unresolved-dose notification")
            #expect(!model.deliveryGloballyBlocked)
        }
    }
}
