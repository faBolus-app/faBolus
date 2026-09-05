import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Pins that compose-time bolus recommendation re-reads op-115 and op-109 and fails closed if those
/// reads cannot be obtained. Invented IOB (`snapshot.iobUnits += delivered`) must not return.
@Suite(.serialized) @MainActor
struct DosingInputFreshnessTests {

    // MARK: - Real TandemBackend (FakePumpTransport)

    private let bolusId = 4321

    /// A connected+paired backend with time/permission scripted; the fake never answers the fire-and-forget
    /// op-115/op-109 reads, so a compose-time `refreshCalcInputsNow()` always times out (fails closed). The
    /// refresh timeout is shortened so the fail-closed test stays fast.
    private func makeBackend() -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        backend.deliveryPollTimeoutOverride = 1.2
        backend.calcInputRefreshTimeout = 0.2
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(BolusPermissionResponse.props.opCode, .frame(FakePumpTransport.permissionGranted(bolusId: bolusId)))
        return (backend, fake)
    }

    /// A full delivery reports the authoritative delivered amount, and `snapshot.iobUnits` is not bumped by it.
    @Test func fullDeliveryReportsAuthoritativeAndDoesNotFabricateIob() async throws {
        let (b, fake) = makeBackend()
        let initiateOp = InitiateBolusResponse.props.opCode
        let statusOp = CurrentBolusStatusResponse.props.opCode
        let lastOp = LastBolusStatusV2Response.props.opCode
        #expect(b.snapshot.iobUnits == 0)  // no op-109 has arrived
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
        fake.script(lastOp, .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: 2000)))
        let delivered = try await b.deliverBolus(units: 2.0, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
        #expect(delivered == 2.0)  // authoritative delivered amount, unchanged by the delete
        #expect(b.snapshot.iobUnits == 0)  // NOT fabricated to 2.0 by a `+= delivered`
        #expect(!b.deliveryOutcomeUnknown)
    }

    /// A partial completion likewise reports the authoritative amount and never fabricates IOB.
    @Test func partialDeliveryDoesNotFabricateIob() async throws {
        let (b, fake) = makeBackend()
        let initiateOp = InitiateBolusResponse.props.opCode
        let statusOp = CurrentBolusStatusResponse.props.opCode
        let lastOp = LastBolusStatusV2Response.props.opCode
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
        fake.script(lastOp, .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: 1000)))
        let delivered = try await b.deliverBolus(units: 2.0, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
        #expect(delivered == 1.0)  // authoritative partial, not the requested 2.0
        #expect(b.snapshot.iobUnits == 0)  // still no fabrication
    }

    /// With no fresh op-115/op-109 obtainable, `recommendBolus` returns `inputsVerified == false` so every surface blocks.
    @Test func recommendBolusFailsClosedWhenFreshCalcInputsUnavailable() async {
        let (b, _) = makeBackend()
        // `TandemBackend(testTransport:)` defaults `therapyParamsDate` to "just read" so other delivery tests aren't blocked. Recreate the never-read window here.
        b.setTherapyParamsDateForTesting(nil)
        let rec = await b.recommendBolus(carbsGrams: 30, bgMgdl: 120)
        #expect(rec.inputsVerified == false)  // BLOCKED (DIF-core interim, pre DIF-ux)
        #expect(rec.iobStale)  // op-109 never arrived → stale
        #expect(rec.therapyStale)  // op-115 never arrived → stale
        #expect(rec.therapyUnavailable)  // op-115 NEVER arrived → hardcoded guess → DIF-ux blocks (cancel-only)
        #expect(rec.assumedProfile != nil)  // the assumed profile the UI must confirm
        #expect(abs(rec.recommendedUnits - 3.0) < 0.0001)  // 30 g / 10 (assumed CR), carbs-only
    }

    /// A window-based gate would verify a dose off in-window cached op-115/op-109 even when this compose's
    /// refresh timed out — a profile time-segment change would be missed. The per-attempt gate must fail closed unless a read confirmed both inputs during this compose.
    @Test func recommendBolusFailsClosedWhenInWindowCacheIsNotConfirmedThisAttempt() async {
        let (b, _) = makeBackend()
        // Seed an in-window cache via the REAL didReceiveFrame path: matching IOB (1.4 U) so the cross-check
        // does NOT trip, and real CR (10 g/U) / ISF / target so a verified dose COULD be built if the gate
        // were window-based. No op-115/op-109 reply is scripted, so the compose-time refresh times out.
        b.injectStatusFrameForTesting(FakePumpTransport.controlIQIOB(iobMilliunits: 1400))
        b.injectStatusFrameForTesting(
            FakePumpTransport.calcDataSnapshot(
                iobMilliunits: 1400, targetBg: 110, isf: 40, carbRatioMilliGramsPerUnit: 10_000,
                maxBolusMilliunits: 25_000))
        // Sanity: the cache is present AND in-window — a pure window gate would PASS from here.
        #expect(b.snapshot.iobUnits == 1.4)
        #expect(!b.snapshot.isIobStale())
        #expect(!b.snapshot.isTherapyStale())

        let rec = await b.recommendBolus(carbsGrams: 30, bgMgdl: 120)
        #expect(rec.inputsVerified == false)  // per-attempt gate: not confirmed THIS compose → block
        // The display staleness flags stay FALSE (the values really are recent) — proving the block is
        // driven by PER-ATTEMPT freshness, not by window staleness (which is what the old gate keyed on).
        #expect(!rec.iobStale)
        #expect(!rec.therapyStale)
        #expect(rec.assumedProfile != nil)  // exposes the true cached CR for the confirm UI
        #expect(abs(rec.recommendedUnits - 3.0) < 0.0001)  // 30 g / 10 g/U, carbs-only (correction dropped)
    }

    /// A second compose routinely joins an in-flight refresh. A wall-clock "stamp must post-date MY composeStart"
    /// proof would wrongly fail the joiner closed; confirmation-return does not.
    @Test func coalescedJoinerVerifiesEvenWhenItStartsAfterTheFirstFrame() async {
        let (b, _) = makeBackend()  // testTransport init leaves it `.connected`
        b.calcInputRefreshTimeout = 5  // ensure the timeout never wins the race in-test
        let t1 = Task { await b.recommendBolus(carbsGrams: 30, bgMgdl: 120) }  // initiator starts the read
        await Task.yield()
        await Task.yield()  // t1 now in-flight (op-115+op-109 requests sent, suspended)
        b.injectStatusFrameForTesting(FakePumpTransport.controlIQIOB(iobMilliunits: 1400))  // FIRST frame (op-109)
        let t2 = Task { await b.recommendBolus(carbsGrams: 30, bgMgdl: 120) }  // JOINER starts AFTER op-109's stamp
        await Task.yield()
        await Task.yield()  // t2 coalesces onto the same in-flight read
        b.injectStatusFrameForTesting(
            FakePumpTransport.calcDataSnapshot(  // SECOND frame (op-115) completes it
                iobMilliunits: 1400, targetBg: 110, isf: 40, carbRatioMilliGramsPerUnit: 10_000,
                maxBolusMilliunits: 25_000))
        let r1 = await t1.value
        let r2 = await t2.value
        #expect(r1.inputsVerified == true)  // initiator verified
        #expect(r2.inputsVerified == true)  // JOINER verified too, despite starting after op-109 (the fix)
    }

    // MARK: - MockBackend spy: recommendBolus forces the fresh calc-input read

    /// The dose path forces a fresh op-115 + op-109 read (the mock's `refreshCalcInputsNow`) BEFORE building
    /// the recommendation — proven by the mock's invocation spy.
    @Test func recommendBolusForcesAFreshCalcInputRead() async {
        let backend = MockBackend()
        #expect(backend.refreshCalcInputsNowCount == 0)
        _ = await backend.recommendBolus(carbsGrams: 30, bgMgdl: nil)
        #expect(backend.refreshCalcInputsNowCount == 1)  // exactly one forced read per recommend
    }

    // MARK: - Override dose-math on the real TandemBackend (not the mock)

    /// Seed an in-window op-115 (CR 10 g/U, ISF 40, target 110) + op-109 (IOB 1.0 U) via the REAL
    /// didReceiveFrame path, so the compose-time fresh read still times out (`inputsVerified == false`) but
    /// the cached last-known therapy/IOB exist. The host-owner override then recomputes the FULL dose off
    /// those cached values WITH the BG correction, and SUBTRACTS the last-known IOB (never zeroes it). This
    /// exercises `TandemBackend`'s 4-arg override branch directly — the mock's predicate can't stand in.
    @Test func tandemOverrideRecomputesOffLastKnownTherapyAndSubtractsIob() async {
        let (b, _) = makeBackend()
        b.injectStatusFrameForTesting(FakePumpTransport.controlIQIOB(iobMilliunits: 1000))  // op-109 = 1.0 U
        b.injectStatusFrameForTesting(
            FakePumpTransport.calcDataSnapshot(
                iobMilliunits: 1000, targetBg: 110, isf: 40, carbRatioMilliGramsPerUnit: 10_000,
                maxBolusMilliunits: 25_000))
        let rec = await b.recommendBolus(carbsGrams: 40, bgMgdl: 220, allowStaleIob: true, allowStaleTherapy: true)
        #expect(rec.inputsVerified == false)  // an override dose is NEVER verified
        #expect(!rec.therapyUnavailable)  // op-115 WAS read (real last-known) → override is offerable, not blocked
        // 40 g / 10 (CR) + (220 − 110)/40 (ISF) − 1.0 (last-known IOB) = 4.0 + 2.75 − 1.0 = 5.75 U.
        #expect(abs(rec.recommendedUnits - 5.75) < 0.0001)
        // Without the override the same state is carbs-only (BG correction dropped) → 4.0 U.
        let blocked = await b.recommendBolus(carbsGrams: 40, bgMgdl: 220)
        #expect(blocked.inputsVerified == false)
        #expect(abs(blocked.recommendedUnits - 4.0) < 0.0001)
    }

    /// The op-115↔op-109 CROSS-CHECK DIVERGENCE case (e.g. right after a bolus, op-109 swan6hrIOB still reads
    /// LOW while op-115 already reflects the delivery). The include-last-known-IOB override MUST subtract the
    /// LARGER of the two reads, so it can never size a correction bigger than a confirmed-fresh read would —
    /// otherwise it would stack insulin. Pins the fix: subtract max(op-109, op-115), not op-109 blindly.
    @Test func tandemOverrideOnCrossCheckDivergenceSubtractsTheLargerIob() async {
        let (b, _) = makeBackend()
        b.injectStatusFrameForTesting(FakePumpTransport.controlIQIOB(iobMilliunits: 1000))  // op-109 = 1.0 U (lagging)
        b.injectStatusFrameForTesting(
            FakePumpTransport.calcDataSnapshot(
                iobMilliunits: 4000, targetBg: 110, isf: 40, carbRatioMilliGramsPerUnit: 10_000,
                maxBolusMilliunits: 25_000))  // op-115 = 4.0 U
        let rec = await b.recommendBolus(carbsGrams: 40, bgMgdl: 220, allowStaleIob: true, allowStaleTherapy: false)
        #expect(rec.inputsVerified == false)
        #expect(rec.iobStale)  // the cross-check divergence set it
        // Conservative IOB = max(op-109 1.0, op-115 4.0) = 4.0. The correction (220−110)/40 = 2.75 is fully
        // offset by that 4.0 (clamped at 0 — IOB never reduces the carb dose), so the dose is carbs-only
        // 40/10 = 4.0 U — exactly what a confirmed-fresh read (op-109 caught up to ~4.0) would give. The BUG
        // (subtracting the lower op-109 1.0) would have added a 1.75 U correction → 5.75 U, stacking onto the
        // just-delivered bolus. So max() removes the stacking.
        #expect(abs(rec.recommendedUnits - 4.0) < 0.0001)
    }

    /// The conservative-max IOB guard must be keyed on the LIVE divergence, NOT the compose-time
    /// `allowStaleIob` flag: a THERAPY-only override (`allowStaleIob:false, allowStaleTherapy:true`) whose IOB
    /// reads diverge (op-109 lags LOW after a bolus/Control-IQ correction) must STILL subtract the larger
    /// op-115, or it would size a correction off the too-low op-109 and stack. Pins that the guard fires with
    /// allowStaleIob == false.
    @Test func tandemTherapyOnlyOverrideStillSubtractsTheLargerIobOnDivergence() async {
        let (b, _) = makeBackend()
        b.injectStatusFrameForTesting(FakePumpTransport.controlIQIOB(iobMilliunits: 1000))  // op-109 = 1.0 U (lagging)
        b.injectStatusFrameForTesting(
            FakePumpTransport.calcDataSnapshot(
                iobMilliunits: 4000, targetBg: 110, isf: 40, carbRatioMilliGramsPerUnit: 10_000,
                maxBolusMilliunits: 25_000))  // op-115 = 4.0 U
        let rec = await b.recommendBolus(carbsGrams: 40, bgMgdl: 220, allowStaleIob: false, allowStaleTherapy: true)
        #expect(rec.inputsVerified == false)
        // Same conservative result as the allowStaleIob case: max(1.0, 4.0) = 4.0 fully offsets the 2.75
        // correction → carbs-only 4.0 U. Keyed on the divergence, not the flag, so it holds here too.
        #expect(abs(rec.recommendedUnits - 4.0) < 0.0001)
    }

    // MARK: - AppModel: the divergence guard now catches an INPUT change between compose and deliver

    private func makeModel(connected: Bool) async -> (AppModel, MockBackend, AppModelBehaviorTests.EchoRecorder) {
        let backend = MockBackend()
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dif-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        let rec = AppModelBehaviorTests.EchoRecorder()
        rec.attach(to: model)
        if connected { await backend.connect() }
        return (model, backend, rec)
    }

    /// Run with the AppSettings gates in a known-clean state (child mode / read-only OFF, Advanced), so a
    /// remote delivery is gated ONLY by the divergence guard — never by a gate another suite left dirty.
    /// Restores after. Mirrors `AppModelBehaviorTests.withCleanSettings` (which is private to that suite).
    private func withCleanGates(_ body: () async -> Void) async {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled, rro = s.remotesReadOnly
        s.phoneReadOnly = false
        s.childModeEnabled = false
        s.remotesReadOnly = false
        defer {
            s.phoneReadOnly = ro
            s.childModeEnabled = child
            s.remotesReadOnly = rro
        }
        await body()
    }

    /// Because the host's `recommendBolus` re-reads FRESH inputs at deliver time, a change in an input
    /// (here IOB) between the remote's compose-time estimate and the host recompute makes the authoritative
    /// dose diverge — so the existing 0.10 U guard fires and the bolus is rejected rather than delivering a
    /// dose built off a value that has since moved. Contrast: with the input unchanged, the same request
    /// delivers, proving this isn't an always-reject.
    @Test func divergenceGuardFiresWhenAnInputChangesBetweenComposeAndDeliver() async {
        await withCleanGates {
            // A high, FRESH glucose so a real correction exists and IOB actually moves the dose.
            let (model, backend, rec) = await makeModel(connected: true)
            backend.seedFreshGlucose(250)
            backend.setLiveIob(0.0)
            // Compose-time estimate (what the remote computed): correction at IOB 0.
            let composeEstimate = await model.recommendBolus(carbsGrams: 0, bgMgdl: 250).recommendedUnits
            #expect(composeEstimate > 0)

            // IOB advances on the pump between compose and deliver; the host recompute re-reads it fresh.
            backend.setLiveIob(6.0)
            await model.remoteDeliver(
                requestId: "dif-div", carbsGrams: 0, remoteEstimate: composeEstimate, peerId: "watch")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.contains("Dose changed") == true)
            #expect(rec.count(.delivering) == 0)  // never reached the backend

            // Same request with the input UNCHANGED delivers — the guard isn't firing spuriously.
            let (model2, backend2, rec2) = await makeModel(connected: true)
            backend2.seedFreshGlucose(250)
            backend2.setLiveIob(0.0)
            let estimate2 = await model2.recommendBolus(carbsGrams: 0, bgMgdl: 250).recommendedUnits
            await model2.remoteDeliver(requestId: "dif-ok", carbsGrams: 0, remoteEstimate: estimate2, peerId: "watch")
            #expect(rec2.last?.status == .delivered)
        }
    }

    // MARK: - Host-owner overrides that relax the fail-closed block (mock profile 10/40/110)

    /// (a) include-last-known-IOB: the override recomputes the FULL dose off the last-known values WITH the
    /// BG correction, and keeps SUBTRACTING the last-known IOB — it is NOT carbs-only, and it never zeroes
    /// the IOB. With no override the same request stays blocked at the DIF-core carbs-only dose.
    @Test func includeLastKnownIobSubtractsIobAndKeepsBgCorrection() async {
        let b = MockBackend()
        b.setLiveIob(1.4)
        b.forceIobStale = true
        // Baseline (no override): fail closed, carbs-only (correction dropped): 30 g / 10 g·U⁻¹ = 3.0.
        let blocked = await b.recommendBolus(carbsGrams: 30, bgMgdl: 250)
        #expect(blocked.inputsVerified == false)
        #expect(blocked.iobStale)
        #expect(abs(blocked.recommendedUnits - 3.0) < 0.0001)
        // Override: 3.0 carbs + (250−110)/40 = 3.5 correction − 1.4 IOB = 5.1.
        let ov = await b.recommendBolus(carbsGrams: 30, bgMgdl: 250, allowStaleIob: true, allowStaleTherapy: false)
        #expect(ov.inputsVerified == false)  // (c) the override NEVER "verifies" the inputs
        #expect(abs(ov.recommendedUnits - 5.1) < 0.0001)
        #expect(ov.recommendedUnits > blocked.recommendedUnits)  // BG correction is INCLUDED (not carbs-only)
        #expect(ov.recommendedUnits < 6.5)  // < the zero-IOB dose ⇒ IOB is SUBTRACTED, not zeroed
    }

    /// (b) use-last-known-therapy: the override computes off the last-known CR/ISF/target WITH the BG
    /// correction. IOB pinned to 0 to isolate the therapy+BG effect.
    @Test func useLastKnownTherapyComputesOffCachedSettingsAndBg() async {
        let b = MockBackend()
        b.setLiveIob(0)
        b.forceTherapyStale = true
        let blocked = await b.recommendBolus(carbsGrams: 30, bgMgdl: 250)
        #expect(blocked.inputsVerified == false)
        #expect(blocked.therapyStale)
        #expect(abs(blocked.recommendedUnits - 3.0) < 0.0001)  // carbs-only
        let ov = await b.recommendBolus(carbsGrams: 30, bgMgdl: 250, allowStaleIob: false, allowStaleTherapy: true)
        #expect(ov.inputsVerified == false)
        // off last-known CR 10 / ISF 40 / target 110: 3.0 + (250−110)/40 = 6.5.
        #expect(abs(ov.recommendedUnits - 6.5) < 0.0001)
        #expect(ov.recommendedUnits > blocked.recommendedUnits)
    }

    /// (c) both stale + both overrides: still `inputsVerified == false`, and it sizes the full dose off the
    /// last-known values (the unified "use last-known & deliver" case in the host UI).
    @Test func bothOverridesStayUnverifiedAndSizeAFullDose() async {
        let b = MockBackend()
        b.setLiveIob(1.4)
        b.forceIobStale = true
        b.forceTherapyStale = true
        let ov = await b.recommendBolus(carbsGrams: 30, bgMgdl: 250, allowStaleIob: true, allowStaleTherapy: true)
        #expect(ov.inputsVerified == false)
        #expect(ov.iobStale && ov.therapyStale)
        #expect(abs(ov.recommendedUnits - 5.1) < 0.0001)  // 3 + 3.5 − 1.4
    }

    /// (d) FAIL-CLOSED HAZARD #1: the REMOTE path must STILL fail closed even though the override API now
    /// exists — `resolveRemoteDose` recomputes with NO override, so `guard rec.inputsVerified` blocks. The
    /// remote's estimate carrying the override dose must NOT let it through (the host recompute decides).
    @Test func remotePathStillFailsClosedDespiteOverrideApi() async {
        await withCleanGates {
            let (model, backend, rec) = await makeModel(connected: true)
            backend.seedFreshGlucose(250)
            backend.setLiveIob(1.4)
            backend.forceIobStale = true  // inputs unconfirmable ⇒ host recompute fails closed
            // A HOST could override to this dose; the remote sends it as its estimate — the host must still block.
            let overrideEstimate = await model.recommendBolus(carbsGrams: 30, bgMgdl: 250, allowStaleIob: true)
                .recommendedUnits
            await model.remoteDeliver(
                requestId: "difux-remote", carbsGrams: 30, remoteEstimate: overrideEstimate, peerId: "watch")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message?.lowercased().contains("not verified") == true)
            #expect(rec.count(.delivering) == 0)  // never reached the backend delivery
        }
    }
}
