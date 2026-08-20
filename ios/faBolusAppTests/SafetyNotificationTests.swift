import Testing
import Foundation
import faBolusCore
import TandemMessages
@testable import faBolus

/// P9 step 4 — the three never-suppressible §6 safety notifications synthesized from their detection
/// points. Two are condition-tracking (pump-link loss, CGM-data loss) and use `SafetyEdge`; one is the
/// authoritative bolus-reconciliation result, posted when `reconcileUnresolvedDeliveries` settles an
/// entry (today that outcome reaches the user through nothing). Pins the edge semantics — **notify once
/// on the transition, withdraw on recovery, never fire at startup** — and that a reconciled
/// not-delivered outcome posts exactly one `.bolusReconciliation` with the right key.
@MainActor
@Suite(.serialized) struct SafetyNotificationTests {

    // MARK: Edge detection (pure)

    @Test func connectionEdgeRaisesOnDropClearsOnRecoveryNeverAtStartup() {
        // A cold launch that starts down is NOT a "drop" (no prior live link).
        #expect(SafetyEdge.connection(prev: nil, now: .disconnected) == .none)
        // A live link → down raises.
        #expect(SafetyEdge.connection(prev: .connected, now: .disconnected) == .raise)
        #expect(SafetyEdge.connection(prev: .bolusing, now: .error) == .raise)
        // Steady states don't re-fire.
        #expect(SafetyEdge.connection(prev: .connected, now: .connected) == .none)
        #expect(SafetyEdge.connection(prev: .disconnected, now: .disconnected) == .none)
        // Recovery clears the banner.
        #expect(SafetyEdge.connection(prev: .disconnected, now: .connected) == .clear)
    }

    /// debug pump-background-disconnect (CRITERION 1). The kit now recovers an unintended drop silently in
    /// the background: a genuine drop is surfaced as `.connected → .connecting` (never a `.disconnected`
    /// flicker) and reconnects without alarming. The `.pumpDisconnect` banner + escalation must therefore
    /// fire ONLY at the ladder's terminal give-up (`.error` / `.reconnectExhausted`), reached FROM the
    /// transient `.connecting` state — not on the momentary drop itself — while a live→plain-disconnect
    /// (hard / powered-off / user) still raises, and recovery still clears.
    @Test func connectionEdgeIsSilentThroughReconnectButRaisesAtExhaustion() {
        // Momentary drop → the kit's reconnecting window: MUST stay silent (this is the whole fix).
        #expect(SafetyEdge.connection(prev: .connected, now: .connecting) == .none)
        #expect(SafetyEdge.connection(prev: .bolusing, now: .connecting) == .none)
        #expect(SafetyEdge.connection(prev: .connecting, now: .connecting) == .none)
        #expect(SafetyEdge.connection(prev: .connecting, now: .scanning) == .none)
        // A recovering link sliding to a PLAIN disconnect (not the terminal give-up) is still the throttled
        // ladder — it recovers silently, so no alarm (net expectation: never INCREASE disconnect notices).
        #expect(SafetyEdge.connection(prev: .connecting, now: .disconnected) == .none)
        #expect(SafetyEdge.connection(prev: .scanning, now: .disconnected) == .none)
        // The ladder GIVES UP (reconnectExhausted → .error) after the transient `.connecting`: MUST raise,
        // even though the immediately-preceding state was the reconnect state, not a live link.
        #expect(SafetyEdge.connection(prev: .connecting, now: .error) == .raise)
        #expect(SafetyEdge.connection(prev: .scanning, now: .error) == .raise)
        // Recovery from the reconnect window clears any (future) escalation.
        #expect(SafetyEdge.connection(prev: .connecting, now: .connected) == .clear)
        // A steady terminal state never re-fires.
        #expect(SafetyEdge.connection(prev: .error, now: .error) == .none)
        #expect(SafetyEdge.connection(prev: .error, now: .connected) == .clear)
    }

    @Test func freshnessEdgeRaisesOnLossClearsOnResumeNeverAtStartup() {
        #expect(SafetyEdge.freshness(wasFresh: false, isFresh: false) == .none)   // no data yet ≠ data lost
        #expect(SafetyEdge.freshness(wasFresh: true, isFresh: false) == .raise)   // had readings, lost them
        #expect(SafetyEdge.freshness(wasFresh: false, isFresh: true) == .clear)   // resumed
        #expect(SafetyEdge.freshness(wasFresh: true, isFresh: true) == .none)     // steady
    }

    // MARK: Pump-identity → safety class (increment 5 — the reroute through autoSuppression)

    @Test func safetyClassMapsPumpIdentitiesToTheForceProtectedSet() {
        typealias K = NotificationKind
        // Occlusion (delivery stopped) — the two occlusion alarm bits.
        #expect(TandemBackend.safetyClass(kind: K.alarm, id: 2) == .occlusion)
        #expect(TandemBackend.safetyClass(kind: K.alarm, id: 26) == .occlusion)
        #expect(TandemBackend.safetyClass(kind: K.alarm, id: 8) == .other)        // "Empty cartridge" ≠ occlusion class
        // Low insulin in the cartridge.
        #expect(TandemBackend.safetyClass(kind: K.alert, id: 0) == .lowInsulin)
        #expect(TandemBackend.safetyClass(kind: K.alert, id: 17) == .lowInsulin)
        // CGM loss reported on the ALERT bitmap.
        #expect(TandemBackend.safetyClass(kind: K.alert, id: 48) == .cgmDataLoss) // CGM unavailable
        #expect(TandemBackend.safetyClass(kind: K.alert, id: 40) == .cgmDataLoss) // CGM error
        #expect(TandemBackend.safetyClass(kind: K.alert, id: 6) == .other)        // Max basal rate
        // CGM loss on the CGM bitmap (sensor failed/expired, out of range, failed connection, transmitter expired).
        for id in [11, 13, 14, 27, 39] {
            #expect(TandemBackend.safetyClass(kind: K.cgmAlert, id: id) == .cgmDataLoss)
        }
        // Glucose-LEVEL CGM alerts stay user-ruleable (.other) — force-protection is loss-of-coverage only.
        #expect(TandemBackend.safetyClass(kind: K.cgmAlert, id: 2) == .other)     // High glucose
        #expect(TandemBackend.safetyClass(kind: K.cgmAlert, id: 3) == .other)     // Low glucose
        #expect(TandemBackend.safetyClass(kind: K.cgmAlert, id: 12) == .other)    // Sensor expiring (data still flows)
        #expect(TandemBackend.safetyClass(kind: K.reminder, id: 0) == .other)
    }

    // MARK: S7 — pump-disconnect escalation ladder wiring (integration)

    /// A unique durable-ledger URL so instances don't share the App Group ledger between serialized tests.
    private func tempLedgerURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("s7-ledger-\(UUID().uuidString).json")
    }

    /// The live→down edge fires the immediate T0 post (with the explicit pump-buttons instruction) AND
    /// requests the delayed escalation family be scheduled — the whole point of S7: a user who walked away
    /// keeps being told, through OS-scheduled re-notifications, to use the pump's own buttons.
    @Test func disconnectEdgeSchedulesTheEscalationFamilyAndStrengthensT0Copy() async {
        let backend = MockBackend()
        let model = AppModel(source: backend, ledgerStoreURL: tempLedgerURL())
        await backend.connect()                       // previousConnection → .connected

        var posted: [NotificationBroker.Message] = []
        var scheduled: [DisconnectEscalation.Step] = []
        model.notificationSink = { msg, _, _ in posted.append(msg) }
        model.notificationScheduleSink = { scheduled = $0 }

        backend.disconnect()                          // onChange → refresh → .raise

        // Exactly one immediate T0 disconnect post, carrying the explicit pump-buttons instruction.
        let disc = posted.filter { $0.category == .pumpDisconnect }
        #expect(disc.count == 1)
        #expect(disc.first?.dedupeKey == "safety.pumpDisconnect")
        #expect(disc.first?.body.contains(DisconnectEscalation.pumpButtonsInstruction) == true)
        // The full escalation ladder was handed off for scheduling (ids + count match the source of truth).
        #expect(!scheduled.isEmpty)
        #expect(scheduled.map(\.id) == DisconnectEscalation.stepIds)
    }

    /// Reconnect (the `.clear` edge) cancels/withdraws the immediate T0 banner AND every scheduled
    /// escalation step, so nothing lingers or fires after the pump is back.
    @Test func reconnectEdgeWithdrawsT0AndEveryEscalationStep() async {
        let backend = MockBackend()
        let model = AppModel(source: backend, ledgerStoreURL: tempLedgerURL())
        await backend.connect()                       // → connected
        backend.disconnect()                          // → disconnected (raise; uncaptured)

        var withdrawn: [String] = []
        model.notificationWithdrawSink = { withdrawn = $0 }

        await backend.connect()                       // final transition → .clear

        #expect(withdrawn.contains("safety.pumpDisconnect"))
        for id in DisconnectEscalation.stepIds {
            #expect(withdrawn.contains(id), "escalation step \(id) must be cancelled on reconnect")
        }
    }

    // MARK: Reconciliation notification (integration)

    /// A durable store preloaded with a fixed ledger, so we seed the reconcile state directly (no delivery
    /// path, no gating dependency).
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

    @Test func reconcileNotifiesTheAuthoritativeNotDeliveredOutcome() async {
        // Seed ONE interrupted pre-initiate entry: began + marked delivering, but never `markSent`, so
        // `sentToPump == false` and it appears unresolved. A relaunch reconciles it as not-delivered and
        // MUST tell the user the authoritative outcome (today that reaches them through nothing).
        var ledger = RemoteBolusLedger()
        _ = ledger.begin(peerId: "watch", requestId: "r9", doseKey: "watch:r9:2.0")
        ledger.markDelivering(peerId: "watch", requestId: "r9")
        let model = AppModel(source: MockBackend(), ledgerStore: SeedLedgerStore(seed: ledger))
        var posted: [NotificationBroker.Message] = []
        model.notificationSink = { msg, _, _ in posted.append(msg) }

        await model.reconcileUnresolvedDeliveries()

        let reconciles = posted.filter { $0.category == .bolusReconciliation }
        #expect(reconciles.count == 1)
        #expect(reconciles.first?.title == "Bolus not delivered")
        #expect(reconciles.first?.dedupeKey == "reconcile-watch-r9")
        #expect(!model.deliveryGloballyBlocked)   // and the interrupted entry cleared (not a permanent lock)
    }
}
