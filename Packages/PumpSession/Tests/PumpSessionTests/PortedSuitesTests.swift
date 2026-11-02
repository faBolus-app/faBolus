import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

private let key = RemoteBolusLedger.Key(peerId: "phone", requestId: "phone-1")

@MainActor
private func deliver(_ rig: Rig, _ dose: ComposedDose, for seconds: Double = 2) async -> DeliveryResult {
    let session = rig.session
    let task = Task { await session.deliver(dose) }
    await rig.run(for: seconds)
    return await task.value
}

/// How each way a delivery can end is recorded. Ported from the old app's suite; the changes from it are
/// noted where they apply.
@MainActor
@Suite struct TandemDeliveryOutcomeTests {
    @Test func aDoseThePumpCantBeToldWritesNothing() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        let extended = ComposedDose(
            request: DoseRequest(id: "x", origin: .phone, shape: .extended(nowUnits: 1, laterUnits: 1, duration: 600)),
            calculatorIOBUnits: nil, correctionGlucoseMgdl: nil, calculatorCarbUnits: nil,
            usedIncludedStaleGlucose: false, notices: [])
        #expect(await rig.session.deliver(extended) == .notStarted(.invalidDose))
        #expect(rig.pump.arrivals.filter { $0.characteristic == .control }.isEmpty)
        #expect(await rig.ledger.ledger.allEntries.isEmpty)
    }

    @Test func noAnswerToInitiateIsUnknown() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.answers[MessageKey(InitiateBolusRequest.self)] = .silent
        })
        await rig.startHeld()
        guard case .started(_, .unknown) = await deliver(rig, composed(1.0), for: 12) else {
            Issue.record("expected unknown")
            return
        }
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).count == 1)
    }

    /// Changed from the old app: an InitiateBolus NACK is now always HMAC-verified (the link refuses an
    /// unverified one as unknown), so it is a definite refusal, not an unknown outcome.
    @Test func anAuthenticatedInitiateNackIsRefused() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.answers[MessageKey(InitiateBolusRequest.self)] = .cargo([0x01, 0x9a, 0x29, 0x00, 0x00, 0x01])
        })
        await rig.startHeld()
        guard case .started(_, .refused) = await deliver(rig, composed(1.0)) else {
            Issue.record("expected refused")
            return
        }
        #expect(await rig.ledger.block == nil)
    }

    @Test func anInitiateReplyNamingAnotherBolusIsUnknown() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.answers[MessageKey(InitiateBolusRequest.self)] = .cargo([0x00, 0x0f, 0x27, 0x00, 0x00, 0x00])
        })
        await rig.startHeld()
        guard case .started(_, .unknown) = await deliver(rig, composed(1.0)) else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test func aBolusWhoseStatusGoesSilentBecomesUnknown() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await deliver(rig, composed(2.0))
        rig.pump.answers[MessageKey(CurrentBolusStatusRequest.self)] = .silent
        await rig.run(for: 90, step: 2)
        #expect(await rig.outcomes(key).contains { $0.isUnknown })
    }

    @Test func aDropWhileDeliveringIsUnknownUntilHistorySettlesIt() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await deliver(rig, composed(2.0))
        rig.transport.drop()
        await rig.settle()
        #expect(await rig.ledger.ledger.outcome(key)?.isUnknown == true)
        await rig.run(for: 60, step: 1)
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 2.0))
    }

    @Test func aFullCompletionDeliversTheAmountThePumpReports() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await deliver(rig, composed(2.0))
        await rig.run(for: 25)
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 2.0))
    }

    /// One pump answers LastBolusStatusV2 with op-77: the amount comes from history instead.
    @Test func aLastBolusThePumpWontReadIsSettledFromHistory() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.answers[MessageKey(LastBolusStatusV2Request.self)] = .error(code: 6, drops: false)
        })
        await rig.startHeld()
        _ = await deliver(rig, composed(2.0))
        await rig.run(for: 30)
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 2.0))
    }

    /// Changed from the old app (which called it unknown): a last-bolus record naming another bolus means
    /// it can't speak for this one, so history settles it.
    @Test func aLastBolusNamingAnotherBolusIsSettledFromHistory() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            var v = [UInt8](repeating: 0, count: 24)
            v[1] = 0x0f
            v[2] = 0x27
            $0.answers[MessageKey(LastBolusStatusV2Request.self)] = .cargo(v)
        })
        await rig.startHeld()
        _ = await deliver(rig, composed(2.0))
        await rig.run(for: 30)
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 2.0))
    }

    /// The InitiateBolus sent carries the dose and inputs the composer approved, and the BG entry goes
    /// before the carb entry.
    @Test func theSentBolusCarriesTheApprovedInputs() async throws {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await deliver(rig, composed(2.0, carbs: 45, bg: 180, iob: 0.5, carbUnits: 2.0))
        let sent = try #require(rig.pump.arrivals(of: InitiateBolusRequest.self).first)
        let expected = try InitiateBolusRequest(
            validating: 2000, bolusID: 10650, bolusTypeBitmask: 1, foodVolume: 2000, correctionVolume: 0,
            bolusCarbs: 45,
            bolusBG: 180, bolusIOB: 500, extendedVolume: 0, extendedSeconds: 0, extended3: 0)
        #expect(sent.cargo == expected.cargo)
        let control = rig.pump.arrivals.filter { $0.characteristic == .control }.map(\.opCode)
        #expect(
            control == [
                BolusPermissionRequest.props.opCode, RemoteBgEntryRequest.props.opCode,
                RemoteCarbEntryRequest.props.opCode, InitiateBolusRequest.props.opCode
            ])
        // The entries carry the pump's seconds since boot from the clock read after permission.
        let carb = try #require(rig.pump.arrivals(of: RemoteCarbEntryRequest.self).first)
        let uptime = (0..<4).reduce(UInt32(0)) { $0 | UInt32(carb.cargo[3 + $1]) << (8 * UInt32($1)) }
        #expect(abs(Double(uptime) - Double(rig.pump.uptime)) < 15)
    }

    /// Changed from the old app: a refused permission reports the pump's own reason. The old guess that
    /// reason 1 with a low reservoir reading meant "out of insulin" is gone.
    @Test func aRefusedPermissionReportsThePumpsReason() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.cartridgeLoaded = false
            $0.reservoirUnits = 0
        })
        await rig.startHeld()
        guard case .started(_, .refused(let reason)) = await deliver(rig, composed(1.0)) else {
            Issue.record("expected refused")
            return
        }
        #expect(reason.contains("reason 1"))
        #expect(!reason.lowercased().contains("insulin"))
    }

    /// A cartridge the pump reports mid-change refuses the dose in the composer, before anything is sent.
    @Test func aCartridgeMidChangeRefusesBeforeAnySignedFrame() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.cartridgeLoaded = false
        })
        await rig.startHeld()
        let prepared = await rig.session.prepareDose()
        #expect(prepared.pump.cartridgeReadiness == .notReady)
        let access = AccessPolicy.AccessContext(
            phoneReadOnly: false, remotesReadOnly: false, capabilities: .tslimX2, garminBolusEnabled: true)
        let decision = DoseComposer.composePhone(
            PhoneDoseEntry(id: "phone-1", amount: .units(1)),
            context: prepared.context(access: access, remoteSizeLimitUnits: nil))
        #expect(decision == .refused(.unavailable(.noCartridge)))
        #expect(rig.pump.arrivals.filter { $0.characteristic == .control }.isEmpty)
    }

    /// An InitiateBolus reply too short to read says nothing about what the pump did: unknown, and new
    /// boluses wait until history settles it.
    @Test func aMalformedInitiateReplyIsUnknownAndBlocks() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.answers[MessageKey(InitiateBolusRequest.self)] = .cargo([0x00])
        })
        await rig.startHeld()
        guard case .started(_, .unknown) = await deliver(rig, composed(1.0), for: 12) else {
            Issue.record("expected unknown")
            return
        }
        guard case .unknownOutcome = await rig.ledger.block else {
            Issue.record("expected bolusing blocked")
            return
        }
    }

    /// A cancel that reaches the pump as the bolus finishes: the pump says it didn't cancel, and the
    /// outcome is the full amount it reports, never "stopped".
    @Test func aCancelRacingTheCompletionIsDelivered() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await deliver(rig, composed(2.0))
        // The session doesn't see the bolus finish (20 s at the scripted rate) before its cancel arrives.
        rig.pump.answers[MessageKey(CurrentBolusStatusRequest.self)] = .silent
        await rig.run(for: 20, step: 2)
        // A status read still waiting for its answer goes first; the cancel follows it.
        let session = rig.session
        let cancel = Task { await session.cancelBolus() }
        await rig.run(for: 12, step: 2)
        #expect(await cancel.value == .notCancelled)
        #expect(rig.pump.arrivals(of: CancelBolusRequest.self).count == 1)
        rig.pump.answers[MessageKey(CurrentBolusStatusRequest.self)] = nil
        await rig.run(for: 5)
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 2.0))
        #expect(await rig.ledger.block == nil)
    }

    /// The pump confirms a cancel, then stops answering the bolus status: the amount that went in isn't
    /// known, so the outcome is unknown and blocks until history settles it as stopped.
    @Test func aCancelFollowedByASilentStatusIsUnknownUntilHistorySettlesIt() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await deliver(rig, composed(2.0))
        await rig.run(for: 3)
        rig.pump.answers[MessageKey(CurrentBolusStatusRequest.self)] = .silent
        #expect(await rig.session.cancelBolus() == .cancelled)
        var blockedWhileUnknown = false
        for _ in 0..<60 where await rig.ledger.ledger.outcome(key)?.isUnknown != true {
            await rig.run(for: 2, step: 2)
        }
        #expect(await rig.ledger.ledger.outcome(key)?.isUnknown == true)
        if case .unknownOutcome = await rig.ledger.block { blockedWhileUnknown = true }
        #expect(blockedWhileUnknown)
        // Never settled from a guess: the status reads said nothing, so the cancel isn't taken as the amount.
        #expect(!(await rig.outcomes(key)).contains { if case .stopped = $0 { return true } else { return false } })
        await rig.run(for: 60, step: 2)
        guard case .stopped(let delivered, let requested) = await rig.ledger.ledger.outcome(key) else {
            Issue.record("expected stopped, from history")
            return
        }
        #expect(delivered > 0 && delivered < 2.0)
        #expect(requested == 2.0)
        #expect(await rig.ledger.block == nil)
    }

    /// A cancel with no answer from the pump doesn't stop the bolus as far as the app knows: the cancel is
    /// unconfirmed, and the outcome is whatever the pump reports, here the full amount.
    @Test func aCancelThatFailsLeavesTheDoseToItsOutcome() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.answers[MessageKey(CancelBolusRequest.self)] = .silent
        })
        await rig.startHeld()
        _ = await deliver(rig, composed(2.0))
        await rig.run(for: 3)
        let session = rig.session
        let cancel = Task { await session.cancelBolus() }
        await rig.run(for: 12)
        #expect(await cancel.value == .unconfirmed)
        #expect(rig.pump.activeBolus != nil)
        await rig.run(for: 15)
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 2.0))
    }
}

/// Unknown outcomes settled from the paired pump's history. Ported from the old app's suite.
@MainActor
@Suite struct ReconcileByHistoryTests {
    private func unknown(_ id: Int, units: Double, pumpKey: String = "tandem|1693", clock: UInt32? = nil)
        -> RemoteBolusLedger
    {
        var saved = RemoteBolusLedger()
        _ = saved.begin(DoseRequest(id: "phone-1", origin: .phone, shape: .now(units: units)))
        saved.markAccepted(key, bolusId: id, pumpKey: pumpKey, pumpClock: clock)
        saved.markUnknown(key)
        return saved
    }

    private func completed(_ pump: ScriptedPump, id: Int, delivered: Float, requested: Float, status: Int = 3) {
        pump.appendHistory(
            typeId: 20,
            body: ScriptedPump.bolusCompletedBody(
                bolusId: id, completionStatus: status, iob: 0, delivered: delivered, requested: requested))
    }

    private func settled(_ saved: RemoteBolusLedger, _ configure: @escaping (ScriptedPump) -> Void) async -> Rig {
        let rig = Rig(
            ledger: saved,
            configure: {
                $0.unsupportedReads = []
                configure($0)
            })
        await rig.startHeld()
        await rig.run(for: 10)
        return rig
    }

    @Test func aNewerBolusSinceDoesntHideTheOneSought() async {
        let rig = await settled(unknown(500, units: 1.5)) {
            completed($0, id: 500, delivered: 1.5, requested: 1.5)
            completed($0, id: 900, delivered: 3, requested: 3)
        }
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 1.5))
    }

    @Test func aCompleteDeliveryWithinAFloatStepIsDelivered() async {
        let rig = await settled(unknown(500, units: 2.0)) {
            completed($0, id: 500, delivered: 2.0, requested: 2.000001)
        }
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 2.0))
    }

    /// Changed from the old app: a short delivery is `stopped(delivered, requested)`, whatever its
    /// completion status. pumpx2 doesn't name the status, so "cancelled" isn't claimed.
    @Test func aShortDeliveryIsStopped() async {
        let rig = await settled(unknown(500, units: 2.0)) {
            completed($0, id: 500, delivered: 1.0, requested: 2.0, status: 0)
        }
        #expect(await rig.ledger.ledger.outcome(key) == .stopped(delivered: 1.0, requested: 2.0))
    }

    @Test func aZeroUnitRecordStillSettles() async {
        let rig = await settled(unknown(500, units: 1.0)) {
            completed($0, id: 500, delivered: 0, requested: 1.0, status: 0)
        }
        #expect(await rig.ledger.ledger.outcome(key) == .stopped(delivered: 0, requested: 1.0))
    }

    @Test func theLaterOfTwoRecordsForOneBolusWins() async {
        let rig = await settled(unknown(505, units: 2.5)) {
            completed($0, id: 505, delivered: 1.0, requested: 2.5)
            completed($0, id: 505, delivered: 2.5, requested: 2.5)
        }
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 2.5))
    }

    /// New: a record whose own requested amount isn't this request's is a different bolus.
    @Test func aRecordForADifferentAmountDoesntSettleIt() async {
        let rig = await settled(unknown(500, units: 1.0)) { completed($0, id: 500, delivered: 3, requested: 3) }
        #expect(await rig.ledger.ledger.outcome(key)?.isUnknown == true)
    }

    @Test func anotherPumpsHistoryIsNeverUsed() async {
        let rig = await settled(unknown(500, units: 1.5, pumpKey: "tandem|42")) {
            completed($0, id: 500, delivered: 1.5, requested: 1.5)
        }
        #expect(await rig.ledger.ledger.outcome(key)?.isUnknown == true)
    }

    @Test func aSearchWithNoMatchStaysUnknown() async {
        let rig = await settled(unknown(500, units: 1.0)) { completed($0, id: 400, delivered: 1, requested: 1) }
        #expect(await rig.ledger.ledger.outcome(key)?.isUnknown == true)
    }

    /// A long history is searched a bounded number of pages, never walked to the start.
    @Test func theSearchStopsAtItsPageLimit() async {
        let rig = await settled(unknown(500, units: 1.0)) { pump in
            for i in 0..<3000 {
                pump.appendHistory(typeId: 16, at: pump.wallClockAtStart - UInt32(3000 - i), body: [0, 0])
            }
        }
        let config = PumpSession.Configuration()
        let searchPages = rig.pump.arrivals(of: HistoryLogRequest.self).count
        #expect(searchPages <= config.reconcileMaxPages + config.historyMaxPages)
        #expect(await rig.ledger.ledger.outcome(key)?.isUnknown == true)
    }

    /// Tries are bounded each connection and start again on the next.
    @Test func triesAreBoundedPerConnection() async {
        let rig = await settled(unknown(500, units: 1.0)) { _ in }
        await rig.run(for: 15 * 60, step: 30)
        #expect(await rig.session.reconcileAttempts == PumpSession.Configuration().reconcileAttemptsPerConnection)
        rig.transport.drop()
        await rig.settle()
        await rig.run(for: 20, step: 1)
        #expect(await rig.session.reconcileAttempts == 1)
    }
}

/// A remote dose that asks to include a stale reading, end to end through the session. Ported from the old
/// app's host tests; the composer holds the rules, and these check the dose that reaches the pump.
@MainActor
@Suite struct StaleRemoteDoseHostTests {
    private let access = AccessPolicy.AccessContext(
        phoneReadOnly: false, remotesReadOnly: false, capabilities: .tslimX2, garminBolusEnabled: true)

    private func remote(_ rig: Rig, carbs: Double, estimate: Double, glucose: Int?, includeStale: Bool) async
        -> RemoteDoseDecision
    {
        let prepared = await rig.session.prepareDose()
        let request = RemoteDoseRequest(
            id: "watch-1", peerId: "garmin", surface: .garmin, sentAt: rig.clock.date.addingTimeInterval(-3),
            amount: .calculator(carbsGrams: carbs, estimateUnits: estimate), glucoseMgdl: glucose,
            includeStaleGlucose: includeStale)
        return DoseComposer.composeRemote(
            request, ledger: prepared.ledger, context: prepared.context(access: access, remoteSizeLimitUnits: nil))
    }

    private func rig(glucoseAge: Double) async -> Rig {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.glucose = (200, glucoseAge)
        })
        await rig.startHeld()
        return rig
    }

    private func initiateBG(_ rig: Rig) -> Int? {
        rig.pump.arrivals(of: InitiateBolusRequest.self).first.map { Int($0.cargo[19]) | Int($0.cargo[20]) << 8 }
    }

    /// 30 g at a 10-minute-old 200 mg/dL: 3.00 + 90/40 − 0.50 = 4.75 U, with the reading recorded.
    @Test func includingAStaleReadingDeliversTheCorrectedDoseAndRecordsIt() async throws {
        let rig = await rig(glucoseAge: 600)
        let dose = try #require(await remote(rig, carbs: 30, estimate: 4.75, glucose: 200, includeStale: true).dose)
        _ = await deliver(rig, dose)
        #expect(initiateBG(rig) == 200)
        #expect(await rig.ledger.ledger.entry(dose.request.ledgerKey)?.usedIncludedStaleBG == true)
    }

    @Test func withoutTheAskItIsCarbsOnly() async throws {
        let rig = await rig(glucoseAge: 600)
        let dose = try #require(await remote(rig, carbs: 30, estimate: 3.0, glucose: 200, includeStale: false).dose)
        _ = await deliver(rig, dose)
        #expect(initiateBG(rig) == 0)
        #expect(await rig.ledger.ledger.entry(dose.request.ledgerKey)?.usedIncludedStaleBG == false)
    }

    @Test func aReadingPastTheIncludableAgeIsCarbsOnly() async {
        let rig = await rig(glucoseAge: 20 * 60)
        let decision = await remote(rig, carbs: 30, estimate: 4.75, glucose: 200, includeStale: true)
        #expect(decision.refusal == .doseChanged(estimateUnits: 4.75, doseUnits: 3.0))
    }

    /// A correction with no carbs, from the included reading: 90/40 − 0.50 = 1.75 U.
    @Test func aZeroCarbCorrectionFromAnIncludedReading() async throws {
        let rig = await rig(glucoseAge: 600)
        let dose = try #require(await remote(rig, carbs: 0, estimate: 1.75, glucose: 200, includeStale: true).dose)
        #expect(dose.request.carbsGrams == 0)
        _ = await deliver(rig, dose)
        #expect(initiateBG(rig) == 200)
        #expect(rig.pump.arrivals(of: RemoteCarbEntryRequest.self).isEmpty)
    }
}

@Suite struct CartridgeReadinessFailClosedTests {
    private func readiness(after loadState: Int?) -> CartridgeReadiness {
        var state = PumpState()
        var alerts = PumpAlertLists()
        if let loadState {
            _ = PumpReadings.apply(
                LoadStatusResponse(cargo: [0, UInt8(loadState), 0]), to: &state, alerts: &alerts,
                context: .init(receivedAt: Date(), anchor: nil))
        }
        return state.cartridgeReadiness
    }

    @Test func notReadIsUnknownNotReady() { #expect(readiness(after: nil) == .unknown) }
    @Test func aStateOtherThanLoadingIsReady() {
        for s in [3, 4, 6] { #expect(readiness(after: s) == .ready, "\(s)") }
    }
    @Test func theLoadingStatesAreNotReady() {
        for s in [0, 1, 2] { #expect(readiness(after: s) == .notReady, "\(s)") }
    }
}

/// The ledger's storage rules, seen from the session.
@MainActor
@Suite struct DeliveryLedgerCoordinatorTests {
    @Test func anUnreadableLedgerBlocksEveryBolus() async {
        let store = MemoryLedgerStore()
        store.corrupt = true
        let rig = Rig(ledgerStore: store, configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        #expect(await rig.session.deliver(composed(1.0)) == .notStarted(.blocked(.ledgerUnreadable)))
        #expect(rig.pump.arrivals.filter { $0.characteristic == .control }.isEmpty)
    }

    @Test func aReadableEmptyLedgerDoesntBlock() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        #expect(await rig.ledger.block == nil)
    }

    /// Confirming on the pump lifts the block, the outcome stays unknown, and history can still settle it.
    @Test func confirmingOnThePumpLiftsTheBlockAndHistoryStillSettles() async throws {
        var saved = RemoteBolusLedger()
        _ = saved.begin(DoseRequest(id: "phone-1", origin: .phone, shape: .now(units: 1.0)))
        saved.markAccepted(key, bolusId: 10650, pumpKey: "tandem|1693")
        saved.markUnknown(key)
        let rig = Rig(ledger: saved, configure: { $0.unsupportedReads = [] })
        try await rig.ledger.confirmAllOnPump()
        #expect(await rig.ledger.block == nil)
        rig.pump.appendHistory(
            typeId: 20,
            body: ScriptedPump.bolusCompletedBody(
                bolusId: 10650, completionStatus: 3, iob: 0, delivered: 1, requested: 1))
        await rig.startHeld()
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 1.0))
    }

    /// A move after the request that can't be saved stays in memory and blocks until a save succeeds.
    @Test func anOutcomeThatCantBeSavedBlocks() async {
        let store = MemoryLedgerStore()
        let rig = Rig(ledgerStore: store, configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        store.failFromSave = 3
        _ = await deliver(rig, composed(1.0), for: 20)
        #expect(await rig.ledger.block == .outcomeNotSaved)
        store.failFromSave = nil
        try? await rig.ledger.retrySave()
        #expect(await rig.ledger.block == nil)
    }

    /// The session saves it again on its own: once storage recovers, the block lifts within the retry
    /// interval and the session says so, with no relaunch and nothing for the user to do.
    @Test func anOutcomeThatCantBeSavedIsSavedAgainOnItsOwn() async {
        let store = MemoryLedgerStore()
        let rig = Rig(ledgerStore: store, configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        store.failFromSave = 3
        _ = await deliver(rig, composed(1.0), for: 20)
        #expect(await rig.ledger.block == .outcomeNotSaved)
        let saves = store.saveCount
        await rig.run(for: 12, step: 1)
        #expect(await rig.ledger.block == .outcomeNotSaved, "still failing, still blocked")
        // Tried again on the retry interval (5 s), not on every tick.
        #expect((2...3).contains(store.saveCount - saves), "\(store.saveCount - saves) saves in 12 s")
        store.failFromSave = nil
        await rig.run(for: 6, step: 1)
        #expect(await rig.until { await rig.ledger.block == nil })
        #expect(await rig.events.contains(.bolusOutcomesSaved))
        let outcome = await rig.ledger.ledger.outcome(key)
        #expect(outcome != nil)
        #expect(store.saved?.outcome(key) == outcome, "what blocked is now on disk")
    }
}
