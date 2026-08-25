import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 14 Plan 01 — the VA-07 family "double-dose window" tracer: closes the settled-echo-loss retry
/// hazard (CX-G-01 phone half) plus its two symmetric supersession re-checks (CX-F-01, C3-01).
///
/// Two-actor regressions here simulate a settled-echo-loss retry: "actor 1" is the delivery that actually
/// reached the pump; "actor 2" is a re-composed retry (or a second remote/widget) that sends the SAME
/// dose content under a FRESH requestId/approval a moment later. Before this plan, `RemoteBolusLedger`
/// only dedups by `(peer,requestId)`, so actor 2 would sail through as "new" and double-dose. These tests
/// drive the REAL `AppModel` against the in-memory `MockBackend` (no BLE), mirroring the harness in
/// `AppModelBehaviorTests`/`StaleRemoteDoseHostTests`.
@Suite(.serialized)
@MainActor
struct PhoneWidgetDoubleDoseTests {

    // MARK: - Test harness (mirrors AppModelBehaviorTests / StaleRemoteDoseHostTests)

    @MainActor
    final class EchoRecorder {
        private(set) var commands: [RemoteCommand] = []
        func attach(to model: AppModel) { model.addRemoteEcho { [weak self] c in self?.commands.append(c) } }
        var last: RemoteCommand? { commands.last }
        var statuses: [RemoteCommand.Status] { commands.compactMap { $0.status } }
        func count(_ s: RemoteCommand.Status) -> Int { statuses.filter { $0 == s }.count }
    }

    private func makeModel(connected: Bool = false) async -> (AppModel, MockBackend, EchoRecorder) {
        let backend = MockBackend()
        // FB-03: give each model its own durable-ledger file so the persisted ledger can't leak between
        // serialized tests (production shares one App Group file; tests must not).
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doubledose-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        let rec = EchoRecorder(); rec.attach(to: model)
        if connected { await backend.connect() }
        return (model, backend, rec)
    }

    private func withCleanSettings(_ body: () async throws -> Void) async rethrows {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled, allowed = s.childAllowed, adv = s.advancedControlEnabled
        let rro = s.remotesReadOnly, clr = s.readOnlyAllowAlertClear
        let mode = s.appMode
        s.phoneReadOnly = false; s.childModeEnabled = false; s.advancedControlEnabled = true
        s.remotesReadOnly = false; s.readOnlyAllowAlertClear = false
        s.appMode = .advanced
        defer {
            s.phoneReadOnly = ro; s.childModeEnabled = child; s.childAllowed = allowed
            s.advancedControlEnabled = adv; s.remotesReadOnly = rro; s.readOnlyAllowAlertClear = clr
            s.appMode = mode
        }
        try await body()
    }

    private let tol = 0.0001

    // MARK: - Task 1 (TRACER): T-14-01 / CX-G-01 (phone) — content+time dedup guard end-to-end
    //
    // `.garmin` surface (so `surface.isRemote` is true and the passcode-optional/garminBolusEnabled gate
    // is satisfied), mirroring `AppModelBehaviorTests`'s VA-07-host block.

    /// The defining hazard this plan closes: a settled-echo-loss retry recomposes the SAME dose under a
    /// FRESH requestId. `remoteDeliver` must refuse it BEFORE the backend — no second pump write.
    @Test func twoActorPhoneDoubleDoseRejectsRecomposedContentWithFreshRequestId() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            let savedGarmin = AppSettings.shared.garminBolusEnabled
            AppSettings.shared.garminBolusEnabled = true
            defer { AppSettings.shared.garminBolusEnabled = savedGarmin }

            let iob0 = backend.snapshot.iobUnits
            // Actor 1: a units-mode remote dose delivers normally.
            await model.remoteDeliver(requestId: "actor1-req", units: 1.0,
                                      sentAt: Int(Date().timeIntervalSince1970),
                                      from: .garmin, peerId: "garmin")
            #expect(rec.last?.status == .delivered)
            let iobAfterActor1 = backend.snapshot.iobUnits
            #expect(iobAfterActor1 > iob0 + 0.9)                      // actor 1 really delivered
            #expect(rec.count(.delivering) == 1)

            // Actor 2: the SAME dose content (same units), a FRESH requestId, a `sentAt` comfortably AFTER
            // the host-delivery stamp (isolates the content+time guard — the VA-07 compose-supersession
            // check must NOT be what fires here).
            await model.remoteDeliver(requestId: "actor2-req", units: 1.0,
                                      sentAt: Int(Date().timeIntervalSince1970) + 5,
                                      from: .garmin, peerId: "garmin")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.contains("delivered after this request was created") == false)
            #expect(rec.count(.delivering) == 1)                      // NO second delivering echo
            // No second pump write: IOB unchanged from actor 1's delivery.
            #expect(abs(backend.snapshot.iobUnits - iobAfterActor1) < tol)
        }
    }

    /// The positive-path counterpart: a DIFFERENT dose content (different units) under a fresh requestId,
    /// shortly after a delivery, still proceeds normally — the guard is additive, not a blanket block.
    @Test func differentContentShortlyAfterAPriorDeliveryStillProceeds() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            let savedGarmin = AppSettings.shared.garminBolusEnabled
            AppSettings.shared.garminBolusEnabled = true
            defer { AppSettings.shared.garminBolusEnabled = savedGarmin }

            await model.remoteDeliver(requestId: "actor1-req-b", units: 1.0,
                                      sentAt: Int(Date().timeIntervalSince1970),
                                      from: .garmin, peerId: "garmin")
            #expect(rec.last?.status == .delivered)

            // Different units ⇒ a different doseKey ⇒ not flagged by the recency guard.
            await model.remoteDeliver(requestId: "actor2-req-b", units: 2.0,
                                      sentAt: Int(Date().timeIntervalSince1970) + 5,
                                      from: .garmin, peerId: "garmin")
            #expect(rec.last?.status == .delivered)
            #expect(abs((backend.lastDeliver?.units ?? -1) - 2.0) < tol)
        }
    }
}
