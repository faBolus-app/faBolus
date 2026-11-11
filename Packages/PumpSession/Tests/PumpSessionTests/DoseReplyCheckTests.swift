import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

private let key = RemoteBolusLedger.Key(peerId: "phone", requestId: "phone-1")

/// Delivers with the clock running, as a delivery waits on the link and the pump's timed replies.
@MainActor
private func deliver(_ rig: Rig, _ dose: ComposedDose) async -> DeliveryResult {
    let session = rig.session
    let task = Task { await session.deliver(dose) }
    await rig.run(for: 3)
    return await task.value
}

/// A calculator snapshot with every field the scripted pump sends, and `first` as its first byte.
@MainActor
private func snapshot(_ pump: ScriptedPump, first: UInt8, iobMilliunits: UInt32? = nil, targetMgdl: Int? = nil)
    -> [UInt8]
{
    var v = [UInt8](repeating: 0, count: 46)
    v[0] = first
    v.replaceSubrange(3..<7, with: le32(iobMilliunits ?? pump.calculatorInsulinOnBoardMilliunits))
    v.replaceSubrange(7..<9, with: le16(pump.reservoirUnits))
    v.replaceSubrange(9..<11, with: le16(targetMgdl ?? pump.targetMgdl))
    v.replaceSubrange(11..<13, with: le16(pump.correctionFactor))
    v[13] = 1
    v.replaceSubrange(14..<18, with: le32(pump.carbRatioMilli))
    v.replaceSubrange(18..<20, with: le16(pump.maxBolusMilliunits))
    return v
}

/// The checks on the pump's replies that a dose rests on: the last-bolus record's validity byte, the
/// snapshot's ACK byte, the IOB read again once permission is held, and a cancel the pump refused.
@MainActor
@Suite struct DoseReplyCheckTests {
    /// A last-bolus reply for this bolus that its first byte doesn't mark valid says nothing about what
    /// went in: the outcome comes from history, never from the amount the reply carries.
    @Test func aLastBolusReplyNotMarkedValidIsNotUsed() async throws {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        #expect(await deliver(rig, composed(1.0)) == .started(key, .delivering))
        let id = try #require(rig.pump.activeBolus?.id)
        var invalid = [UInt8](repeating: 0, count: 24)
        invalid.replaceSubrange(1..<3, with: le16(id))
        invalid.replaceSubrange(9..<13, with: le32(9_000))
        invalid.replaceSubrange(20..<24, with: le32(9_000))
        rig.pump.answers[MessageKey(LastBolusStatusV2Request.self)] = .cargo(invalid)

        await rig.run(for: rig.pump.pendingSeconds + rig.pump.deliverySeconds(milliunits: 1_000) + 20)
        #expect(!rig.pump.arrivals(of: LastBolusStatusV2Request.self).isEmpty)
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 1.0))
    }

    /// A snapshot whose first byte isn't the ACK (0) changes nothing: the settings and IOB stay as they
    /// were, so the dose path sees them as not read for this attempt.
    @Test func aSnapshotThePumpDidNotAcknowledgeIsNoReading() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        let before = await rig.session.state.bolusCalculator
        #expect(before?.value.targetMgdl == 110)
        rig.pump.answers[MessageKey(BolusCalcDataSnapshotRequest.self)] = .cargo(
            snapshot(rig.pump, first: 1, targetMgdl: 200))
        await rig.run(for: 1)
        let preparation = await rig.session.prepareDose()
        #expect(preparation.pump.bolusCalculator == before)
        let inputs = CalculatorInputs(
            context: preparation.context(
                access: AccessPolicy.AccessContext(
                    phoneReadOnly: false, remotesReadOnly: false, capabilities: .tslimX2, garminBolusEnabled: true),
                remoteSizeLimitUnits: nil))
        #expect(!inputs.settingsVerified)

        // An acknowledged one is read as usual.
        rig.pump.answers[MessageKey(BolusCalcDataSnapshotRequest.self)] = .cargo(
            snapshot(rig.pump, first: 0, targetMgdl: 200))
        let next = await rig.session.prepareDose()
        #expect(next.pump.bolusCalculator?.value.targetMgdl == 200)
    }

    /// A bolus the pump gave between the dose's reads and its permission (from the pump screen, or by
    /// Control-IQ) shows as IOB the dose wasn't sized from: the permission is released, nothing that
    /// delivers is sent, and new boluses aren't blocked.
    @Test(arguments: [true, false])
    func aRiseInIOBOncePermissionIsHeldStopsTheDose(sizedByTheCalculator: Bool) async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await rig.session.prepareDose()
        rig.pump.calculatorInsulinOnBoardMilliunits = 2_500
        rig.pump.insulinOnBoardMilliunits = 2_500

        let dose = sizedByTheCalculator ? composed(1.0, carbs: 30, iob: 0.5, carbUnits: 1.0) : composed(1.0)
        let result = await deliver(rig, dose)
        #expect(result == .started(key, .failed(reason: PumpSession.iobRoseReason(from: 0.5, to: 2.5))))
        #expect(rig.pump.arrivals(of: BolusPermissionRequest.self).count == 1)
        #expect(rig.pump.arrivals(of: BolusPermissionReleaseRequest.self).count == 1)
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).isEmpty)
        #expect(await rig.ledger.block == nil)
    }

    /// IOB that rose by no more than one pump step, or fell as insulin was absorbed, is the IOB the dose
    /// was sized from: the bolus goes ahead.
    @Test(arguments: [540, 300] as [UInt32])
    func aSmallChangeInIOBStillDelivers(milliunits: UInt32) async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await rig.session.prepareDose()
        rig.pump.calculatorInsulinOnBoardMilliunits = milliunits
        #expect(await deliver(rig, composed(1.0, carbs: 30, iob: 0.5, carbUnits: 1.0)) == .started(key, .delivering))
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).count == 1)
    }

    /// The two IOB readings agreed within a step at preparation (0.50 and 0.55), and the calculator
    /// subtracted the lower. A rise smaller than a step over the higher one is no new bolus: it delivers.
    @Test func aRiseWithinAStepOfEitherReadingStillDelivers() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.calculatorInsulinOnBoardMilliunits = 550
        })
        await rig.startHeld()
        _ = await rig.session.prepareDose()
        rig.pump.calculatorInsulinOnBoardMilliunits = 590
        #expect(
            await deliver(rig, composed(1.0, carbs: 30, iob: 0.5, carbUnits: 1.0)) == .started(key, .delivering))
    }

    /// The pump answers the snapshot read once permission is held with an error: the IOB can't be checked,
    /// so the permission is released and nothing is delivered.
    @Test func anErrorToTheSnapshotOncePermissionIsHeldStopsTheDose() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await rig.session.prepareDose()
        rig.pump.answers[MessageKey(BolusCalcDataSnapshotRequest.self)] = .error(code: 0, drops: false)
        let result = await deliver(rig, composed(1.0))
        #expect(
            result
                == .started(
                    key, .failed(reason: "The pump's active insulin couldn't be read again. Nothing was delivered.")))
        #expect(rig.pump.arrivals(of: BolusPermissionReleaseRequest.self).count == 1)
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).isEmpty)
    }

    /// The snapshot read again once permission is held isn't acknowledged: the IOB can't be checked, so
    /// the permission is released and nothing is delivered.
    @Test func anUnacknowledgedSnapshotOncePermissionIsHeldStopsTheDose() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await rig.session.prepareDose()
        rig.pump.answers[MessageKey(BolusCalcDataSnapshotRequest.self)] = .cargo(snapshot(rig.pump, first: 1))
        let result = await deliver(rig, composed(1.0))
        guard case .started(_, .failed) = result else {
            Issue.record("expected failed, got \(result)")
            return
        }
        #expect(rig.pump.arrivals(of: BolusPermissionReleaseRequest.self).count == 1)
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).isEmpty)
    }

    /// The pump answers the cancel with an error: it didn't take the request, which says nothing about the
    /// bolus, so the cancel is unconfirmed (check the pump, cancel there), not "didn't cancel".
    @Test func aCancelThePumpAnswersWithAnErrorIsUnconfirmed() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        #expect(await deliver(rig, composed(2.0)) == .started(key, .delivering))
        rig.pump.answers[MessageKey(CancelBolusRequest.self)] = .error(code: 7, drops: false)
        let session = rig.session
        let cancel = Task { await session.cancelBolus() }
        await rig.run(for: 5)
        #expect(await cancel.value == .unconfirmed)
        #expect(rig.pump.arrivals(of: CancelBolusRequest.self).count == 1)
    }
}
