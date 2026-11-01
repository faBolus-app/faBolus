import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// A settled-echo-loss retry that recomposes the same dose under a fresh requestId must be refused
/// before a second pump write.
@Suite(.serialized)
@MainActor
struct PhoneWidgetDoubleDoseTests {

    // MARK: - Test harness (mirrors AppModelBehaviorTests / StaleRemoteDoseHostTests)

    private func makeModel(connected: Bool = false) async -> (AppModel, MockBackend, EchoRecorder) {
        let backend = MockBackend()
        // Give each model its own durable-ledger file so the persisted ledger can't leak between
        // serialized tests (production shares one App Group file; tests must not).
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doubledose-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        let rec = EchoRecorder()
        rec.attach(to: model)
        if connected { await backend.connect() }
        return (model, backend, rec)
    }

    private func withCleanSettings(_ body: () async throws -> Void) async rethrows {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled, allowed = s.childAllowed
        let rro = s.remotesReadOnly, clr = s.readOnlyAllowAlertClear
        s.phoneReadOnly = false
        s.childModeEnabled = false
        s.remotesReadOnly = false
        s.readOnlyAllowAlertClear = false
        defer {
            s.phoneReadOnly = ro
            s.childModeEnabled = child
            s.childAllowed = allowed
            s.remotesReadOnly = rro
            s.readOnlyAllowAlertClear = clr
        }
        try await body()
    }

    private let tol = 0.0001

    // MARK: - Content+time dedup guard end-to-end
    //
    // `.garmin` surface so `surface.isRemote` is true and the garminBolusEnabled gate is satisfied.

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
            await model.remoteDeliver(
                requestId: "actor1-req", units: 1.0,
                sentAt: Int(Date().timeIntervalSince1970),
                from: .garmin, peerId: "garmin")
            #expect(rec.last?.status == .delivered)
            let iobAfterActor1 = backend.snapshot.iobUnits
            #expect(iobAfterActor1 > iob0 + 0.9)  // actor 1 really delivered
            #expect(rec.count(.delivering) == 1)

            // Actor 2: the SAME dose content (same units), a FRESH requestId, a `sentAt` comfortably AFTER
            // the host-delivery stamp (isolates the content+time guard — compose-supersession must NOT
            // be what fires here).
            await model.remoteDeliver(
                requestId: "actor2-req", units: 1.0,
                sentAt: Int(Date().timeIntervalSince1970) + 5,
                from: .garmin, peerId: "garmin")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.contains("delivered after this request was created") == false)
            #expect(rec.count(.delivering) == 1)  // NO second delivering echo
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

            await model.remoteDeliver(
                requestId: "actor1-req-b", units: 1.0,
                sentAt: Int(Date().timeIntervalSince1970),
                from: .garmin, peerId: "garmin")
            #expect(rec.last?.status == .delivered)

            // Different units ⇒ a different doseKey ⇒ not flagged by the recency guard.
            await model.remoteDeliver(
                requestId: "actor2-req-b", units: 2.0,
                sentAt: Int(Date().timeIntervalSince1970) + 5,
                from: .garmin, peerId: "garmin")
            #expect(rec.last?.status == .delivered)
            #expect(abs((backend.lastDeliver?.units ?? -1) - 2.0) < tol)
        }
    }

    // MARK: - confirmRemoteBolus supersession + accessDecision re-check
    //
    // `presentRemoteBolus` freezes a pending approval at `createdAt`; `confirmRemoteBolus` is the
    // second confirm. It must re-check an intervening host delivery and whether access has since been revoked.

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
            await model.presentRemoteBolus(
                requestId: "cxf01-a", units: 0, carbsGrams: 30,
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
            await model.presentRemoteBolus(
                requestId: "cxf01-b", units: 0, carbsGrams: 30,
                remoteEstimate: dose, from: .garmin, peerId: "garmin")
            #expect(model.pendingRemoteBolus != nil)

            // Access is revoked for remote surfaces WHILE the approval is pending.
            AppSettings.shared.remotesReadOnly = true

            await model.confirmRemoteBolus()
            #expect(model.pendingRemoteBolus == nil)
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.lowercased().contains("read-only") == true)
            #expect(backend.lastDeliver == nil)  // never reached the backend
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
            await model.presentRemoteBolus(
                requestId: "cxf01-c", units: 0, carbsGrams: 30,
                remoteEstimate: dose, from: .garmin, peerId: "garmin")
            await model.confirmRemoteBolus()
            #expect(model.pendingRemoteBolus == nil)
            #expect(rec.last?.status == .delivered)
            #expect(abs((backend.lastDeliver?.units ?? -1) - dose) < tol)
        }
    }

    // MARK: - deliverWidgetBolus stamps lastHostDeliveryAt
    //
    // Every other completed host delivery stamps `lastHostDeliveryAt` so a remote request composed
    // BEFORE it is caught as superseded. The widget path historically did not stamp it.

    /// After a widget `.delivered` outcome, `lastHostDeliveryAt` advances — proven indirectly through the
    /// supersession check it feeds (the property itself is `private(set)`, not directly assertable).
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
            await model.remoteDeliver(
                requestId: "c301-remote-old", units: 2.0,
                sentAt: Int(Date().timeIntervalSince1970) - 120,
                from: .garmin, peerId: "garmin")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.contains("delivered after this request was created") == true)
            #expect(abs((backend.lastDeliver?.units ?? -1) - 1.0) < tol)  // only the widget's 1.0 U landed
        }
    }

    /// The two-actor WIDGET double-dose regression: a remote request composed BEFORE a widget delivery is
    /// refused — no second pump write. Robust to today's behavior (which is expected to FAIL until the
    /// widget path stamps `lastHostDeliveryAt`: today it never does, so this superseded request would
    /// incorrectly proceed).
    @Test func twoActorWidgetDoubleDoseRejectsRequestComposedBeforeWidgetDelivery() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            let savedGarmin = AppSettings.shared.garminBolusEnabled
            AppSettings.shared.garminBolusEnabled = true
            defer { AppSettings.shared.garminBolusEnabled = savedGarmin }

            let composedBefore = Int(Date().timeIntervalSince1970) - 5  // "composed" just before the widget tap
            let w = await model.deliverWidgetBolus(requestId: "c301-w2", units: 1.0)
            #expect(w.delivered > 0)
            let iobAfterWidget = backend.snapshot.iobUnits

            await model.remoteDeliver(
                requestId: "c301-r2", units: 3.0, sentAt: composedBefore,
                from: .garmin, peerId: "garmin")
            #expect(rec.last?.status == .failed)
            #expect(rec.count(.delivering) == 1)  // only the widget ever delivered
            #expect(abs(backend.snapshot.iobUnits - iobAfterWidget) < tol)  // no second pump write
        }
    }

    // MARK: - present→confirm derives the idempotency doseKey from the RAW WIRE params
    //
    // Both remote-delivery entry points must key the ledger doseKey off the original wire request,
    // never the resolved/frozen correction basis. Otherwise the two flows produce different doseKeys
    // for one logical dose and the recency/conflict guard narrows.

    /// After a present→confirm carb delivery where the host's fresh correction basis differs from the
    /// wire `bgMgdl`, the ledger's recency index must be keyed on the WIRE bg.
    @Test func presentConfirmDoseKeyIsDerivedFromRawWireParamsNotResolvedBasis() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            let savedGarmin = AppSettings.shared.garminBolusEnabled
            AppSettings.shared.garminBolusEnabled = true
            defer { AppSettings.shared.garminBolusEnabled = savedGarmin }

            let carbs = 30.0
            let freshBg = 120  // host's FRESH reading (becomes the resolved correction basis)
            let wireBg = 185  // the DIFFERENT bg the remote sent on the wire
            backend.setLiveIob(1.0)
            backend.seedFreshGlucose(freshBg, at: Date())  // fresh ⇒ freshCorrectionBG == 120 wins as basis

            // The remote's estimate must match the host recompute off the FRESH basis (120), or the
            // divergence guard would reject before we ever reach the doseKey.
            let dose = await model.recommendBolus(carbsGrams: carbs, bgMgdl: freshBg).recommendedUnits
            await model.presentRemoteBolus(
                requestId: "wr01", units: 0, carbsGrams: carbs, bgMgdl: wireBg,
                remoteEstimate: dose, from: .garmin, peerId: "garmin")
            #expect(model.pendingRemoteBolus != nil)
            await model.confirmRemoteBolus()
            #expect(rec.last?.status == .delivered)
            #expect(backend.lastDeliver?.bg == freshBg)  // delivered dose still uses the FROZEN fresh basis (unchanged)

            // The recency index (carried in the value-type ledger snapshot) must be keyed on the WIRE bg.
            let snap = model.privacyExportLedgerSnapshot
            let wireKey = RemoteBolusLedger.doseKey(units: 0, carbsGrams: carbs, bgMgdl: wireBg)
            let resolvedKey = RemoteBolusLedger.doseKey(units: 0, carbsGrams: carbs, bgMgdl: freshBg)
            #expect(wireKey != resolvedKey)  // the two bases really do produce different keys
            #expect(
                snap.hasRecentlyDeliveredDuplicate(peerId: "garmin", doseKey: wireKey),
                "confirm-path doseKey must match remoteDeliver's raw-wire doseKey")
            #expect(
                !snap.hasRecentlyDeliveredDuplicate(peerId: "garmin", doseKey: resolvedKey),
                "confirm-path doseKey must NOT be keyed on the resolved correction basis")
        }
    }

    // MARK: - An INDETERMINATE outcome stamps `lastHostDeliveryAt` too
    //
    // An indeterminate outcome MAY have delivered. The durable ledger's unresolved-delivery block masks
    // this today, so these tests assert the stamp directly rather than through supersession.

    /// performLocalBolus `.indeterminate` stamps `lastHostDeliveryAt`.
    @Test func localBolusIndeterminateStampsLastHostDeliveryAt() async {
        try? await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            #expect(model.lastHostDeliveryAt == nil)  // baseline
            backend.forceIndeterminateNextDelivery = true
            await model.deliverBolus(units: 1.0)
            #expect(model.lastError == AppModel.indeterminateOutcomeLockedCopy)  // genuinely indeterminate
            #expect(
                model.lastHostDeliveryAt != nil, "an indeterminate local bolus must stamp lastHostDeliveryAt")
        }
    }

    /// executeResolved `.indeterminate` (remote path) stamps `lastHostDeliveryAt`.
    @Test func remoteBolusIndeterminateStampsLastHostDeliveryAt() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            let savedGarmin = AppSettings.shared.garminBolusEnabled
            AppSettings.shared.garminBolusEnabled = true
            defer { AppSettings.shared.garminBolusEnabled = savedGarmin }
            #expect(model.lastHostDeliveryAt == nil)  // baseline
            backend.forceIndeterminateNextDelivery = true
            await model.remoteDeliver(
                requestId: "in02-remote", units: 2.0,
                sentAt: Int(Date().timeIntervalSince1970),
                from: .garmin, peerId: "garmin")
            #expect(rec.last?.status == .unknown)  // indeterminate echo
            #expect(
                model.lastHostDeliveryAt != nil, "an indeterminate remote bolus must stamp lastHostDeliveryAt")
        }
    }

    /// deliverWidgetBolus `.indeterminate` stamps `lastHostDeliveryAt`.
    @Test func widgetBolusIndeterminateStampsLastHostDeliveryAt() async {
        try? await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            let savedGarmin = AppSettings.shared.garminBolusEnabled
            AppSettings.shared.garminBolusEnabled = true
            defer { AppSettings.shared.garminBolusEnabled = savedGarmin }
            #expect(model.lastHostDeliveryAt == nil)  // baseline
            backend.forceIndeterminateNextDelivery = true
            let w = await model.deliverWidgetBolus(requestId: "in02-widget", units: 1.0)
            #expect(w.delivered == 0)  // indeterminate → no confirmed delivery
            #expect(w.error != nil)
            #expect(
                model.lastHostDeliveryAt != nil, "an indeterminate widget bolus must stamp lastHostDeliveryAt")
        }
    }

    /// deliverExtendedBolus `.indeterminate` stamps `lastHostDeliveryAt` too (the 4th delivery site).
    @Test func extendedBolusIndeterminateStampsLastHostDeliveryAt() async {
        try? await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            #expect(model.lastHostDeliveryAt == nil)  // baseline
            backend.forceIndeterminateNextDelivery = true
            await model.deliverExtendedBolus(totalUnits: 2.0, nowUnits: 1.0, durationMinutes: 30)
            #expect(model.lastError == AppModel.indeterminateOutcomeLockedCopy)  // genuinely indeterminate
            #expect(
                model.lastHostDeliveryAt != nil, "an indeterminate extended bolus must stamp lastHostDeliveryAt"
            )
        }
    }
}
