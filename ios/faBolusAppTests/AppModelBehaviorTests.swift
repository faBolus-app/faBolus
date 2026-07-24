import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// App-target behavioral e2e for the safety-critical remote-delivery decision logic (audit C-08).
///
/// These exercise the REAL `AppModel` against the in-memory `MockBackend`, so no pump/BLE hardware
/// is needed and they run on the Simulator. They cover the finding areas that live in `AppModel`:
///   • **Divergence guard** (C-06): host recomputes the authoritative carb dose and rejects when the
///     remote's own estimate diverges beyond `remoteDivergenceLimitUnits` (0.10 U), and fails closed
///     when the estimate is missing.
///   • **Freeze-before-approve** (C-02): a carb request with no units freezes the *real* dose before
///     prompting (never "0.00 U"), and confirm delivers that frozen number with no recompute.
///   • **Action gates** (A-05): child mode blocks every bolus surface; phone read-only blocks the
///     local Quick-Bolus widget but (by design) not an authenticated remote peer.
///   • **Idempotency wiring** (A-02): a duplicate (peer, requestId) hits the backend once; a same-id
///     request with a different dose fails closed.
///
/// The `MockBackend` seeds a glucose value with **no timestamp**, so `isGlucoseStale` is true and a
/// carb dose resolves off carbs-only (`bgMgdl: nil`) — deterministic, given the seeded IOB. That is
/// why these assertions can compare against a probed `recommendBolus` value without flakiness.
///
/// Not covered here (they need a fake CoreBluetooth transport for `TandemBackend`, not `AppModel`):
/// pump-transaction drop/timeout (A-03) and the glucose single-flight race (C-05) — still bench/mock
/// scoped per `docs/UNVERIFIED-GUESSES.md` and the remediation tracker.
@Suite(.serialized)
@MainActor
struct AppModelBehaviorTests {

    // MARK: - Test harness

    /// Captures every `RemoteCommand` the model echoes back to a remote, so a test can assert on the
    /// exact status sequence and messages the surface would see.
    @MainActor
    final class EchoRecorder {
        private(set) var commands: [RemoteCommand] = []
        func attach(to model: AppModel) { model.addRemoteEcho { [weak self] c in self?.commands.append(c) } }
        var last: RemoteCommand? { commands.last }
        var statuses: [RemoteCommand.Status] { commands.compactMap { $0.status } }
        func count(_ s: RemoteCommand.Status) -> Int { statuses.filter { $0 == s }.count }
    }

    /// A fresh model + backend + recorder. `connect()` only when the test needs delivery to succeed
    /// (rejections/gate blocks short-circuit before touching the backend).
    private func makeModel(connected: Bool = false) async -> (AppModel, MockBackend, EchoRecorder) {
        let backend = MockBackend()
        // FB-03: give each model its own durable-ledger file so the persisted ledger can't leak between
        // serialized tests (production shares one App Group file; tests must not).
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appmodel-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        let rec = EchoRecorder(); rec.attach(to: model)
        if connected { await backend.connect() }
        return (model, backend, rec)
    }

    /// Run `body` with the global `AppSettings` gates in a known-clean state, restoring them after so
    /// the serialized suite never leaks child/read-only state between tests.
    private func withCleanSettings(_ body: () async throws -> Void) async rethrows {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled, allowed = s.childAllowed
        s.phoneReadOnly = false; s.childModeEnabled = false
        defer { s.phoneReadOnly = ro; s.childModeEnabled = child; s.childAllowed = allowed }
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
            #expect(rec.count(.delivering) == 0)   // never reached the backend
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
            let (model, _, rec) = await makeModel(connected: true)   // mock glucose is stale (no date)
            await model.remoteDeliver(requestId: "z1", carbsGrams: 0, remoteEstimate: 1.5, peerId: "watch")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.contains("Dose changed") == true)   // carb path, NOT "No insulin needed"
            #expect(rec.count(.delivering) == 0)
        }
    }

    /// With a FRESH high BG the same correction-only request succeeds end-to-end (the wrist estimate
    /// matches the host recompute), proving the fix isn't just "always reject".
    @Test func zeroCarbCorrectionDeliversWithFreshBG() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            backend.seedFreshGlucose(260)   // fresh, high → a real correction
            let dose = await model.recommendBolus(carbsGrams: 0, bgMgdl: 260).recommendedUnits
            #expect(dose > 0)                                          // sanity: a real correction
            await model.remoteDeliver(requestId: "z2", carbsGrams: 0, remoteEstimate: dose, peerId: "watch")
            #expect(rec.last?.status == .delivered)
        }
    }

    // MARK: - Freeze before approve (C-02)

    @Test func presentFreezesRealUnitsNotZero() async {
        try? await withCleanSettings {
            let (model, _, _) = await makeModel()
            let dose = await model.recommendBolus(carbsGrams: 45, bgMgdl: nil).recommendedUnits
            #expect(dose > 0)   // sanity: 45 g must resolve to a nonzero dose
            // A carb request carries NO units (the classic C-02 "confirm 0.00 U" shape).
            await model.presentRemoteBolus(requestId: "f1", units: 0, carbsGrams: 45,
                                           remoteEstimate: dose, peerId: "watch")
            let pending = model.pendingRemoteBolus
            #expect(pending != nil)
            #expect((pending?.units ?? 0) > 0)                       // never the requested 0
            #expect(abs((pending?.units ?? -1) - dose) < tol)        // the real frozen dose
            #expect(pending?.carbsGrams == 45)
        }
    }

    @Test func confirmDeliversFrozenDose() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel(connected: true)
            let dose = await model.recommendBolus(carbsGrams: 45, bgMgdl: nil).recommendedUnits
            await model.presentRemoteBolus(requestId: "f2", units: 0, carbsGrams: 45,
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
            await model.presentRemoteBolus(requestId: "f3", units: 0, carbsGrams: 30,
                                           remoteEstimate: nil, peerId: "watch")
            #expect(model.pendingRemoteBolus == nil)
            #expect(rec.last?.status == .failed)
        }
    }

    @Test func rejectClearsPendingAndEchoesCancelled() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel()
            let dose = await model.recommendBolus(carbsGrams: 30, bgMgdl: nil).recommendedUnits
            await model.presentRemoteBolus(requestId: "f4", units: 0, carbsGrams: 30,
                                           remoteEstimate: dose, peerId: "watch")
            #expect(model.pendingRemoteBolus != nil)
            model.rejectRemoteBolus()
            #expect(model.pendingRemoteBolus == nil)
            #expect(rec.last?.status == .cancelled)
        }
    }

    /// Audit A-01: a pending host-approval bolus bound to a peer must not survive that peer's session
    /// teardown — and clearing one peer must not touch another's.
    @Test func clearPendingForPeerDropsOnlyThatPeer() async {
        try? await withCleanSettings {
            let (model, _, _) = await makeModel()
            let dose = await model.recommendBolus(carbsGrams: 30, bgMgdl: nil).recommendedUnits
            await model.presentRemoteBolus(requestId: "f5", units: 0, carbsGrams: 30,
                                           remoteEstimate: dose, peerId: "mac")
            model.clearPendingRemoteBolus(forPeer: "otherPhone")
            #expect(model.pendingRemoteBolus != nil)   // different peer → untouched
            model.clearPendingRemoteBolus(forPeer: "mac")
            #expect(model.pendingRemoteBolus == nil)    // bound peer → dropped
        }
    }

    // MARK: - Action gates (A-05)

    @Test func childModeBlocksRemoteBolus() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel()
            AppSettings.shared.childModeEnabled = true
            AppSettings.shared.childAllowed = []   // .bolus not permitted
            await model.remoteDeliver(requestId: "g1", units: 1.0, enforceChildLock: true, peerId: "watch")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.lowercased().contains("child mode") == true)
            #expect(rec.count(.delivering) == 0)
        }
    }

    @Test func childModeBlocksWidgetBolus() async {
        try? await withCleanSettings {
            let (model, _, _) = await makeModel()
            AppSettings.shared.childModeEnabled = true
            AppSettings.shared.childAllowed = []
            let r = await model.deliverWidgetBolus(requestId: "g2", units: 1.0)
            #expect(r.delivered == 0)
            #expect(r.error?.lowercased().contains("child mode") == true)
        }
    }

    @Test func readOnlyBlocksWidgetButNotRemotePeer() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel(connected: true)
            AppSettings.shared.phoneReadOnly = true
            // Local Quick-Bolus widget must honor phone read-only (A-05).
            let w = await model.deliverWidgetBolus(requestId: "g3", units: 1.0)
            #expect(w.delivered == 0)
            #expect(w.error?.lowercased().contains("read-only") == true)
            // A remote peer is a separate device — read-only on THIS phone must not block it (A-05, by design).
            await model.remoteDeliver(requestId: "g4", units: 1.0, enforceChildLock: false, peerId: "mac")
            #expect(rec.last?.status == .delivered)
        }
    }

    @Test func parentRemoteBypassesChildLock() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel(connected: true)
            AppSettings.shared.childModeEnabled = true
            AppSettings.shared.childAllowed = []
            // An authorized parent remote sends enforceChildLock: false → the child lock is bypassed.
            await model.remoteDeliver(requestId: "g5", units: 1.0, enforceChildLock: false, peerId: "mac")
            #expect(rec.last?.status == .delivered)
        }
    }

    // MARK: - Idempotency wiring (A-02)

    @Test func duplicateRequestHitsBackendOnce() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            let iob0 = backend.snapshot.iobUnits
            await model.remoteDeliver(requestId: "i1", units: 1.0, peerId: "watch")
            let iobAfterFirst = backend.snapshot.iobUnits
            await model.remoteDeliver(requestId: "i1", units: 1.0, peerId: "watch")   // exact duplicate
            let iobAfterReplay = backend.snapshot.iobUnits
            // MockBackend adds `units` to IOB on each real delivery; a replay must not deliver again.
            #expect(iobAfterFirst > iob0 + 0.9)                          // first delivery happened
            #expect(abs(iobAfterReplay - iobAfterFirst) < 0.05)          // replay did NOT deliver
            #expect(rec.count(.delivering) == 1)                          // backend touched exactly once
            #expect(rec.last?.status == .delivered)                       // replay re-echoes the terminal result
        }
    }

    @Test func sameIdDifferentDoseFailsClosed() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel(connected: true)
            await model.remoteDeliver(requestId: "i2", units: 1.0, peerId: "watch")   // delivers
            #expect(rec.last?.status == .delivered)
            await model.remoteDeliver(requestId: "i2", units: 2.0, peerId: "watch")   // same id, different dose
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
            #expect(rec.count(.delivering) == 0)                       // never reached the backend
            #expect(abs(backend.snapshot.iobUnits - iob0) < tol)       // nothing delivered
        }
    }

    // MARK: - FB-02: indeterminate outcome is not a failure and blocks a retry

    @Test func indeterminateOutcomeReportsUnknownAndBlocksRetry() async {
        try? await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            backend.forceIndeterminateNextDelivery = true
            await model.remoteDeliver(requestId: "x1", units: 2.0, peerId: "watch")
            #expect(rec.last?.status == .unknown)                      // NOT .failed
            #expect(rec.count(.delivered) == 0)
            let deliveringAfterFirst = rec.count(.delivering)
            // A retry of the SAME request must not re-deliver (ledger is indeterminate, not terminal).
            await model.remoteDeliver(requestId: "x1", units: 2.0, peerId: "watch")
            #expect(rec.count(.delivering) == deliveringAfterFirst)    // no new delivery attempt
            #expect(rec.count(.delivered) == 0)                        // still never delivered
        }
    }

    // MARK: - FB-03: the durable ledger blocks a duplicate across a simulated relaunch

    @Test func durableLedgerBlocksDuplicateAcrossRelaunch() async {
        try? await withCleanSettings {
            // Two AppModels sharing ONE ledger file = the same install across a relaunch.
            let sharedURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("shared-ledger-\(UUID().uuidString).json")
            let backend1 = MockBackend(); await backend1.connect()
            let model1 = AppModel(source: backend1, ledgerStoreURL: sharedURL)
            let rec1 = EchoRecorder(); rec1.attach(to: model1)
            await model1.remoteDeliver(requestId: "dur1", units: 1.5, peerId: "watch")
            #expect(rec1.last?.status == .delivered)

            // "Relaunch": a fresh model loads the persisted ledger and must NOT re-deliver dur1.
            let backend2 = MockBackend(); await backend2.connect()
            let iob0 = backend2.snapshot.iobUnits
            let model2 = AppModel(source: backend2, ledgerStoreURL: sharedURL)
            let rec2 = EchoRecorder(); rec2.attach(to: model2)
            await model2.remoteDeliver(requestId: "dur1", units: 1.5, peerId: "watch")
            #expect(rec2.count(.delivering) == 0)                      // no second delivery after relaunch
            #expect(abs(backend2.snapshot.iobUnits - iob0) < tol)      // backend2 untouched
        }
    }

    // MARK: - FB-06: central unverified-therapy gate (a new caller must fail closed unless acknowledged)

    /// An IDP write with NO prior acknowledgment is refused at the AppModel boundary: the backend is
    /// never touched and `lastError` explains why. This is the policy a *new* caller must satisfy — the
    /// gate no longer lives only on the individual UI buttons.
    @Test func unverifiedIdpWriteWithoutAckFailsClosed() async {
        try? await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            #expect(!model.hasRecentUnverifiedAck)
            await model.createProfile(name: "Test", basalRateUnitsPerHour: 0.8, carbRatioGramsPerUnit: 10,
                                      isf: 40, targetBg: 110, insulinDurationMinutes: 300)
            #expect(backend.idpWriteCount == 0)                        // backend never hit
            #expect(model.lastError != nil)                            // fail-closed reason surfaced
            #expect(model.snapshot.profiles.isEmpty)                   // and no profile appeared
        }
    }

    /// The same write proceeds after `acknowledgeUnverifiedTherapy()` (what `UnverifiedFeatureGate` /
    /// the restore confirmation call), and the one-shot ack is consumed so a *second* write fails closed.
    @Test func unverifiedIdpWriteWithAckProceedsThenReArms() async {
        try? await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            model.acknowledgeUnverifiedTherapy()
            #expect(model.hasRecentUnverifiedAck)
            await model.createProfile(name: "Test", basalRateUnitsPerHour: 0.8, carbRatioGramsPerUnit: 10,
                                      isf: 40, targetBg: 110, insulinDurationMinutes: 300)
            #expect(backend.idpWriteCount == 1)                        // reached the backend once
            #expect(model.lastError == nil)
            #expect(model.snapshot.profiles.count == 1)

            // One-shot: the ack was consumed, so the next write is refused again (no accidental repeat).
            #expect(!model.hasRecentUnverifiedAck)
            await model.createProfile(name: "Test2", basalRateUnitsPerHour: 0.8, carbRatioGramsPerUnit: 10,
                                      isf: 40, targetBg: 110, insulinDurationMinutes: 300)
            #expect(backend.idpWriteCount == 1)                        // still only the first write
            #expect(model.lastError != nil)
        }
    }

    /// Segment delete (the swipe action that previously bypassed the UI gate) and the CGM high/low alert
    /// are gated too — proving the boundary covers every consequential unverified-therapy write.
    @Test func segmentDeleteAndCgmAlertAreGated() async {
        try? await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            await model.deleteProfileSegment(idpId: 1, segmentIndex: 0)
            #expect(backend.idpWriteCount == 0)
            #expect(model.lastError != nil)

            await model.setCgmHighLowAlert(alertType: 0, thresholdMgdl: 180, repeatMinutes: 0, enabled: true)
            #expect(backend.idpWriteCount == 0)
            #expect(model.lastError != nil)

            // With an ack, the CGM alert write goes through.
            model.acknowledgeUnverifiedTherapy()
            await model.setCgmHighLowAlert(alertType: 0, thresholdMgdl: 180, repeatMinutes: 0, enabled: true)
            #expect(backend.idpWriteCount == 1)
            #expect(model.lastError == nil)
        }
    }

    // MARK: - P0: durable GLOBAL unresolved-delivery block + bolus-id reconciliation

    /// After an indeterminate outcome, EVERY delivery surface (a brand-new remote request AND a local
    /// bolus) is globally blocked — within the session AND across a simulated relaunch — until the prior
    /// bolus is reconciled against the pump. This is the P0 duplicate-insulin fix.
    @Test func indeterminateGloballyBlocksAllSurfacesAcrossRestart() async {
        try? await withCleanSettings {
            let sharedURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("p0-block-\(UUID().uuidString).json")
            let backend1 = MockBackend(); await backend1.connect()
            let model1 = AppModel(source: backend1, ledgerStoreURL: sharedURL)
            let rec1 = EchoRecorder(); rec1.attach(to: model1)
            backend1.forceIndeterminateNextDelivery = true
            await model1.remoteDeliver(requestId: "p0a", units: 2.0, peerId: "watch")
            #expect(rec1.last?.status == .unknown)
            #expect(model1.deliveryGloballyBlocked)                     // same-session block is up
            let assignedId = backend1.lastAssignedBolusId
            #expect(assignedId != nil)                                  // id was persisted before initiate

            // A DIFFERENT remote request is now refused (not just the same id).
            let iob1 = backend1.snapshot.iobUnits
            await model1.remoteDeliver(requestId: "p0b", units: 1.0, peerId: "watch")
            #expect(rec1.count(.delivered) == 0)
            #expect(abs(backend1.snapshot.iobUnits - iob1) < tol)       // nothing delivered

            // "Relaunch": a fresh model loads the durable ledger. The id-bearing record can't reconcile
            // (pump has no matching result), so the GLOBAL block must persist across the restart.
            let backend2 = MockBackend(); await backend2.connect()
            let model2 = AppModel(source: backend2, ledgerStoreURL: sharedURL)
            let rec2 = EchoRecorder(); rec2.attach(to: model2)
            await model2.reconcileUnresolvedDeliveries()               // deterministic (init also schedules it)
            #expect(model2.deliveryGloballyBlocked)                     // relaunch cannot erase the block

            // Local delivery after relaunch is blocked too.
            let iob2 = backend2.snapshot.iobUnits
            await model2.deliverBolus(units: 1.0)
            #expect(abs(backend2.snapshot.iobUnits - iob2) < tol)
            #expect(model2.lastError?.lowercased().contains("unconfirmed") == true)
        }
    }

    /// On reconnect, an authoritative pump match by bolus id settles the entry and releases the global
    /// block — after which delivery resumes normally.
    @Test func reconciliationByBolusIdReleasesBlock() async {
        try? await withCleanSettings {
            let sharedURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("p0-recon-\(UUID().uuidString).json")
            let backend1 = MockBackend(); await backend1.connect()
            let model1 = AppModel(source: backend1, ledgerStoreURL: sharedURL)
            backend1.forceIndeterminateNextDelivery = true
            await model1.remoteDeliver(requestId: "p0c", units: 2.0, peerId: "watch")
            let id = backend1.lastAssignedBolusId!
            #expect(model1.deliveryGloballyBlocked)

            // Relaunch + the pump now reports that exact bolus id as delivered.
            let backend2 = MockBackend(); await backend2.connect()
            backend2.reconcileResultsById[id] = .resolved(deliveredUnits: 2.0, cancelled: false)
            let model2 = AppModel(source: backend2, ledgerStoreURL: sharedURL)
            let rec2 = EchoRecorder(); rec2.attach(to: model2)
            await model2.reconcileUnresolvedDeliveries()
            #expect(!model2.deliveryGloballyBlocked)                    // authoritative match released it

            // Delivery works again.
            await model2.remoteDeliver(requestId: "p0d", units: 1.0, peerId: "watch")
            #expect(rec2.last?.status == .delivered)
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
            ledger.markDelivering(peerId: "local", requestId: "crashed1")   // no bolus id
            try RemoteBolusLedgerStore(url: sharedURL).save(ledger)

            let backend = MockBackend(); await backend.connect()
            let model = AppModel(source: backend, ledgerStoreURL: sharedURL)
            #expect(model.deliveryGloballyBlocked)                      // blocked on load (fail safe)
            await model.reconcileUnresolvedDeliveries()
            #expect(!model.deliveryGloballyBlocked)                     // no-id ⇒ never sent ⇒ cleared
        }
    }

    /// A `delivering` record WITH a bolus id stays blocked until the pump confirms it; an unavailable
    /// reconcile keeps the block (verify on the pump).
    @Test func idBearingDeliveringEntryStaysBlockedWhenUnavailable() async throws {
        try await withCleanSettings {
            let sharedURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("p0-idblock-\(UUID().uuidString).json")
            var ledger = RemoteBolusLedger()
            _ = ledger.begin(peerId: "watch", requestId: "sent1", doseKey: "u:2")
            ledger.markDelivering(peerId: "watch", requestId: "sent1", bolusId: 7777)
            try RemoteBolusLedgerStore(url: sharedURL).save(ledger)

            let backend = MockBackend(); await backend.connect()   // no reconcileResultsById[7777] ⇒ unavailable
            let model = AppModel(source: backend, ledgerStoreURL: sharedURL)
            await model.reconcileUnresolvedDeliveries()
            #expect(model.deliveryGloballyBlocked)                      // stays blocked; outcome unknown
        }
    }

    /// A corrupt/unreadable durable ledger fails CLOSED: delivery is blocked until the user verifies and
    /// explicitly clears the lock.
    @Test func corruptLedgerFailsClosedThenManualClearRecovers() async {
        try? await withCleanSettings {
            let sharedURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("p0-corrupt-\(UUID().uuidString).json")
            try? Data("{ this is not valid ledger json".utf8).write(to: sharedURL)

            let backend = MockBackend(); await backend.connect()
            let model = AppModel(source: backend, ledgerStoreURL: sharedURL)
            #expect(model.deliveryGloballyBlocked)                      // fail closed on corruption

            let iob0 = backend.snapshot.iobUnits
            await model.deliverBolus(units: 1.0)
            #expect(abs(backend.snapshot.iobUnits - iob0) < tol)        // no delivery while locked

            model.clearDeliveryBlockAfterVerification()
            #expect(!model.deliveryGloballyBlocked)
            await model.deliverBolus(units: 1.0)
            #expect(backend.snapshot.iobUnits > iob0)                   // delivery resumes after clear
        }
    }

    /// Exactly ONE initiate across a restart: an indeterminate first attempt + a blocked relaunch attempt
    /// must reach the backend's delivery entry exactly once.
    @Test func exactlyOneInitiateAcrossRestart() async {
        try? await withCleanSettings {
            let sharedURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("p0-once-\(UUID().uuidString).json")
            let backend1 = MockBackend(); await backend1.connect()
            let model1 = AppModel(source: backend1, ledgerStoreURL: sharedURL)
            backend1.forceIndeterminateNextDelivery = true
            await model1.remoteDeliver(requestId: "once1", units: 2.0, peerId: "watch")
            #expect(backend1.lastAssignedBolusId != nil)               // one initiate attempt on backend1

            let backend2 = MockBackend(); await backend2.connect()
            let model2 = AppModel(source: backend2, ledgerStoreURL: sharedURL)
            await model2.reconcileUnresolvedDeliveries()
            await model2.remoteDeliver(requestId: "once2", units: 2.0, peerId: "watch")
            #expect(backend2.lastAssignedBolusId == nil)               // blocked ⇒ backend2 never initiated
        }
    }
}
