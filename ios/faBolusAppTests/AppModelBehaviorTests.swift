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
}
