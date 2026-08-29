import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins that a remote `includeStaleBG` intent uses the host's own stale reading as the dose input only
/// when it matches the wire value; otherwise the host fails closed to carbs-only. The wire `bgMgdl` is never itself a dose input.
@Suite(.serialized)
@MainActor
struct StaleRemoteDoseHostTests {

    // MARK: - Test harness (mirrors AppModelBehaviorTests)

    @MainActor
    final class EchoRecorder {
        private(set) var commands: [RemoteCommand] = []
        func attach(to model: AppModel) { model.addRemoteEcho { [weak self] c in self?.commands.append(c) } }
        var last: RemoteCommand? { commands.last }
        var statuses: [RemoteCommand.Status] { commands.compactMap { $0.status } }
        func count(_ s: RemoteCommand.Status) -> Int { statuses.filter { $0 == s }.count }
    }

    /// A fresh model + backend + recorder + the model's durable-ledger URL (so a test can load the ledger
    /// and assert the durable provenance the delivery recorded).
    private func makeModel(connected: Bool = false) async -> (AppModel, MockBackend, EchoRecorder, URL) {
        let backend = MockBackend()
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stalehost-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        let rec = EchoRecorder()
        rec.attach(to: model)
        if connected { await backend.connect() }
        return (model, backend, rec, ledgerURL)
    }

    private func withCleanSettings(_ body: () async throws -> Void) async rethrows {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled, allowed = s.childAllowed, adv = s.advancedControlEnabled
        let rro = s.remotesReadOnly, clr = s.readOnlyAllowAlertClear
        let mode = s.appMode
        s.phoneReadOnly = false
        s.childModeEnabled = false
        s.advancedControlEnabled = true
        s.remotesReadOnly = false
        s.readOnlyAllowAlertClear = false
        s.appMode = .advanced
        let d = UserDefaults.standard
        let peerPolicies = d.data(forKey: "remotePeerPolicies"), peerQR = d.data(forKey: "remotePeerHighEntropy")
        d.removeObject(forKey: "remotePeerPolicies")
        d.removeObject(forKey: "remotePeerHighEntropy")
        defer {
            s.phoneReadOnly = ro
            s.childModeEnabled = child
            s.childAllowed = allowed
            s.advancedControlEnabled = adv
            s.remotesReadOnly = rro
            s.readOnlyAllowAlertClear = clr
            s.appMode = mode
            d.set(peerPolicies, forKey: "remotePeerPolicies")
            d.set(peerQR, forKey: "remotePeerHighEntropy")
        }
        try await body()
    }

    // No peer can hold a full-control grant, so a Mac host-approval include-stale path is unconstructable.

    /// Pin a KNOWN stale reading (10 min old): a fixed value above target so a correction is nonzero, with
    /// a stale timestamp so `freshCorrectionBG == nil` and the include-stale branch is the one under test.
    private func seedStale(_ backend: MockBackend, _ mgdl: Int) {
        backend.seedFreshGlucose(mgdl, at: Date().addingTimeInterval(-600))
    }

    private let tol = 0.0001
    private let staleBg = 200  // > target 110 ⇒ a real positive correction
    private let carbs = 30.0

    /// Load the durable ledger the model persisted, to assert the include-stale provenance sidecar.
    private func loadedLedger(_ url: URL) -> RemoteBolusLedger { RemoteBolusLedgerStore(url: url).load() }

    // MARK: - (a) THE GAP CLOSED: acknowledged stale ⇒ host delivers the stale-CORRECTED dose

    @Test func includeStaleDeliversHostStaleCorrectedDose() async {
        try? await withCleanSettings {
            let (model, backend, rec, _) = await makeModel(connected: true)
            backend.setLiveIob(1.0)  // deterministic IOB
            seedStale(backend, staleBg)
            let staleDose = await model.recommendBolus(carbsGrams: carbs, bgMgdl: staleBg).recommendedUnits
            let carbsOnly = await model.recommendBolus(carbsGrams: carbs, bgMgdl: nil).recommendedUnits
            #expect(staleDose > carbsOnly)  // sanity: the stale reading adds insulin
            await model.remoteDeliver(
                requestId: "s-a", carbsGrams: carbs, bgMgdl: staleBg,
                remoteEstimate: staleDose, includeStaleBG: true, peerId: "watch")
            #expect(rec.last?.status == .delivered)
            #expect(abs((rec.last?.deliveredUnits ?? -1) - staleDose) < tol)
            // The correction was recomputed from the HOST's own stale reading (recordedBg == the stale value).
            #expect(backend.lastDeliver?.bg == staleBg)
            #expect((backend.lastDeliver?.units ?? -1) > carbsOnly)  // strictly larger than carbs-only
        }
    }

    // MARK: - (b) absent intent ⇒ carbs-only (bg nil), delivers

    @Test func absentIntentFailsClosedToCarbsOnly() async {
        try? await withCleanSettings {
            let (model, backend, rec, _) = await makeModel(connected: true)
            backend.setLiveIob(1.0)
            seedStale(backend, staleBg)
            let carbsOnly = await model.recommendBolus(carbsGrams: carbs, bgMgdl: nil).recommendedUnits
            // No includeStaleBG intent; the client sends a carbs-only estimate → no divergence.
            await model.remoteDeliver(
                requestId: "s-b", carbsGrams: carbs, bgMgdl: staleBg,
                remoteEstimate: carbsOnly, peerId: "watch")
            #expect(rec.last?.status == .delivered)
            #expect(backend.lastDeliver?.bg == nil)  // carbs-only: no correction basis
            #expect(abs((backend.lastDeliver?.units ?? -1) - carbsOnly) < tol)
        }
    }

    // MARK: - (c) absent intent + include-stale estimate ⇒ divergence .failed

    @Test func absentIntentWithCorrectedEstimateDiverges() async {
        try? await withCleanSettings {
            let (model, backend, rec, _) = await makeModel(connected: true)
            backend.setLiveIob(1.0)
            seedStale(backend, staleBg)
            // A legacy/carbs-only host: no intent ⇒ carbs-only dose, but the client sent a stale-CORRECTED
            // estimate → the two diverge → the existing guard rejects (the pre-PR-2 behavior, preserved).
            let staleDose = await model.recommendBolus(carbsGrams: carbs, bgMgdl: staleBg).recommendedUnits
            await model.remoteDeliver(
                requestId: "s-c", carbsGrams: carbs, bgMgdl: staleBg,
                remoteEstimate: staleDose, includeStaleBG: false, peerId: "watch")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.contains("Dose changed") == true)
            #expect(rec.count(.delivering) == 0)  // never reached the backend
            #expect(backend.lastDeliver == nil)
        }
    }

    // MARK: - (d) consistency gate: intent true but wire bg ≠ host glucose ⇒ carbs-only ⇒ diverges ⇒ .failed

    @Test func intentButHostClientMismatchFailsClosed() async {
        try? await withCleanSettings {
            let (model, backend, rec, _) = await makeModel(connected: true)
            backend.setLiveIob(1.0)
            seedStale(backend, staleBg)  // host reading = 200
            let wireBg = staleBg - 5  // client's own stale reading = 195 (mismatch)
            // Client estimated its correction from 195; host reading is 200, so the equality gate fails →
            // the host uses NO correction basis (carbs-only) → the corrected estimate diverges → rejected.
            let clientEstimate = await model.recommendBolus(carbsGrams: carbs, bgMgdl: wireBg).recommendedUnits
            await model.remoteDeliver(
                requestId: "s-d", carbsGrams: carbs, bgMgdl: wireBg,
                remoteEstimate: clientEstimate, includeStaleBG: true, peerId: "watch")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.contains("Dose changed") == true)
            #expect(rec.count(.delivering) == 0)
            #expect(backend.lastDeliver == nil)
        }
    }

    // MARK: - (e) fresh precedence: fresh reading + intent ⇒ fresh used, provenance false

    @Test func freshReadingWinsOverIncludeStaleIntent() async {
        try? await withCleanSettings {
            let (model, backend, rec, ledgerURL) = await makeModel(connected: true)
            backend.setLiveIob(1.0)
            backend.seedFreshGlucose(staleBg)  // FRESH (now) reading of 200
            let freshDose = await model.recommendBolus(carbsGrams: carbs, bgMgdl: staleBg).recommendedUnits
            // Intent is set, but the fresh reading always wins (unchanged behavior); provenance stays false.
            await model.remoteDeliver(
                requestId: "s-e", carbsGrams: carbs, bgMgdl: staleBg,
                remoteEstimate: freshDose, includeStaleBG: true, peerId: "watch")
            #expect(rec.last?.status == .delivered)
            #expect(backend.lastDeliver?.bg == staleBg)  // fresh reading used as the basis
            #expect(abs((backend.lastDeliver?.units ?? -1) - freshDose) < tol)
            // NOT an acknowledged-stale delivery → the durable provenance sidecar is false.
            #expect(loadedLedger(ledgerURL).usedIncludedStaleBG(peerId: "watch", requestId: "s-e") == false)
        }
    }

    // MARK: - (f) a genuine >0.10 U divergence still rejects (guard unchanged on the stale recompute)

    @Test func genuineDivergenceStillRejectsOnIncludeStale() async {
        try? await withCleanSettings {
            let (model, backend, rec, _) = await makeModel(connected: true)
            backend.setLiveIob(1.0)
            seedStale(backend, staleBg)
            let staleDose = await model.recommendBolus(carbsGrams: carbs, bgMgdl: staleBg).recommendedUnits
            // Same acknowledged-stale path as (a), but the client estimate is off by >0.10 U → still rejected.
            await model.remoteDeliver(
                requestId: "s-f", carbsGrams: carbs, bgMgdl: staleBg,
                remoteEstimate: staleDose + 0.5, includeStaleBG: true, peerId: "watch")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.contains("Dose changed") == true)
            #expect(rec.count(.delivering) == 0)
            #expect(backend.lastDeliver == nil)
        }
    }

    // MARK: - (g) durable provenance: true on include-stale, false on carbs-only; the ledger carries it

    @Test func ledgerRecordsIncludeStaleProvenance() async {
        try? await withCleanSettings {
            // include-stale delivery ⇒ provenance TRUE, durably.
            let (m1, b1, r1, url1) = await makeModel(connected: true)
            b1.setLiveIob(1.0)
            seedStale(b1, staleBg)
            let staleDose = await m1.recommendBolus(carbsGrams: carbs, bgMgdl: staleBg).recommendedUnits
            await m1.remoteDeliver(
                requestId: "g-true", carbsGrams: carbs, bgMgdl: staleBg,
                remoteEstimate: staleDose, includeStaleBG: true, peerId: "watch")
            #expect(r1.last?.status == .delivered)
            #expect(loadedLedger(url1).usedIncludedStaleBG(peerId: "watch", requestId: "g-true") == true)

            // carbs-only delivery ⇒ provenance FALSE.
            let (m2, b2, r2, url2) = await makeModel(connected: true)
            b2.setLiveIob(1.0)
            seedStale(b2, staleBg)
            let carbsOnly = await m2.recommendBolus(carbsGrams: carbs, bgMgdl: nil).recommendedUnits
            await m2.remoteDeliver(
                requestId: "g-false", carbsGrams: carbs, bgMgdl: staleBg,
                remoteEstimate: carbsOnly, peerId: "watch")
            #expect(r2.last?.status == .delivered)
            #expect(loadedLedger(url2).usedIncludedStaleBG(peerId: "watch", requestId: "g-false") == false)
        }
    }

    // MARK: - (i) access gates still deny BEFORE resolve (include-stale intent cannot bypass a gate)

    @Test func gatesDenyBeforeResolveEvenWithIncludeStale() async {
        // `refreshCalcInputsNowCount` proves whether `resolveRemoteDose` ran at all (it forces that read):
        // a gate denial must reject before resolve, so the count stays 0 and nothing is delivered. Setup
        // (connect/seed/setLiveIob) never touches that read, so no probe is taken here — the estimate value
        // is irrelevant because resolve is never reached.

        // remotesReadOnly: denied before resolve. An authenticated Garmin peer is always denied via
        // Gate 4 regardless of this flag; this pin uses the read-only surface that still produces this reason.
        try? await withCleanSettings {
            let (model, backend, rec, _) = await makeModel(connected: true)
            backend.setLiveIob(1.0)
            seedStale(backend, staleBg)
            AppSettings.shared.remotesReadOnly = true
            #expect(backend.refreshCalcInputsNowCount == 0)  // baseline: resolve hasn't run
            await model.remoteDeliver(
                requestId: "i-ro", carbsGrams: carbs, bgMgdl: staleBg,
                remoteEstimate: 5.0, includeStaleBG: true,
                from: .garmin, peerId: "garmin")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.lowercased().contains("read-only") == true)
            #expect(rec.count(.delivering) == 0)
            #expect(backend.lastDeliver == nil)
            #expect(backend.refreshCalcInputsNowCount == 0)  // resolve never ran
        }

        // Child-mode denial is frozen off (setter is a no-op). AccessPolicyTests still pin the evaluator against `true`.
    }

    // MARK: - (j) FIX 2: carbs==0 PURE correction + include-stale (within cap) ⇒ doses off the stale reading

    /// The riskiest include-stale variant: a correction-ONLY request (`carbsGrams == 0`) has no carb
    /// component to anchor it, so it is a pure insulin-INCREASING dose driven entirely by the (stale) BG.
    /// With explicit intent, a within-cap stale reading, and wire == host glucose, the host must recompute
    /// that pure correction from ITS OWN stale reading, with the include-stale provenance recorded.
    @Test func includeStaleZeroCarbPureCorrectionDosesOffStaleReading() async {
        try? await withCleanSettings {
            let (model, backend, rec, ledgerURL) = await makeModel(connected: true)
            backend.setLiveIob(1.0)
            seedStale(backend, staleBg)  // 10 min old ⇒ within the 15-min cap
            // Probe the calculator for the pure correction. (200 → target 110, ISF 40, IOB 1.0) ⇒ 1.25 U:
            // strictly positive here, so it delivers a real dose rather than rounding to 0 (documented).
            let pureCorr = await model.recommendBolus(carbsGrams: 0, bgMgdl: staleBg).recommendedUnits
            #expect(pureCorr > 0)
            await model.remoteDeliver(
                requestId: "j-zerocarb", carbsGrams: 0, bgMgdl: staleBg,
                remoteEstimate: pureCorr, includeStaleBG: true, peerId: "watch")
            #expect(rec.last?.status == .delivered)
            #expect(abs((rec.last?.deliveredUnits ?? -1) - pureCorr) < tol)
            #expect(backend.lastDeliver?.bg == staleBg)  // bg USED == the host's own stale value
            #expect(backend.lastDeliver?.carbs == 0)  // a PURE correction: no carb component
            #expect(abs((backend.lastDeliver?.units ?? -1) - pureCorr) < tol)
            #expect(loadedLedger(ledgerURL).usedIncludedStaleBG(peerId: "watch", requestId: "j-zerocarb") == true)
        }
    }

    // MARK: - (k) FIX 1/2: stale BEYOND the includable cap fails closed; a within-cap control still includes

    /// The core FIX-1 assertion: an include-stale correction may only be recomputed from a reading no older
    /// than `GlucoseFreshness.maxIncludableStaleness`. A reading past the cap fails closed to carbs-only
    /// (basis nil, provenance false) exactly as a no-intent request; a within-cap control — same intent,
    /// same wire==g consistency, ONLY the age differs — DOES include, proving the boundary is what bites.
    @Test func includeStaleBeyondMaxAgeFailsClosedToCarbsOnly() async {
        try? await withCleanSettings {
            // Pin the window explicitly so the boundary is unambiguous regardless of the global default.
            let savedStale = GlucoseFreshness.staleAfter, savedMax = GlucoseFreshness.maxIncludableStaleness
            GlucoseFreshness.staleAfter = 6 * 60
            GlucoseFreshness.maxIncludableStaleness = 15 * 60
            defer {
                GlucoseFreshness.staleAfter = savedStale
                GlucoseFreshness.maxIncludableStaleness = savedMax
            }

            // (k1) reading OLDER than the cap (20 min > 15 min) + explicit intent + wire == host reading:
            // the age cap bites ⇒ basis nil ⇒ carbs-only. A cap-aware remote sends a carbs-only estimate,
            // so it DELIVERS carbs-only rather than diverging.
            let (m1, b1, r1, url1) = await makeModel(connected: true)
            b1.setLiveIob(1.0)
            b1.seedFreshGlucose(staleBg, at: Date().addingTimeInterval(-20 * 60))  // 20 min old ⇒ beyond cap
            let carbsOnly = await m1.recommendBolus(carbsGrams: carbs, bgMgdl: nil).recommendedUnits
            await m1.remoteDeliver(
                requestId: "k-beyond", carbsGrams: carbs, bgMgdl: staleBg,
                remoteEstimate: carbsOnly, includeStaleBG: true, peerId: "watch")
            #expect(r1.last?.status == .delivered)
            #expect(b1.lastDeliver?.bg == nil)  // no correction basis: too old to include
            #expect(abs((b1.lastDeliver?.units ?? -1) - carbsOnly) < tol)
            #expect(loadedLedger(url1).usedIncludedStaleBG(peerId: "watch", requestId: "k-beyond") == false)

            // (k2) CONTROL: identical request but the reading is WITHIN the cap (10 min) ⇒ the stale reading
            // IS included ⇒ a strictly larger, stale-corrected dose with provenance TRUE.
            let (m2, b2, r2, url2) = await makeModel(connected: true)
            b2.setLiveIob(1.0)
            b2.seedFreshGlucose(staleBg, at: Date().addingTimeInterval(-10 * 60))  // 10 min old ⇒ within cap
            let staleDose = await m2.recommendBolus(carbsGrams: carbs, bgMgdl: staleBg).recommendedUnits
            #expect(staleDose > carbsOnly)  // sanity: the included stale reading adds insulin
            await m2.remoteDeliver(
                requestId: "k-within", carbsGrams: carbs, bgMgdl: staleBg,
                remoteEstimate: staleDose, includeStaleBG: true, peerId: "watch")
            #expect(r2.last?.status == .delivered)
            #expect(b2.lastDeliver?.bg == staleBg)  // included the stale reading as the basis
            #expect(abs((b2.lastDeliver?.units ?? -1) - staleDose) < tol)
            #expect(loadedLedger(url2).usedIncludedStaleBG(peerId: "watch", requestId: "k-within") == true)
        }
    }

    // MARK: - (l) FIX 2 (panel nonblocking): a UNITS-mode request treats includeStaleBG as a no-op

    @Test func unitsModeRequestTreatsIncludeStaleAsNoOp() async {
        try? await withCleanSettings {
            let (model, backend, rec, ledgerURL) = await makeModel(connected: true)
            backend.setLiveIob(1.0)
            seedStale(backend, staleBg)
            // A TRUE units request (no carbsGrams): resolve returns the passed units verbatim BEFORE the
            // basis-selection block, so includeStaleBG is never consulted — a pure no-op.
            await model.remoteDeliver(
                requestId: "l-units", units: 1.0, bgMgdl: staleBg,
                includeStaleBG: true, peerId: "watch")
            #expect(rec.last?.status == .delivered)
            #expect(abs((backend.lastDeliver?.units ?? -1) - 1.0) < tol)  // delivered the passed units, unchanged
            // Never an include-stale dose (the branch is unreachable on the units path).
            #expect(loadedLedger(ledgerURL).usedIncludedStaleBG(peerId: "watch", requestId: "l-units") == false)
        }
    }

    // MARK: - (m) FIX 2 (panel nonblocking): wire ≠ host glucose ⇒ basis nil (carbs-only), provenance false

    @Test func wireMismatchYieldsCarbsOnlyBasisNil() async {
        try? await withCleanSettings {
            let (model, backend, rec, ledgerURL) = await makeModel(connected: true)
            backend.setLiveIob(1.0)
            seedStale(backend, staleBg)  // host reading = 200 (within cap)
            let wireBg = staleBg - 5  // 195: wire ≠ host glucose
            // Direct assertion of the consistency gate: intent is set and the reading is within the cap, but
            // the wire value disagrees with the host's own reading ⇒ NO correction basis (carbs-only). The
            // client sends a carbs-only estimate so it DELIVERS (rather than diverging as in test (d)).
            let carbsOnly = await model.recommendBolus(carbsGrams: carbs, bgMgdl: nil).recommendedUnits
            await model.remoteDeliver(
                requestId: "m-mismatch", carbsGrams: carbs, bgMgdl: wireBg,
                remoteEstimate: carbsOnly, includeStaleBG: true, peerId: "watch")
            #expect(rec.last?.status == .delivered)
            #expect(backend.lastDeliver?.bg == nil)  // basis nil: wire≠g fails the equality gate
            #expect(abs((backend.lastDeliver?.units ?? -1) - carbsOnly) < tol)
            #expect(loadedLedger(ledgerURL).usedIncludedStaleBG(peerId: "watch", requestId: "m-mismatch") == false)
        }
    }

    // MARK: - (n) FIX 2 (panel nonblocking): RemoteBolusLedger tolerant decode ⇒ absent provenance ⇒ false

    @Test func ledgerTolerantDecodeDefaultsProvenanceFalse() throws {
        var ledger = RemoteBolusLedger()
        _ = ledger.begin(peerId: "p", requestId: "r", doseKey: "k", usedIncludedStaleBG: true)
        ledger.settle(peerId: "p", requestId: "r", status: "delivered")
        #expect(ledger.usedIncludedStaleBG(peerId: "p", requestId: "r") == true)
        // Encode, then STRIP `usedIncludedStaleBG` from every entry to mimic a ledger persisted before the
        // field existed, and decode it back: the tolerant `decodeIfPresent ?? false` must default it false
        // without dropping the rest of the entry.
        let data = try JSONEncoder().encode(ledger)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var entries = obj["entries"] as! [String: Any]
        for (k, v) in entries {
            var e = v as! [String: Any]
            e.removeValue(forKey: "usedIncludedStaleBG")
            entries[k] = e
        }
        obj["entries"] = entries
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(RemoteBolusLedger.self, from: stripped)
        #expect(decoded.usedIncludedStaleBG(peerId: "p", requestId: "r") == false)  // absent key ⇒ false
        #expect(decoded.state(peerId: "p", requestId: "r") == .terminal)  // rest of the entry survived
    }
}
