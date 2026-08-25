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

    // MARK: - Task 2: CX-F-01 — confirmRemoteBolus supersession + accessDecision re-check
    //
    // `presentRemoteBolus` freezes a pending approval at `createdAt`; `confirmRemoteBolus` is the SECOND
    // confirm (the phone user tapping "Yes"). Before this task, it re-checked only the approval's AGE —
    // never a completed host delivery in the interim, nor whether access has since been revoked.

    /// A pending approval composed BEFORE a host delivery that has since completed must be refused at
    /// confirm time — even though it is well within `remoteApprovalMaxAge` (the existing age check alone
    /// would have let it through).
    @Test func confirmRefusesApprovalSupersededByAnInterveningHostDelivery() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            let savedGarmin = AppSettings.shared.garminBolusEnabled
            AppSettings.shared.garminBolusEnabled = true
            defer { AppSettings.shared.garminBolusEnabled = savedGarmin }

            let dose = await model.recommendBolus(carbsGrams: 30, bgMgdl: nil).recommendedUnits
            await model.presentRemoteBolus(requestId: "cxf01-a", units: 0, carbsGrams: 30,
                                           remoteEstimate: dose, from: .garmin, peerId: "garmin")
            #expect(model.pendingRemoteBolus != nil)

            // An intervening HOST delivery completes (stamps lastHostDeliveryAt AFTER the pending
            // approval's createdAt) while the phone user is still deciding.
            let iobBeforeHostBolus = backend.snapshot.iobUnits
            await model.deliverBolus(units: 1.0)
            #expect(backend.snapshot.iobUnits > iobBeforeHostBolus + 0.9)
            let iobAfterHostBolus = backend.snapshot.iobUnits

            await model.confirmRemoteBolus()
            #expect(model.pendingRemoteBolus == nil)
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.contains("delivered after this request was created") == true)
            #expect(model.lastError?.contains("delivered after this request was created") == true)
            // No second pump write from the confirm.
            #expect(abs(backend.snapshot.iobUnits - iobAfterHostBolus) < tol)
        }
    }

    /// `accessDecision` is re-evaluated at confirm time: settings that changed AFTER present (denying the
    /// surface) must refuse the confirm, not just its age.
    @Test func confirmRefusesWhenAccessHasBeenRevokedSincePresent() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            let savedGarmin = AppSettings.shared.garminBolusEnabled
            AppSettings.shared.garminBolusEnabled = true
            defer { AppSettings.shared.garminBolusEnabled = savedGarmin }

            let dose = await model.recommendBolus(carbsGrams: 30, bgMgdl: nil).recommendedUnits
            await model.presentRemoteBolus(requestId: "cxf01-b", units: 0, carbsGrams: 30,
                                           remoteEstimate: dose, from: .garmin, peerId: "garmin")
            #expect(model.pendingRemoteBolus != nil)

            // Access is revoked for remote surfaces WHILE the approval is pending.
            AppSettings.shared.remotesReadOnly = true

            await model.confirmRemoteBolus()
            #expect(model.pendingRemoteBolus == nil)
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.lowercased().contains("read-only") == true)
            #expect(backend.lastDeliver == nil)   // never reached the backend
        }
    }

    /// The positive-path counterpart: a pending REMOTE approval with no intervening host delivery and
    /// valid access still confirms normally (the guard is additive, not a blanket block on remote confirms).
    @Test func confirmProceedsNormallyForARemoteApprovalWithNoSupersessionOrAccessChange() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            let savedGarmin = AppSettings.shared.garminBolusEnabled
            AppSettings.shared.garminBolusEnabled = true
            defer { AppSettings.shared.garminBolusEnabled = savedGarmin }

            let dose = await model.recommendBolus(carbsGrams: 30, bgMgdl: nil).recommendedUnits
            await model.presentRemoteBolus(requestId: "cxf01-c", units: 0, carbsGrams: 30,
                                           remoteEstimate: dose, from: .garmin, peerId: "garmin")
            await model.confirmRemoteBolus()
            #expect(model.pendingRemoteBolus == nil)
            #expect(rec.last?.status == .delivered)
            #expect(abs((backend.lastDeliver?.units ?? -1) - dose) < tol)
        }
    }

    // MARK: - Task 3: C3-01 — deliverWidgetBolus stamps lastHostDeliveryAt
    //
    // Every OTHER completed host delivery stamps `lastHostDeliveryAt` (local, extended, remote) so a
    // remote request composed BEFORE it is caught by VA-07's `composeSupersededByHostDelivery`. The
    // widget path is the one delivery site that historically does NOT stamp it — a blind spot: a remote
    // request composed before a widget delivery sails through unrefused.

    /// After a widget `.delivered` outcome, `lastHostDeliveryAt` advances — proven indirectly through the
    /// VA-07 supersession check it feeds (the property itself is `private(set)`, not directly assertable
    /// from a test target).
    @Test func widgetDeliveryStampsLastHostDeliveryAt() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            let savedGarmin = AppSettings.shared.garminBolusEnabled
            AppSettings.shared.garminBolusEnabled = true
            defer { AppSettings.shared.garminBolusEnabled = savedGarmin }

            let w = await model.deliverWidgetBolus(requestId: "c301-widget", units: 1.0)
            #expect(w.delivered > 0)
            #expect(backend.snapshot.iobUnits > 0.9)

            // A remote request composed BEFORE the widget delivery must now be caught as superseded.
            await model.remoteDeliver(requestId: "c301-remote-old", units: 2.0,
                                      sentAt: Int(Date().timeIntervalSince1970) - 120,
                                      from: .garmin, peerId: "garmin")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.contains("delivered after this request was created") == true)
            #expect(abs((backend.lastDeliver?.units ?? -1) - 1.0) < tol)   // only the widget's 1.0 U landed
        }
    }

    /// The two-actor WIDGET double-dose regression: a remote request composed BEFORE a widget delivery is
    /// refused — no second pump write. Robust to today's behavior (which is expected to FAIL until C3-01
    /// lands: today the widget path never stamps `lastHostDeliveryAt`, so this superseded request would
    /// incorrectly proceed).
    @Test func twoActorWidgetDoubleDoseRejectsRequestComposedBeforeWidgetDelivery() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            let savedGarmin = AppSettings.shared.garminBolusEnabled
            AppSettings.shared.garminBolusEnabled = true
            defer { AppSettings.shared.garminBolusEnabled = savedGarmin }

            let composedBefore = Int(Date().timeIntervalSince1970) - 5   // "composed" just before the widget tap
            let w = await model.deliverWidgetBolus(requestId: "c301-w2", units: 1.0)
            #expect(w.delivered > 0)
            let iobAfterWidget = backend.snapshot.iobUnits

            await model.remoteDeliver(requestId: "c301-r2", units: 3.0, sentAt: composedBefore,
                                      from: .garmin, peerId: "garmin")
            #expect(rec.last?.status == .failed)
            #expect(rec.count(.delivering) == 1)                          // only the widget ever delivered
            #expect(abs(backend.snapshot.iobUnits - iobAfterWidget) < tol)  // no second pump write
        }
    }
}
