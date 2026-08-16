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
/// The `MockBackend` seeds a glucose value timestamped **10 minutes ago** — older than the 6-minute
/// stale threshold — so `isGlucoseStale` is true and a carb dose resolves off carbs-only
/// (`bgMgdl: nil`), deterministic given the seeded IOB. That is why these assertions can compare
/// against a probed `recommendBolus` value without flakiness. (It used to be stale because the mock
/// published no timestamp at all; that unknown-age state was the defect A1 reproducer, since a remote
/// could then stamp the reading with its own receive time and render it as fresh.)
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
    ///
    /// P8: `advancedControlEnabled` is set ON here as the baseline. Every advanced / IDP-CRUD write is
    /// reachable in the app ONLY behind `advancedControlAllowed` (opt-in + Mobi), and the funnel now
    /// enforces that pump-capability + opt-in gate too (owner decision 2026-08-05, defense-in-depth). The
    /// `MockBackend` is already a Mobi with `.mobiAdvanced` capabilities, so ON here reflects exactly the
    /// context the UI guarantees for these writes; without it the funnel would (correctly) refuse them
    /// with `.capabilityUnavailable`. A test that wants to prove the capability gate itself sets it false.
    private func withCleanSettings(_ body: () async throws -> Void) async rethrows {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled, allowed = s.childAllowed, adv = s.advancedControlEnabled
        let rro = s.remotesReadOnly, clr = s.readOnlyAllowAlertClear
        let mode = s.appMode
        s.phoneReadOnly = false; s.childModeEnabled = false; s.advancedControlEnabled = true
        s.remotesReadOnly = false; s.readOnlyAllowAlertClear = false
        // P14 S2: baseline Advanced so the mode gate is a no-op for every existing test; a mode test sets
        // it explicitly. Restored below.
        s.appMode = .advanced
        // P8: the evaluator's peer gate (Gate 4) reads `RemotePeerPolicyStore` (UserDefaults). Snapshot +
        // clear it so a peer grant set by one test can't leak into the next (the suite is serialized).
        let d = UserDefaults.standard
        let peerPolicies = d.data(forKey: "remotePeerPolicies"), peerQR = d.data(forKey: "remotePeerHighEntropy")
        d.removeObject(forKey: "remotePeerPolicies"); d.removeObject(forKey: "remotePeerHighEntropy")
        defer {
            s.phoneReadOnly = ro; s.childModeEnabled = child; s.childAllowed = allowed
            s.advancedControlEnabled = adv; s.remotesReadOnly = rro; s.readOnlyAllowAlertClear = clr
            s.appMode = mode
            d.set(peerPolicies, forKey: "remotePeerPolicies"); d.set(peerQR, forKey: "remotePeerHighEntropy")
        }
        try await body()
    }

    /// Grant a peer a QR-paired full-control policy (what a real Mac/caregiver has once paired via QR and
    /// granted control) so the evaluator's Gate 4 permits its writes. Cleared by `withCleanSettings`.
    private func grantFullControlPeer(_ clientId: String) {
        RemotePeerPolicyStore.setPairedViaQR(clientId, true)   // audit A-11: only QR peers may hold control
        RemotePeerPolicyStore.setPolicy(.fullControl, for: clientId)
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
            await model.remoteDeliver(requestId: "g1", units: 1.0, from: .appleWatch, peerId: "watch")
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

    /// §6 `lastError` Tier-2 — a FAILED / BLOCKED delivery posts exactly one `.bolusDeliveryFailed`, so a
    /// user who isn't watching the screen learns the dose did NOT happen; an INDETERMINATE outcome ("sent,
    /// outcome unknown") posts NONE — it may in fact have delivered, so a "failed" banner would be a lie,
    /// and its authoritative resolution belongs to the never-suppressible `.bolusReconciliation` poster.
    /// Driven through the widget path (a public delivery entry with no reverse-approval branch) that shares
    /// the one ledgered-delivery outcome mapping with every surface.
    @Test func failedDeliveryNotifiesButIndeterminateDoesNot() async {
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

            // INDETERMINATE: sent but outcome unknown → NO delivery-FAILED notification (op-result only).
            let (m2, backend2, _) = await makeModel(connected: true)
            backend2.forceIndeterminateNextDelivery = true
            var posted2: [NotificationBroker.Message] = []
            m2.notificationSink = { msg, _, _ in posted2.append(msg) }
            let r2 = await m2.deliverWidgetBolus(requestId: "df-indet", units: 1.0)
            #expect(r2.error != nil)   // "verify on the pump"
            #expect(posted2.allSatisfy { $0.category != .bolusDeliveryFailed },
                    "an indeterminate outcome must never post a delivery-FAILED notification")
        }
    }

    @Test func readOnlyBlocksWidgetButNotRemotePeer() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel(connected: true)
            grantFullControlPeer("mac")
            AppSettings.shared.phoneReadOnly = true
            // Local Quick-Bolus widget must honor phone read-only (A-05).
            let w = await model.deliverWidgetBolus(requestId: "g3", units: 1.0)
            #expect(w.delivered == 0)
            #expect(w.error?.lowercased().contains("read-only") == true)
            // A remote peer is a separate device — the PHONE's read-only (phoneReadOnly) must not block it.
            // (P8: peers are governed by `remotesReadOnly`, which is OFF here — see the matrix test for the
            // owner-decision case where remotesReadOnly=ON does block the peer.)
            await model.remoteDeliver(requestId: "g4", units: 1.0, from: .macPeer, peerId: "mac")
            #expect(rec.last?.status == .delivered)
        }
    }

    @Test func parentRemoteBypassesChildLock() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel(connected: true)
            grantFullControlPeer("mac")
            AppSettings.shared.childModeEnabled = true
            AppSettings.shared.childAllowed = []
            // An authorized parent remote delivers from the `.macPeer` surface → child mode is bypassed
            // (the authenticated peer already passed its per-peer policy).
            await model.remoteDeliver(requestId: "g5", units: 1.0, from: .macPeer, peerId: "mac")
            #expect(rec.last?.status == .delivered)
        }
    }

    // MARK: - P8: the (surface × action) gate matrix routes through the single evaluator

    /// The whole point of P8: `AppModel.accessDecision` builds the context from live app/pump/peer state
    /// and every gated entry point defers to the one `AccessPolicy` evaluator. This drives that real
    /// context-builder over the full surface × action grid and pins the two owner decisions + the
    /// fail-closed invariant. (The pure evaluator's own truth table is exhausted in faBolusCore's
    /// `AccessPolicyTests`; this proves the AppModel wiring feeds it correctly.)
    @Test func surfaceActionMatrixRoutesThroughTheEvaluator() async {
        try? await withCleanSettings {
            let (model, _, _) = await makeModel(connected: true)
            grantFullControlPeer("mac")
            typealias A = GatedPumpWrite
            typealias S = AccessPolicy.Surface
            let remotes: [S] = [.appleWatch, .garmin, .macPeer, .caregiverPhonePeer]

            // Owner decision 2026-08-05 — `remotesReadOnly` governs ALL remotes INCLUDING the Mac/
            // caregiver peer path (the hole this closes: the peer path never consulted it before). A
            // delivery is refused on every remote surface; the phone (local) is untouched.
            AppSettings.shared.remotesReadOnly = true
            for s in remotes {
                #expect(model.accessDecision(.deliverBolus, from: s, peerId: "mac").reason == .remotesReadOnly,
                        "deliverBolus on \(s.rawValue) must be remotesReadOnly-blocked (owner decision)")
            }
            #expect(model.accessDecision(.deliverBolus, from: .phoneUI).allowed,
                    "the phone's own bolus is governed by phoneReadOnly, not remotesReadOnly")
            // …but cancel + dismiss are `.childOnly` — a safety STOP / low-risk clear survives read-only
            // on every remote surface (never read-only-blocked).
            for s in remotes {
                #expect(model.accessDecision(.cancelBolus, from: s, peerId: "mac").allowed,
                        "cancel (safety STOP) must survive remotesReadOnly on \(s.rawValue)")
                #expect(model.accessDecision(.dismissNotification, from: s, peerId: "mac").allowed,
                        "dismiss must survive remotesReadOnly on \(s.rawValue)")
            }

            // Fail-closed: fully locked (child on with nothing allowed, both read-only flags on, advanced
            // off, the peer revoked) denies EVERY action on EVERY surface — no cell escapes.
            AppSettings.shared.childModeEnabled = true; AppSettings.shared.childAllowed = []
            AppSettings.shared.phoneReadOnly = true; AppSettings.shared.remotesReadOnly = true
            AppSettings.shared.advancedControlEnabled = false
            RemotePeerPolicyStore.remove("mac")
            for a in A.allCases {
                for s in S.allCases {
                    #expect(!model.accessDecision(a, from: s, peerId: "mac").allowed,
                            "\(a.rawValue) on \(s.rawValue) must be denied when fully locked")
                }
            }
        }
    }

    /// P14 S2: the mode axis flows through the SAME `AppModel.accessDecision` context-builder as every
    /// other gate — the load-bearing wiring (C13's "inert-change trap"). If the mode field were added to
    /// the evaluator but `accessDecision` didn't populate `modeContext`, the gate would be dead and this
    /// fails. Simple mode hides an advanced write on EVERY surface (incl. the remote list) while the core
    /// bolus stays available and safety STOPs survive; Advanced restores it.
    @Test func modeGateRoutesThroughAppModelWiring() async {
        try? await withCleanSettings {
            let (model, _, _) = await makeModel(connected: true)
            grantFullControlPeer("mac")
            typealias S = AccessPolicy.Surface
            AppSettings.shared.appMode = .simple
            // An advanced write is denied on every surface, through the real context-builder.
            for s in S.allCases {
                #expect(!model.accessDecision(.setTempBasal, from: s, peerId: "mac").allowed,
                        "setTempBasal must be denied in Simple on \(s.rawValue)")
            }
            // On a local surface (everything else open) the reason is specifically the mode gate.
            #expect(model.accessDecision(.setTempBasal, from: .phoneUI).reason == .modeDisallowed(required: .advanced))
            // Core bolus stays available on the phone; safety STOPs survive on every surface.
            #expect(model.accessDecision(.deliverBolus, from: .phoneUI).allowed)
            for s in S.allCases {
                #expect(model.accessDecision(.cancelBolus, from: s, peerId: "mac").allowed,
                        "cancel (safety STOP) must survive Simple mode on \(s.rawValue)")
            }
            // Advanced mode restores the advanced write (proves the wiring reads the live value, not a const).
            AppSettings.shared.appMode = .advanced
            #expect(model.accessDecision(.setTempBasal, from: .phoneUI).allowed)
        }
    }

    /// End-to-end proof of the owner-decision fix at the delivery funnel (not just the decision): a peer
    /// `remoteDeliver` is refused host-side under `remotesReadOnly`, and delivers once it is off. On the
    /// pre-P8 code the peer path ignored `remotesReadOnly` entirely, so the first half fails there.
    @Test func remotesReadOnlyBlocksPeerBolusEndToEnd() async {
        try? await withCleanSettings {
            let (model, _, rec) = await makeModel(connected: true)
            grantFullControlPeer("mac")
            AppSettings.shared.remotesReadOnly = true
            await model.remoteDeliver(requestId: "ro1", units: 1.0, from: .macPeer, peerId: "mac")
            // `.failed` (not `.delivering`/`.delivered`) proves the guard fired before any pump write.
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.lowercased().contains("read-only") == true)
            #expect(rec.count(.delivering) == 0, "the peer bolus must not start delivering under remotesReadOnly")
            AppSettings.shared.remotesReadOnly = false
            await model.remoteDeliver(requestId: "ro2", units: 1.0, from: .macPeer, peerId: "mac")
            #expect(rec.last?.status == .delivered)
        }
    }

    // P8 approved-behavior pins (added after the pre-merge adversarial review flagged these three
    // intended changes as having no direct test — each one is exactly the kind of subtle gate most
    // likely to regress silently later).

    /// Behavior change (3): the phone-local `readOnlyAllowAlertClear` sub-option governs the phone's OWN
    /// alert-dismiss under read-only, but must NOT gate a remote (watch/Garmin) dismiss — dismiss is
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
        // (c) remote (watch), read-only, opt-in OFF → the local-only setting does NOT apply.
        try? await withCleanSettings {
            let (m, _, _) = await makeModel(connected: true)
            AppSettings.shared.phoneReadOnly = true
            await m.dismissAlert(id: 1, kind: 1, from: .appleWatch, peerId: "watch")
            #expect(m.lastError != block)
        }
    }

    /// Behavior change (1): the pump-capability + advanced-control-opt-in gate is enforced AT THE FUNNEL
    /// (not only the UI). A control write is refused with `.capabilityUnavailable` when the opt-in is off
    /// — even on a Mobi with the capability — and allowed once it is on.
    @Test func controlWriteBlockedAtFunnelWhenAdvancedControlOptInOff() async {
        try? await withCleanSettings {
            let (m, _, _) = await makeModel(connected: true)   // MockBackend: Mobi + .mobiAdvanced
            AppSettings.shared.advancedControlEnabled = false
            #expect(m.accessDecision(.setTempBasal, from: .phoneUI).reason == .capabilityUnavailable)
            AppSettings.shared.advancedControlEnabled = true
            #expect(m.accessDecision(.setTempBasal, from: .phoneUI).allowed)
        }
    }

    /// Behavior change (4): `syncTimeToNow` is capability-gated (supportsTimeSync) but NOT opt-in-gated —
    /// reachable on a Mobi from Settings with advanced control OFF. Pinned AT THE FUNNEL (not just the
    /// enum flag): with the opt-in off it is allowed, while a genuine advanced control write is refused.
    @Test func syncTimeToNowIsNotOptInGatedAtFunnel() async {
        try? await withCleanSettings {
            let (m, _, _) = await makeModel(connected: true)
            AppSettings.shared.advancedControlEnabled = false
            #expect(m.accessDecision(.syncTimeToNow, from: .phoneUI).allowed)
            #expect(m.accessDecision(.setTempBasal, from: .phoneUI).reason == .capabilityUnavailable)
        }
    }

    /// P13c-4: the two INVERSE Control-IQ preconditions enforced AT THE FUNNEL (pre-flight), not left for
    /// the pump to silently reject. A mode change is refused while Control-IQ is OFF; a temp rate is
    /// refused while it's ON. Fails closed: `lastError` carries the plain reason and nothing reaches the
    /// backend write.
    @Test func inverseControlIQPreconditionsRefusedAtFunnel() async {
        try? await withCleanSettings {
            let (m, backend, _) = await makeModel(connected: true)   // MockBackend defaults Control-IQ ON
            AppSettings.shared.advancedControlEnabled = true

            // Temp rate while Control-IQ is ON → refused with the temp-rate reason.
            await m.setTempBasal(percent: 120, durationMinutes: 30)
            #expect(m.lastError == ControlIQPrecondition.tempRateBlockReason(controlIQEnabled: true))

            // Turn Control-IQ OFF (onChange → the model's cached snapshot updates synchronously).
            try? await backend.setControlIQ(enabled: false, weightLbs: 0, totalDailyInsulinUnits: 0)
            // A mode change is now refused with the mode reason, and the reported activity stays normal.
            await m.setSleepMode(true)
            #expect(m.lastError == ControlIQPrecondition.modeBlockReason(controlIQEnabled: false))
            #expect(backend.snapshot.controlIQMode == ControlIQActivity.normal.rawValue)
        }
    }

    #if FABOLUS_TEMPRATE_CIQ_EXPERIMENTAL
    /// D-02 (Phase 09.5, experimental-only): the CIQ-off precondition in `AppModel.setTempBasal` is
    /// compiled OUT under `FABOLUS_TEMPRATE_CIQ_EXPERIMENTAL`, so a temp rate while Control-IQ is ON
    /// reaches the backend instead of being refused pre-flight. This is the counterpart to
    /// `inverseControlIQPreconditionsRefusedAtFunnel` above (which pins the DEFAULT-build refusal and
    /// MUST stay unmodified) — this test pins the OVERTURNED behavior, compiled only in the experimental
    /// build (never in the default build or CI, which always builds with the flag off).
    @Test func inverseControlIQPreconditionOverturnedUnderExperimentalFlag() async {
        try? await withCleanSettings {
            let (m, backend, _) = await makeModel(connected: true)   // MockBackend defaults Control-IQ ON
            AppSettings.shared.advancedControlEnabled = true

            // Temp rate while Control-IQ is ON → the CIQ-off refusal does NOT fire; the write reaches
            // the backend funnel (MockBackend's write counter increments, lastError is not the
            // tempRateBlockReason value).
            await m.setTempBasal(percent: 120, durationMinutes: 30)
            #expect(m.lastError != ControlIQPrecondition.tempRateBlockReason(controlIQEnabled: true))
            #expect(backend.tempRateWriteCount == 1)
        }
    }
    #endif

    /// P14 S11 (§2.1(7)): the Control-IQ CONFIG compatibility pre-flight, AT THE FUNNEL.
    /// - A Mobi (remotely configurable) is NOT blocked — even though its `controllerVariant` is still
    ///   `.none` here (the MockBackend reads no feature bits, exactly like a real Mobi before `staticRead`
    ///   completes). This is the safety-critical "don't fail-block on an unread variant" case, proven
    ///   end-to-end: the write reaches the pump.
    /// - A t:slim (NOT remotely configurable) is refused pre-flight with the plain reason, and nothing
    ///   reaches the pump — even with an acknowledgment present, the compat check runs first.
    @Test func controlIQConfigCompatibilityRefusedAtFunnel() async {
        try? await withCleanSettings {
            let (m, backend, _) = await makeModel(connected: true)   // Mobi, .mobiAdvanced caps
            #expect(backend.snapshot.controllerVariant == .none)     // bits unread — must NOT block
            m.acknowledgeUnverifiedTherapy()
            await m.setControlIQ(enabled: false, weightLbs: 150, totalDailyInsulinUnits: 40)
            #expect(m.lastError == nil)
            #expect(backend.controlWriteCount == 1)                  // reached the pump
            #expect(backend.snapshot.controlIQEnabled == false)      // and applied

            // t:slim: not remotely configurable → refused before the funnel, nothing reaches the pump.
            let tslim = MockBackend(isMobi: false)
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("s11-\(UUID().uuidString).json")
            let mt = AppModel(source: tslim, ledgerStoreURL: url)
            await tslim.connect()
            mt.acknowledgeUnverifiedTherapy()   // present on purpose: the compat pre-flight still wins
            await mt.setControlIQ(enabled: true, weightLbs: 150, totalDailyInsulinUnits: 40)
            #expect(mt.lastError == ControlIQPrecondition.configBlockReason(
                supportsControlIQConfig: tslim.capabilities.supportsControlIQSettings,
                controllerVariant: tslim.snapshot.controllerVariant))
            #expect(tslim.controlWriteCount == 0)                    // never reached the pump
            #expect(mt.hasRecentUnverifiedAck)                       // ack NOT consumed (blocked before the funnel)
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

    // MARK: - FB-06 (completed): table-driven — EVERY therapy-write entry point is centrally gated

    /// Each consequential unverified-therapy write, invoked directly on `AppModel`, must: fail closed with
    /// no ack (backend untouched + error surfaced), run exactly once WITH an ack, and fail closed again on
    /// a second call (the one-shot ack was consumed). This is the complete IDP-CRUD + CGM-alert matrix the
    /// round-2 audit required — set-active/rename/delete-profile are included (they were bypassing the gate).
    @Test func everyTherapyWriteEntryPointIsCentrallyGated() async {
        // Each entry: the invocation + the MockBackend counter that increments when it REACHES the backend.
        // IDP CRUD uses `idpWriteCount`; the P14 S6 therapy-defining writes (Control-IQ / max bolus / max
        // basal) use `controlWriteCount`.
        let idp: @MainActor (MockBackend) -> Int = { $0.idpWriteCount }
        let ctl: @MainActor (MockBackend) -> Int = { $0.controlWriteCount }
        let entries: [(String, @MainActor (AppModel) async -> Void, @MainActor (MockBackend) -> Int)] = [
            ("createProfile",       { await $0.createProfile(name: "P", basalRateUnitsPerHour: 0.8, carbRatioGramsPerUnit: 10, isf: 40, targetBg: 110, insulinDurationMinutes: 300) }, idp),
            ("setActiveProfile",    { await $0.setActiveProfile(idpId: 1) }, idp),
            ("renameProfile",       { await $0.renameProfile(idpId: 1, name: "New") }, idp),
            ("deleteProfile",       { await $0.deleteProfile(idpId: 1) }, idp),
            ("addProfileSegment",   { await $0.addProfileSegment(idpId: 1, startTimeMinutes: 60, basalRateUnitsPerHour: 0.8, carbRatioGramsPerUnit: 10, isf: 40, targetBg: 110) }, idp),
            ("modifyProfileSegment",{ await $0.modifyProfileSegment(idpId: 1, segmentIndex: 0, startTimeMinutes: 0, basalRateUnitsPerHour: 0.8, carbRatioGramsPerUnit: 10, isf: 40, targetBg: 110) }, idp),
            ("deleteProfileSegment",{ await $0.deleteProfileSegment(idpId: 1, segmentIndex: 0) }, idp),
            ("setCgmHighLowAlert",  { await $0.setCgmHighLowAlert(alertType: 0, thresholdMgdl: 180, repeatMinutes: 0, enabled: true) }, idp),
            ("setControlIQ",        { await $0.setControlIQ(enabled: true, weightLbs: 150, totalDailyInsulinUnits: 40) }, ctl),
            ("setMaxBolus",         { await $0.setMaxBolus(units: 10) }, ctl),
            ("setMaxBasal",         { await $0.setMaxBasal(unitsPerHour: 3) }, ctl),
            ("setSleepSchedule",    { await $0.setSleepSchedule(slot: 0, enabled: true, activeDays: 1, startMinute: 1320, endMinute: 360) }, ctl),
        ]
        // R3-F / P14 S6: these entries must equal the declared ack-gated set EXACTLY — a new `.unverifiedAck`
        // case added to `GatedPumpWrite` (or one removed here) fails this, so the test and the authoritative
        // declared set that seeds P8 cannot silently drift apart.
        #expect(Set(entries.map(\.0)) == Set(GatedPumpWrite.allCases.filter { $0.gate == .unverifiedAck }.map(\.rawValue)))
        for (name, invoke, count) in entries {
            try? await withCleanSettings {
                let (model, backend, _) = await makeModel(connected: true)
                // (a) no ack → fail closed
                await invoke(model)
                #expect(count(backend) == 0, "\(name) reached the backend without an ack")
                #expect(model.lastError != nil, "\(name) did not surface a fail-closed error")
                // (b) with ack → exactly one write, ack consumed
                model.acknowledgeUnverifiedTherapy()
                await invoke(model)
                #expect(count(backend) == 1, "\(name) did not run once with an ack")
                #expect(!model.hasRecentUnverifiedAck, "\(name) left the one-shot ack un-consumed")
                // (c) second call without a fresh ack → fail closed again
                await invoke(model)
                #expect(count(backend) == 1, "\(name) ran a second time without a fresh ack")
            }
        }
    }

    // MARK: - FB-04: the FROZEN calculator IOB is delivered, never a later live snapshot

    /// A carb dose freezes the IOB it was computed against at approval time; if the live IOB then moves
    /// before the user confirms, the delivery must still send the FROZEN value (the approved inputs), not
    /// the live one. Verified by spying the exact metadata the backend received.
    @Test func frozenIobIsDeliveredNotLiveIob() async {
        try? await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            backend.setLiveIob(2.0)                          // IOB at approval time
            // Glucose is stale in the mock → carbs-only dose 30/10 = 3.0 U (IOB doesn't move a carbs-only
            // dose), so the estimate 3.0 clears the divergence guard regardless of IOB.
            await model.presentRemoteBolus(requestId: "fb04", units: 0, carbsGrams: 30, remoteEstimate: 3.0, peerId: "watch")
            #expect(model.pendingRemoteBolus != nil)         // frozen + awaiting confirmation
            backend.setLiveIob(0.1)                          // live IOB drops AFTER the freeze
            await model.confirmRemoteBolus()
            #expect(backend.lastDeliver?.iob == 2.0)         // delivered the FROZEN IOB, not live 0.1
            #expect(backend.lastDeliver?.carbs == 30)
        }
    }

    /// A zero frozen IOB is delivered as 0 (not a later nonzero live value).
    @Test func zeroFrozenIobIsDeliveredAsZero() async {
        try? await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            backend.setLiveIob(0.0)
            await model.presentRemoteBolus(requestId: "fb04z", units: 0, carbsGrams: 30, remoteEstimate: 3.0, peerId: "watch")
            backend.setLiveIob(5.0)
            await model.confirmRemoteBolus()
            #expect(backend.lastDeliver?.iob == 0.0)
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
