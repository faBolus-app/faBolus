import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Two different remotes requesting the same physical dose must never cause a second delivery while the
/// first is in flight.
@Suite(.serialized)
@MainActor
struct CrossClientMutexTests {

    private func makeModel() async -> (AppModel, MockBackend, EchoRecorder) {
        let backend = MockBackend()
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("s6-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        let rec = EchoRecorder()
        rec.attach(to: model)
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

    /// Two DIFFERENT clients (the local phone and Garmin) fire the SAME dose while the first is in
    /// flight: exactly one dose reaches the pump, and the loser is told a bolus is in progress — NOT
    /// the alarming "check the pump" (which is reserved for a genuinely unconfirmed outcome, e.g. a
    /// crash mid-delivery).
    @Test func concurrentSameDoseFromTwoClientsDeliversOnlyOnce() async {
        await AppSettingsGate.withCleanRemoteBolusAllowed {
            let (model, backend, rec) = await makeModel()
            let startIob = backend.snapshot.iobUnits
            backend.onDeliverInFlight = { [weak model] in
                await model?.remoteDeliver(requestId: "garmin-1", units: 2.0, from: .garmin, peerId: "garmin")
            }
            await model.remoteDeliver(requestId: "local-1", units: 2.0, from: .phoneUI, peerId: "local")

            // Safety invariant: exactly ONE dose reached the pump — no cross-client double-dose.
            #expect(backend.snapshot.iobUnits == startIob + 2.0)
            // A delivered; B was rejected while A was in flight (no delivered echo).
            #expect(rec.delivered("local-1"))
            #expect(!rec.delivered("garmin-1"))
            // B's rejection message is the transient "in progress" one, not the "check the pump" one.
            let bMsg = rec.message("garmin-1") ?? ""
            #expect(bMsg.contains("already being delivered"))
            #expect(!bMsg.contains("check the pump"))
        }
    }

    /// The in-flight mutex is not a permanent dedup. After settle, the content+time recency guard still
    /// refuses a same-peer, same-content recompose under a fresh id within the recency window.
    @Test func sameDoseFromSameClientShortlyAfterSettlingIsRefusedByRecencyGuard() async {
        await AppSettingsGate.withCleanRemoteBolusAllowed {
            let (model, backend, rec) = await makeModel()
            let startIob = backend.snapshot.iobUnits
            await model.remoteDeliver(requestId: "garmin-1", units: 2.0, from: .garmin, peerId: "garmin")
            await model.remoteDeliver(requestId: "garmin-2", units: 2.0, from: .garmin, peerId: "garmin")
            #expect(backend.snapshot.iobUnits == startIob + 2.0)  // only the FIRST dose delivered
            #expect(rec.delivered("garmin-1"))
            #expect(!rec.delivered("garmin-2"))  // recency guard refused the recompose
            #expect(rec.message("garmin-2")?.contains("matching bolus was just delivered") == true)
        }
    }

    /// The positive-path counterpart the retired test's title promised: a user genuinely dosing twice in a
    /// row still works — just with a DIFFERENT dose (a different doseKey is never flagged by the recency
    /// guard, matching `PhoneWidgetDoubleDoseTests.differentContentShortlyAfterAPriorDeliveryStillProceeds`).
    @Test func differentDoseFromSameClientShortlyAfterSettlingStillDeliversNormally() async {
        await AppSettingsGate.withCleanRemoteBolusAllowed {
            let (model, backend, rec) = await makeModel()
            let startIob = backend.snapshot.iobUnits
            await model.remoteDeliver(requestId: "garmin-3", units: 2.0, from: .garmin, peerId: "garmin")
            await model.remoteDeliver(requestId: "garmin-4", units: 1.5, from: .garmin, peerId: "garmin")
            #expect(backend.snapshot.iobUnits == startIob + 3.5)  // both distinct doses delivered
            #expect(rec.delivered("garmin-3"))
            #expect(rec.delivered("garmin-4"))
        }
    }
}

/// Minimal helper to run a body with the `AppSettings` gates in a state that allows an authenticated
/// remote bolus (child off, read-only off, and the per-surface Garmin bolus enable ON so the evaluator
/// doesn't fail-closed on the default-OFF flag), restoring them after so the serialized suite can't
/// leak gate state.
@MainActor
private enum AppSettingsGate {
    static func withCleanRemoteBolusAllowed(_ body: () async -> Void) async {
        let s = AppSettings.shared
        let child = s.childModeEnabled, ro = s.remotesReadOnly
        let gb = s.garminBolusEnabled
        s.childModeEnabled = false
        s.remotesReadOnly = false
        s.garminBolusEnabled = true
        await body()
        s.childModeEnabled = child
        s.remotesReadOnly = ro
        s.garminBolusEnabled = gb
    }
}
