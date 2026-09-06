import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Host recomputes and clamps remote doses, fails closed on a missing or divergent estimate, and
/// treats stale-CGM as carbs-only; AccessPolicy gates every delivery surface.
@Suite(.serialized)
@MainActor
struct AppModelBehaviorTests {

    // MARK: - Test harness

    /// A fresh model + backend + recorder. `connect()` only when the test needs delivery to succeed
    /// (rejections/gate blocks short-circuit before touching the backend).
    private func makeModel(connected: Bool = false) async -> (AppModel, MockBackend, EchoRecorder) {
        let backend = MockBackend()
        // Each model gets its own durable-ledger file so the persisted ledger can't leak between
        // serialized tests (production shares one App Group file; tests must not).
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appmodel-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        let rec = EchoRecorder()
        rec.attach(to: model)
        if connected { await backend.connect() }
        return (model, backend, rec)
    }

    /// Run `body` with the global `AppSettings` gates in a known-clean state, restoring them after so
    /// the serialized suite never leaks child/read-only state between tests.
    ///
    /// The `MockBackend` is already a Mobi with `.mobiAdvanced`, so every advanced / IDP-CRUD write is
    /// capability-reachable here; a test that wants to prove the capability gate itself sets
    /// `capabilities` to `.full` instead.
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

    // MARK: - Divergence guard (C-06)

    @Test func carbRequestWithinLimitDelivers() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel(connected: true)
            let dose = await model.recommendBolus(carbsGrams: 30, bgMgdl: nil).recommendedUnits
            await model.remoteDeliver(requestId: "d1", carbsGrams: 30, remoteEstimate: dose, peerId: "watch")
            #expect(rec.count(.delivering) == 1)
            #expect(rec.last?.status == .delivered)
            #expect(abs((rec.last?.deliveredUnits ?? -1) - dose) < tol)
        }
    }

    @Test func carbRequestBeyondLimitRejected() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel()
            let dose = await model.recommendBolus(carbsGrams: 30, bgMgdl: nil).recommendedUnits
            await model.remoteDeliver(requestId: "d2", carbsGrams: 30, remoteEstimate: dose + 0.5, peerId: "watch")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.contains("Dose changed") == true)
            #expect(rec.count(.delivering) == 0)  // never reached the backend
        }
    }

    @Test func carbRequestMissingEstimateFailsClosed() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel()
            await model.remoteDeliver(requestId: "d3", carbsGrams: 30, remoteEstimate: nil, peerId: "watch")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.contains("Missing dose estimate") == true)
            #expect(rec.count(.delivering) == 0)
        }
    }

    @Test func unitsRequestSkipsGuardAndDelivers() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel(connected: true)
            await model.remoteDeliver(requestId: "d4", units: 2.0, peerId: "watch")
            #expect(rec.last?.status == .delivered)
            #expect(abs((rec.last?.deliveredUnits ?? -1) - 2.0) < tol)
        }
    }

    // MARK: - GA-05: zero-carb (correction-only) carbs-mode requests aren't silently dropped

    /// A zero-carb carbs-mode request (a wrist BG correction) must route through the carb-recompute path,
    /// not the units path. With the phone's glucose stale it can't verify the correction, so it EXPLICITLY
    /// rejects (divergence) rather than mislabeling it "No insulin needed" — and the watch never hangs.
    @Test func zeroCarbCorrectionRoutesThroughCarbPathAndRejectsWhenStale() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel(connected: true)  // mock glucose is stale (no date)
            await model.remoteDeliver(requestId: "z1", carbsGrams: 0, remoteEstimate: 1.5, peerId: "watch")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.contains("Dose changed") == true)  // carb path, NOT "No insulin needed"
            #expect(rec.count(.delivering) == 0)
        }
    }

    /// With a FRESH high BG the same correction-only request succeeds end-to-end (the wrist estimate
    /// matches the host recompute), proving the fix isn't just "always reject".
    @Test func zeroCarbCorrectionDeliversWithFreshBG() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            backend.seedFreshGlucose(260)  // fresh, high → a real correction
            let dose = await model.recommendBolus(carbsGrams: 0, bgMgdl: 260).recommendedUnits
            #expect(dose > 0)  // sanity: a real correction
            await model.remoteDeliver(requestId: "z2", carbsGrams: 0, remoteEstimate: dose, peerId: "watch")
            #expect(rec.last?.status == .delivered)
        }
    }

    // MARK: - Freeze before approve (C-02)

    @Test func presentFreezesRealUnitsNotZero() async {
        try? await withCleanSettings {
            let (model, _, _) = await makeModel()
            let dose = await model.recommendBolus(carbsGrams: 45, bgMgdl: nil).recommendedUnits
            #expect(dose > 0)  // sanity: 45 g must resolve to a nonzero dose
            // A carb request carries NO units (the classic C-02 "confirm 0.00 U" shape).
            await model.presentRemoteBolus(
                requestId: "f1", units: 0, carbsGrams: 45,
                remoteEstimate: dose, peerId: "watch")
            let pending = model.pendingRemoteBolus
            #expect(pending != nil)
            #expect((pending?.units ?? 0) > 0)  // never the requested 0
            #expect(abs((pending?.units ?? -1) - dose) < tol)  // the real frozen dose
            #expect(pending?.carbsGrams == 45)
        }
    }

    @Test func confirmDeliversFrozenDose() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel(connected: true)
            let dose = await model.recommendBolus(carbsGrams: 45, bgMgdl: nil).recommendedUnits
            await model.presentRemoteBolus(
                requestId: "f2", units: 0, carbsGrams: 45,
                remoteEstimate: dose, peerId: "watch")
            await model.confirmRemoteBolus()
            #expect(model.pendingRemoteBolus == nil)
            #expect(rec.last?.status == .delivered)
            #expect(abs((rec.last?.deliveredUnits ?? -1) - dose) < tol)
        }
    }

    @Test func presentMissingEstimateSetsNoPending() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel()
            await model.presentRemoteBolus(
                requestId: "f3", units: 0, carbsGrams: 30,
                remoteEstimate: nil, peerId: "watch")
            #expect(model.pendingRemoteBolus == nil)
            #expect(rec.last?.status == .failed)
        }
    }

    @Test func rejectClearsPendingAndEchoesCancelled() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel()
            let dose = await model.recommendBolus(carbsGrams: 30, bgMgdl: nil).recommendedUnits
            await model.presentRemoteBolus(
                requestId: "f4", units: 0, carbsGrams: 30,
                remoteEstimate: dose, peerId: "watch")
            #expect(model.pendingRemoteBolus != nil)
            model.rejectRemoteBolus()
            #expect(model.pendingRemoteBolus == nil)
            #expect(rec.last?.status == .cancelled)
        }
    }

    // MARK: - Action gates
    //
    // AccessPolicy still blocks when `childModeEnabled` is true (faBolusCore `AccessPolicyTests`);
    // the app-layer setter is frozen false, so this suite does not flip it.

    /// A FAILED / BLOCKED delivery posts exactly one `.bolusDeliveryFailed` so a user who isn't
    /// watching learns the dose did not happen. An indeterminate outcome posts `.bolusIndeterminate`
    /// instead — never `.bolusDeliveryFailed`, because the dose may have landed.
    @Test func indeterminatePostsGovernedNotificationNotFailed() async {
        try? await withCleanSettings {
            // FAILED: not connected → a determinate `.notConnected` throw → outcome `.failed`.
            let (m1, _, _) = await makeModel(connected: false)
            var posted1: [NotificationBroker.Message] = []
            m1.notificationSink = { msg, _, _ in posted1.append(msg) }
            let r1 = await m1.deliverWidgetBolus(requestId: "df-fail", units: 1.0)
            #expect(r1.error != nil)
            let failed = posted1.filter { $0.category == .bolusDeliveryFailed }
            #expect(failed.count == 1)
            #expect(failed.first?.title == "Bolus not delivered")

            // INDETERMINATE: sent but outcome unknown → exactly ONE governed `.bolusIndeterminate` heads-up,
            // and STILL zero delivery-FAILED notifications (op-result + governed-heads-up only).
            let (m2, backend2, _) = await makeModel(connected: true)
            backend2.forceIndeterminateNextDelivery = true
            var posted2: [NotificationBroker.Message] = []
            m2.notificationSink = { msg, _, _ in posted2.append(msg) }
            let r2 = await m2.deliverWidgetBolus(requestId: "df-indet", units: 1.0)
            #expect(r2.error != nil)  // "verify on the pump"
            #expect(
                posted2.filter { $0.category == .bolusIndeterminate }.count == 1,
                "an indeterminate outcome must post exactly one governed .bolusIndeterminate heads-up")
            #expect(
                posted2.allSatisfy { $0.category != .bolusDeliveryFailed },
                "an indeterminate outcome must never post a delivery-FAILED notification")
        }
    }

    /// The local Quick-Bolus widget must honor phone read-only (AccessPolicy).
    @Test func readOnlyBlocksWidgetBolus() async {
        try? await withCleanSettings {
            let (model, _, _) = await makeModel(connected: true)
            AppSettings.shared.phoneReadOnly = true
            let w = await model.deliverWidgetBolus(requestId: "g3", units: 1.0)
            #expect(w.delivered == 0)
            #expect(w.error?.lowercased().contains("read-only") == true)
        }
    }

    // MARK: - AccessPolicy surface × action matrix

    /// `AppModel.accessDecision` builds context from live app/pump state and every gated
    /// entry point defers to the one AccessPolicy evaluator. This pins that wiring, including
    /// fail-closed.
    @Test func surfaceActionMatrixRoutesThroughTheEvaluator() async {
        try? await withCleanSettings {
            let (model, _, _) = await makeModel(connected: true)
            typealias S = AccessPolicy.Surface
            let remotes: [S] = [.garmin]

            // `remotesReadOnly` governs every remote. A delivery is refused on every remote surface;
            // the phone (local) is untouched.
            AppSettings.shared.remotesReadOnly = true
            for s in remotes {
                #expect(
                    model.accessDecision(.deliverBolus, from: s, peerId: "mac").reason == .remotesReadOnly,
                    "deliverBolus on \(s.rawValue) must be remotesReadOnly-blocked (owner decision)")
            }
            #expect(
                model.accessDecision(.deliverBolus, from: .phoneUI).allowed,
                "the phone's own bolus is governed by phoneReadOnly, not remotesReadOnly")
            // …but cancel + dismiss are `.childOnly` — a safety STOP / low-risk clear survives read-only
            // on every remote surface (never read-only-blocked).
            for s in remotes {
                #expect(
                    model.accessDecision(.cancelBolus, from: s, peerId: "mac").allowed,
                    "cancel (safety STOP) must survive remotesReadOnly on \(s.rawValue)")
                #expect(
                    model.accessDecision(.dismissNotification, from: s, peerId: "mac").allowed,
                    "dismiss must survive remotesReadOnly on \(s.rawValue)")
            }

            // AccessPolicy still fail-closes child mode in faBolusCore; the app-layer setter is frozen
            // false, so this suite does not flip it.
        }
    }

    // P8 approved-behavior pins (added after the pre-merge adversarial review flagged these three
    // intended changes as having no direct test — each one is exactly the kind of subtle gate most
    // likely to regress silently later).

    /// Behavior change (3): the phone-local `readOnlyAllowAlertClear` sub-option governs the phone's OWN
    /// alert-dismiss under read-only, but must NOT gate a remote (Garmin) dismiss — dismiss is
    /// `.childOnly`, so on a remote it is child-gated only, not subject to this local-phone setting.
    @Test func readOnlyAllowAlertClearGovernsLocalDismissOnly() async {
        let block = "Clearing alerts is disabled in read-only mode."
        // (a) local phone, read-only, opt-in OFF → blocked by the setting.
        try? await withCleanSettings {
            let (m, _, _) = await makeModel(connected: true)
            AppSettings.shared.phoneReadOnly = true
            await m.dismissAlert(id: 1, kind: 1, from: .phoneUI)
            #expect(m.lastError == block)
        }
        // (b) local phone, read-only, opt-in ON → not blocked by the setting.
        try? await withCleanSettings {
            let (m, _, _) = await makeModel(connected: true)
            AppSettings.shared.phoneReadOnly = true
            AppSettings.shared.readOnlyAllowAlertClear = true
            await m.dismissAlert(id: 1, kind: 1, from: .phoneUI)
            #expect(m.lastError != block)
        }
        // (c) remote (Garmin), read-only, opt-in OFF → the local-only setting does NOT apply.
        try? await withCleanSettings {
            let (m, _, _) = await makeModel(connected: true)
            AppSettings.shared.phoneReadOnly = true
            await m.dismissAlert(id: 1, kind: 1, from: .garmin, peerId: "garmin")
            #expect(m.lastError != block)
        }
    }

    // MARK: - Idempotency wiring (A-02)

    @Test func duplicateRequestHitsBackendOnce() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            let iob0 = backend.snapshot.iobUnits
            await model.remoteDeliver(requestId: "i1", units: 1.0, peerId: "watch")
            let iobAfterFirst = backend.snapshot.iobUnits
            await model.remoteDeliver(requestId: "i1", units: 1.0, peerId: "watch")  // exact duplicate
            let iobAfterReplay = backend.snapshot.iobUnits
            // MockBackend adds `units` to IOB on each real delivery; a replay must not deliver again.
            #expect(iobAfterFirst > iob0 + 0.9)  // first delivery happened
            #expect(abs(iobAfterReplay - iobAfterFirst) < 0.05)  // replay did NOT deliver
            #expect(rec.count(.delivering) == 1)  // backend touched exactly once
            #expect(rec.last?.status == .delivered)  // replay re-echoes the terminal result
        }
    }

    @Test func sameIdDifferentDoseFailsClosed() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel(connected: true)
            await model.remoteDeliver(requestId: "i2", units: 1.0, peerId: "watch")  // delivers
            #expect(rec.last?.status == .delivered)
            await model.remoteDeliver(requestId: "i2", units: 2.0, peerId: "watch")  // same id, different dose
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.lowercased().contains("different dose") == true)
        }
    }

    // MARK: - FB-01: unverified pump settings fail closed on a remote

    @Test func remoteCarbWithUnverifiedInputsFailsClosed() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            backend.forceUnverifiedInputs = true
            let iob0 = backend.snapshot.iobUnits
            // Provide a matching estimate so ONLY the verification gate can reject it (not divergence).
            let dose = await model.recommendBolus(carbsGrams: 30, bgMgdl: nil).recommendedUnits
            await model.remoteDeliver(requestId: "u1", carbsGrams: 30, remoteEstimate: dose, peerId: "watch")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.lowercased().contains("not verified") == true)
            #expect(rec.count(.delivering) == 0)  // never reached the backend
            #expect(abs(backend.snapshot.iobUnits - iob0) < tol)  // nothing delivered
        }
    }

    // MARK: - FB-02: indeterminate outcome is not a failure and blocks a retry

    @Test func indeterminateOutcomeReportsUnknownAndBlocksRetry() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            backend.forceIndeterminateNextDelivery = true
            await model.remoteDeliver(requestId: "x1", units: 2.0, peerId: "watch")
            #expect(rec.last?.status == .unknown)  // NOT .failed
            #expect(rec.count(.delivered) == 0)
            let deliveringAfterFirst = rec.count(.delivering)
            // A retry of the SAME request must not re-deliver (ledger is indeterminate, not terminal).
            await model.remoteDeliver(requestId: "x1", units: 2.0, peerId: "watch")
            #expect(rec.count(.delivering) == deliveringAfterFirst)  // no new delivery attempt
            #expect(rec.count(.delivered) == 0)  // still never delivered
        }
    }

    // MARK: - FB-03: the durable ledger blocks a duplicate across a simulated relaunch

    @Test func durableLedgerBlocksDuplicateAcrossRelaunch() async {
        try? await withCleanSettings {
            // Two AppModels sharing ONE ledger file = the same install across a relaunch.
            let sharedURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("shared-ledger-\(UUID().uuidString).json")
            let backend1 = MockBackend()
            await backend1.connect()
            let model1 = AppModel(source: backend1, ledgerStoreURL: sharedURL)
            let rec1 = EchoRecorder()
            rec1.attach(to: model1)
            await model1.remoteDeliver(requestId: "dur1", units: 1.5, peerId: "watch")
            #expect(rec1.last?.status == .delivered)

            // "Relaunch": a fresh model loads the persisted ledger and must NOT re-deliver dur1.
            let backend2 = MockBackend()
            await backend2.connect()
            let iob0 = backend2.snapshot.iobUnits
            let model2 = AppModel(source: backend2, ledgerStoreURL: sharedURL)
            let rec2 = EchoRecorder()
            rec2.attach(to: model2)
            await model2.remoteDeliver(requestId: "dur1", units: 1.5, peerId: "watch")
            #expect(rec2.count(.delivering) == 0)  // no second delivery after relaunch
            #expect(abs(backend2.snapshot.iobUnits - iob0) < tol)  // backend2 untouched
        }
    }

    // MARK: - FB-04: the FROZEN calculator IOB is delivered, never a later live snapshot

    /// A carb dose freezes the IOB it was computed against at approval time; if the live IOB then moves
    /// before the user confirms, the delivery must still send the FROZEN value (the approved inputs), not
    /// the live one. Verified by spying the exact metadata the backend received.
    @Test func frozenIobIsDeliveredNotLiveIob() async {
        try? await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            backend.setLiveIob(2.0)  // IOB at approval time
            // Glucose is stale in the mock → carbs-only dose 30/10 = 3.0 U (IOB doesn't move a carbs-only
            // dose), so the estimate 3.0 clears the divergence guard regardless of IOB.
            await model.presentRemoteBolus(
                requestId: "fb04", units: 0, carbsGrams: 30, remoteEstimate: 3.0, peerId: "watch")
            #expect(model.pendingRemoteBolus != nil)  // frozen + awaiting confirmation
            backend.setLiveIob(0.1)  // live IOB drops AFTER the freeze
            await model.confirmRemoteBolus()
            #expect(backend.lastDeliver?.iob == 2.0)  // delivered the FROZEN IOB, not live 0.1
            #expect(backend.lastDeliver?.carbs == 30)
        }
    }

    /// A zero frozen IOB is delivered as 0 (not a later nonzero live value).
    @Test func zeroFrozenIobIsDeliveredAsZero() async {
        try? await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            backend.setLiveIob(0.0)
            await model.presentRemoteBolus(
                requestId: "fb04z", units: 0, carbsGrams: 30, remoteEstimate: 3.0, peerId: "watch")
            backend.setLiveIob(5.0)
            await model.confirmRemoteBolus()
            #expect(backend.lastDeliver?.iob == 0.0)
        }
    }

    // MARK: - P0: durable GLOBAL unresolved-delivery block + bolus-id reconciliation

    /// After an indeterminate outcome the durable stale block that used to prevent a subsequent
    /// same-session delivery is gone — the owner-decided narrow removal. The unresolved dose is surfaced
    /// as the non-blocking inline disclosure instead. (MockBackend has no in-session unknown-outcome
    /// layer; that layer — which STILL refuses the next attempt on real hardware — is covered by
    /// TandemDeliveryOutcomeTests. The across-restart disclosure of a loaded-from-disk unresolved entry is
    /// covered by `idBearingDeliveringEntryStaysDisclosedWhenUnavailable` and
    /// `relaunchAfterIndeterminateIsNoLongerDurablyBlocked`.) The residual is accepted only because
    /// real-insulin is NO-GO.
    @Test func indeterminateNoLongerDurablyBlocksTheSameSession() async {
        try? await withCleanSettings {
            let sharedURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("p0-block-\(UUID().uuidString).json")
            let backend = MockBackend()
            await backend.connect()
            let model = AppModel(source: backend, ledgerStoreURL: sharedURL)
            let rec = EchoRecorder()
            rec.attach(to: model)
            backend.forceIndeterminateNextDelivery = true
            await model.remoteDeliver(requestId: "p0a", units: 2.0, peerId: "watch")
            #expect(rec.last?.status == .unknown)
            #expect(backend.lastAssignedBolusId != nil)  // id was persisted before initiate
            // The durable stale block is gone: an indeterminate outcome no longer GLOBALLY blocks
            // delivery; the unresolved dose is surfaced as the non-blocking inline disclosure instead.
            // (The relaunch/residual — a subsequent delivery now proceeds — is covered by
            // `relaunchAfterIndeterminateIsNoLongerDurablyBlocked`.)
            #expect(!model.deliveryGloballyBlocked)
            #expect(model.unconfirmedDeliveryDisclosure != nil)
        }
    }

    /// On reconnect, an authoritative pump match by bolus id settles the entry and releases the global
    /// block — after which delivery resumes normally.
    @Test func reconciliationByBolusIdReleasesBlock() async {
        try? await withCleanSettings {
            let sharedURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("p0-recon-\(UUID().uuidString).json")
            let backend1 = MockBackend()
            await backend1.connect()
            let model1 = AppModel(source: backend1, ledgerStoreURL: sharedURL)
            backend1.forceIndeterminateNextDelivery = true
            await model1.remoteDeliver(requestId: "p0c", units: 2.0, peerId: "watch")
            let id = backend1.lastAssignedBolusId!
            #expect(model1.unconfirmedDeliveryDisclosure != nil)  // unresolved ⇒ disclosed inline, not durably blocked

            // Relaunch + the pump now reports that exact bolus id as delivered.
            let backend2 = MockBackend()
            await backend2.connect()
            backend2.reconcileResultsById[id] = .resolved(deliveredUnits: 2.0, cancelled: false)
            let model2 = AppModel(source: backend2, ledgerStoreURL: sharedURL)
            let rec2 = EchoRecorder()
            rec2.attach(to: model2)
            await model2.reconcileUnresolvedDeliveries()
            #expect(!model2.deliveryGloballyBlocked)  // authoritative match released it

            // Delivery works again.
            await model2.remoteDeliver(requestId: "p0d", units: 1.0, peerId: "watch")
            #expect(rec2.last?.status == .delivered)
        }
    }

    /// The fresh-connect reconcile trigger fires on a non-empty unreconciled set even though the entry no
    /// longer sets a delivery block (deliveryBlockedReason == nil). It is re-based off the block reason
    /// onto the unreconciled set so the automation that JUSTIFIES dropping the durable stale block does
    /// not silently stop for exactly the case it exists to resolve.
    @Test func freshConnectReconcileTriggerFiresOnUnreconciledSetWithNoBlock() async throws {
        try await withCleanSettings {
            let sharedURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("fresh-connect-\(UUID().uuidString).json")
            // A genuinely-unresolved id-bearing entry (no fault, no in-flight): it discloses but sets NO
            // delivery block.
            var ledger = RemoteBolusLedger()
            _ = ledger.begin(peerId: "watch", requestId: "fc1", doseKey: "u:2")
            ledger.markDelivering(peerId: "watch", requestId: "fc1", bolusId: 8888)
            try RemoteBolusLedgerStore(url: sharedURL).save(ledger)

            // Backend starts DISCONNECTED with an EMPTY reconcile map, so the at-launch reconcile leaves
            // the entry unresolved (unavailable). Awaited so the map is empty during that pass.
            let backend = MockBackend()
            let model = AppModel(source: backend, ledgerStoreURL: sharedURL)
            await model.reconcileUnresolvedDeliveries()
            #expect(model.deliveryBlockedReason == nil)  // genuinely-unresolved ⇒ no durable block
            #expect(model.unconfirmedDeliveryDisclosure != nil)  // …but disclosed inline

            // The pump can now resolve id 8888; a fresh connect edge must fire the re-based trigger.
            backend.reconcileResultsById[8888] = .resolved(deliveredUnits: 2.0, cancelled: false)
            await backend.connect()  // onChange → refresh() → connect-edge trigger on the unreconciled set
            try? await Task.sleep(nanoseconds: 200_000_000)
            // Trigger fired ⇒ the entry reconciled ⇒ the disclosure cleared, with the block reason nil throughout.
            #expect(model.unconfirmedDeliveryDisclosure == nil)
            #expect(model.deliveryBlockedReason == nil)
        }
    }

    /// A `delivering` record with NO pump bolus id means the pump never granted permission (nothing was
    /// delivered), so reconciliation safely auto-clears it rather than blocking delivery forever.
    @Test func noBolusIdEntryAutoClearsOnReconcile() async throws {
        try await withCleanSettings {
            let sharedURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("p0-noid-\(UUID().uuidString).json")
            // Hand-craft a persisted ledger with an interrupted (no-id) delivering entry.
            var ledger = RemoteBolusLedger()
            _ = ledger.begin(peerId: "local", requestId: "crashed1", doseKey: "u:1")
            ledger.markDelivering(peerId: "local", requestId: "crashed1")  // no bolus id
            try RemoteBolusLedgerStore(url: sharedURL).save(ledger)

            let backend = MockBackend()
            await backend.connect()
            let model = AppModel(source: backend, ledgerStoreURL: sharedURL)
            #expect(!model.deliveryGloballyBlocked)  // a genuinely-unresolved entry no longer durably blocks
            await model.reconcileUnresolvedDeliveries()
            #expect(!model.deliveryGloballyBlocked)  // no-id ⇒ never sent ⇒ cleared
        }
    }

    /// A `delivering` record WITH a bolus id stays UNRESOLVED until the pump confirms it; an unavailable
    /// reconcile keeps it disclosed inline (verify on the pump) — no longer a durable delivery block.
    @Test func idBearingDeliveringEntryStaysDisclosedWhenUnavailable() async throws {
        try await withCleanSettings {
            let sharedURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("p0-idblock-\(UUID().uuidString).json")
            var ledger = RemoteBolusLedger()
            _ = ledger.begin(peerId: "watch", requestId: "sent1", doseKey: "u:2")
            ledger.markDelivering(peerId: "watch", requestId: "sent1", bolusId: 7777)
            try RemoteBolusLedgerStore(url: sharedURL).save(ledger)

            let backend = MockBackend()
            await backend.connect()  // no reconcileResultsById[7777] ⇒ unavailable
            let model = AppModel(source: backend, ledgerStoreURL: sharedURL)
            await model.reconcileUnresolvedDeliveries()
            #expect(!model.deliveryGloballyBlocked)  // no longer a durable block…
            #expect(model.unconfirmedDeliveryDisclosure != nil)  // …but stays disclosed; outcome unknown
        }
    }

    /// A corrupt/unreadable durable ledger fails CLOSED: delivery is blocked until the user verifies and
    /// explicitly clears the lock.
    @Test func corruptLedgerFailsClosedThenManualClearRecovers() async {
        try? await withCleanSettings {
            let sharedURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("p0-corrupt-\(UUID().uuidString).json")
            try? Data("{ this is not valid ledger json".utf8).write(to: sharedURL)

            let backend = MockBackend()
            await backend.connect()
            let model = AppModel(source: backend, ledgerStoreURL: sharedURL)
            #expect(model.deliveryGloballyBlocked)  // fail closed on corruption

            let iob0 = backend.snapshot.iobUnits
            await model.deliverBolus(units: 1.0)
            #expect(abs(backend.snapshot.iobUnits - iob0) < tol)  // no delivery while locked

            model.clearDeliveryBlockAfterVerification()
            #expect(!model.deliveryGloballyBlocked)
            await model.deliverBolus(units: 1.0)
            #expect(backend.snapshot.iobUnits > iob0)  // delivery resumes after clear
        }
    }

    /// Across a restart, an indeterminate first attempt no longer durably blocks a relaunch attempt — the
    /// accepted residual (no durable same-pump crash/relaunch interlock) under real-insulin NO-GO. The
    /// unresolved prior dose is disclosed inline instead of gating the relaunch delivery.
    @Test func relaunchAfterIndeterminateIsNoLongerDurablyBlocked() async {
        try? await withCleanSettings {
            let sharedURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("p0-once-\(UUID().uuidString).json")
            let backend1 = MockBackend()
            await backend1.connect()
            let model1 = AppModel(source: backend1, ledgerStoreURL: sharedURL)
            backend1.forceIndeterminateNextDelivery = true
            await model1.remoteDeliver(requestId: "once1", units: 2.0, peerId: "watch")
            #expect(backend1.lastAssignedBolusId != nil)  // one initiate attempt on backend1

            let backend2 = MockBackend()
            await backend2.connect()
            let model2 = AppModel(source: backend2, ledgerStoreURL: sharedURL)
            await model2.reconcileUnresolvedDeliveries()
            #expect(model2.unconfirmedDeliveryDisclosure != nil)  // prior dose still unresolved ⇒ disclosed
            await model2.remoteDeliver(requestId: "once2", units: 2.0, peerId: "watch")
            #expect(backend2.lastAssignedBolusId != nil)  // no durable interlock ⇒ relaunch delivery proceeds
        }
    }

    // MARK: - A remote request COMPOSED before a completed host delivery is refused
    //
    // `remoteDeliver(..., sentAt:)` carries the remote's compose-time wall clock. On a remote surface, if a
    // host bolus has since DELIVERED (stamping `lastHostDeliveryAt`), a request whose `sentAt` predates that
    // stamp dosed off pre-bolus state — a double-dose hazard — so it is refused BEFORE the backend, echoing
    // `.failed` with the "delivered after this request was created" message. Defense-in-depth over the
    // transport-layer `sentAt` freshness gate (which `remoteDeliver` bypasses when called directly, so
    // a future `sentAt` here is fine — the compose guard is the only `sentAt` check on this path).
    //
    // These use the `.garmin` surface so `surface.isRemote` is true (the divergence/idempotency tests above
    // all use the default `.phoneUI`, where the compose guard never fires). `.garmin` bolusing is a default-OFF
    // opt-in NOT managed by `withCleanSettings`, so it is enabled + restored locally.

    /// A remote request whose `sentAt` PREDATES a completed host delivery is refused, `lastError` carries the
    /// reason, and the backend delivers no second bolus (the request never reaches `executeResolved`).
    @Test func remoteRequestSupersededByHostDeliveryIsRejected() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            let savedGarmin = AppSettings.shared.garminBolusEnabled
            AppSettings.shared.garminBolusEnabled = true  // §2.3: opt in the Garmin surface
            defer { AppSettings.shared.garminBolusEnabled = savedGarmin }

            // A prior host delivery stamps `lastHostDeliveryAt = Date()` (local path emits no `.delivering`).
            let iob0 = backend.snapshot.iobUnits
            await model.deliverBolus(units: 1.0)
            let iobAfterHost = backend.snapshot.iobUnits
            #expect(iobAfterHost > iob0 + 0.9)  // the host bolus really delivered
            #expect(rec.count(.delivering) == 0)  // the local path never echoes .delivering

            // A remote request COMPOSED 120 s ago (before that stamp) → superseded → refused pre-backend.
            await model.remoteDeliver(
                requestId: "r-old", units: 1.0,
                sentAt: Int(Date().timeIntervalSince1970) - 120,
                from: .garmin, peerId: "garmin")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.contains("delivered after this request was created") == true)
            #expect(model.lastError?.contains("delivered after this request was created") == true)
            #expect(rec.count(.delivering) == 0)  // the SECOND request never reached the backend
            #expect(abs(backend.snapshot.iobUnits - iobAfterHost) < tol)  // and delivered no second bolus
        }
    }

    /// The counterpart: with a prior host delivery stamped, a remote request whose `sentAt` is AFTER the
    /// stamp is NOT rejected by the compose guard — it proceeds to normal handling. Robust: the
    /// point is that the supersession message never fires.
    @Test func remoteRequestComposedAfterHostDeliveryProceeds() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            let savedGarmin = AppSettings.shared.garminBolusEnabled
            AppSettings.shared.garminBolusEnabled = true
            defer { AppSettings.shared.garminBolusEnabled = savedGarmin }

            let iob0 = backend.snapshot.iobUnits
            await model.deliverBolus(units: 1.0)  // stamps lastHostDeliveryAt = now
            #expect(backend.snapshot.iobUnits > iob0 + 0.9)

            // `sentAt` 120 s in the FUTURE (after the stamp) ⇒ compose guard does NOT fire. remoteDeliver is
            // called directly (bypasses the transport freshness gate), so a future stamp is fine here.
            await model.remoteDeliver(
                requestId: "r-new", units: 1.0,
                sentAt: Int(Date().timeIntervalSince1970) + 120,
                from: .garmin, peerId: "garmin")
            // The supersession message never appears on ANY echo …
            #expect(
                rec.commands.allSatisfy {
                    ($0.message?.contains("delivered after this request was created") ?? false) == false
                })
            // … and the request proceeds to a normal delivery instead.
            #expect(rec.last?.status == .delivered)
        }
    }

    // MARK: - A status reply correlates to the request it answers

    /// `statusCommand(includeHistory:replyingTo:)` stamps the incoming request's id onto the reply when
    /// `replyingTo` is non-nil (true correlation), and keeps a fresh UUID when it is nil (an unsolicited push).
    @Test func statusCommandEchoesReplyingToRequestId() async {
        try? await withCleanSettings {
            let (model, _, _) = await makeModel()
            #expect(model.statusCommand(includeHistory: true, replyingTo: "req-123").requestId == "req-123")
            #expect(model.statusCommand(includeHistory: true).requestId != "req-123")  // fresh id when not replying
        }
    }
}
