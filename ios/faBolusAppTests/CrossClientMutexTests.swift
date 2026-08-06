import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P11 / S6 — the cross-client in-flight mutex: two DIFFERENT remotes requesting the SAME physical dose
/// (same `doseKey`, different `peerId`/`requestId`) must never cause a second delivery. The ledger keys on
/// `(peerId, requestId)`, so `begin` alone would let both through; only a mutex above the backend, keyed by
/// the idempotency token and owned at the single delivery funnel (`runLedgeredDelivery`), stops the second.
///
/// Deterministic via `MockBackend.onDeliverInFlight`: client A's delivery is held IN FLIGHT on the pump
/// (id recorded, `.bolusing`) while client B fires the same dose, so the collision is exercised without any
/// wall-clock timing.
@Suite(.serialized)
@MainActor
struct CrossClientMutexTests {

    private func makeModel() async -> (AppModel, MockBackend, EchoRecorder) {
        let backend = MockBackend()
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("s6-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        let rec = EchoRecorder(); rec.attach(to: model)
        await backend.connect()
        return (model, backend, rec)
    }

    /// Captures echoes so we can tell which client (by requestId) got what status/message.
    @MainActor final class EchoRecorder {
        private(set) var commands: [RemoteCommand] = []
        func attach(to model: AppModel) { model.addRemoteEcho { [weak self] c in self?.commands.append(c) } }
        func delivered(_ requestId: String) -> Bool {
            commands.contains { $0.requestId == requestId && $0.status == .delivered }
        }
        func message(_ requestId: String) -> String? {
            commands.last { $0.requestId == requestId }?.message
        }
    }

    /// Two DIFFERENT clients fire the SAME dose while the first is in flight: exactly one dose reaches the
    /// pump, and the loser is told a bolus is in progress — NOT the alarming "check the pump" (which is
    /// reserved for a genuinely unconfirmed outcome, e.g. a crash mid-delivery).
    @Test func concurrentSameDoseFromTwoClientsDeliversOnlyOnce() async {
        await AppSettingsGate.withCleanRemoteBolusAllowed {
            let (model, backend, rec) = await makeModel()
            let startIob = backend.snapshot.iobUnits
            backend.onDeliverInFlight = { [weak model] in
                await model?.remoteDeliver(requestId: "garmin-1", units: 2.0, from: .garmin, peerId: "garmin")
            }
            await model.remoteDeliver(requestId: "watch-1", units: 2.0, from: .appleWatch, peerId: "watch")

            // Safety invariant: exactly ONE dose reached the pump — no cross-client double-dose.
            #expect(backend.snapshot.iobUnits == startIob + 2.0)
            // A delivered; B was rejected while A was in flight (no delivered echo).
            #expect(rec.delivered("watch-1"))
            #expect(!rec.delivered("garmin-1"))
            // B's rejection message is the transient "in progress" one, not the "check the pump" one.
            let bMsg = rec.message("garmin-1") ?? ""
            #expect(bMsg.contains("already being delivered"))
            #expect(!bMsg.contains("check the pump"))
        }
    }

    /// The mutex is IN-FLIGHT only, not a permanent dedup: once the first delivery settles, a later request
    /// for the same dose (different requestId) delivers normally. A user genuinely may bolus 2 U twice.
    @Test func sameDoseAfterTheFirstSettlesDeliversAgain() async {
        await AppSettingsGate.withCleanRemoteBolusAllowed {
            let (model, backend, rec) = await makeModel()
            let startIob = backend.snapshot.iobUnits
            await model.remoteDeliver(requestId: "watch-1", units: 2.0, from: .appleWatch, peerId: "watch")
            await model.remoteDeliver(requestId: "watch-2", units: 2.0, from: .appleWatch, peerId: "watch")
            #expect(backend.snapshot.iobUnits == startIob + 4.0)   // both sequential doses delivered
            #expect(rec.delivered("watch-1"))
            #expect(rec.delivered("watch-2"))
        }
    }
}

/// Minimal helper to run a body with the `AppSettings` gates in a state that allows an authenticated
/// remote bolus (child off, read-only off, advanced control on so the funnel's capability gate passes on
/// the Mobi `MockBackend`), restoring them after so the serialized suite can't leak gate state.
@MainActor
private enum AppSettingsGate {
    static func withCleanRemoteBolusAllowed(_ body: () async -> Void) async {
        let s = AppSettings.shared
        let child = s.childModeEnabled, ro = s.remotesReadOnly, adv = s.advancedControlEnabled
        s.childModeEnabled = false; s.remotesReadOnly = false; s.advancedControlEnabled = true
        await body()
        s.childModeEnabled = child; s.remotesReadOnly = ro; s.advancedControlEnabled = adv
    }
}
