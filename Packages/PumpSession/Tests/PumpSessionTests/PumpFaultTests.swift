import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

private let key = RemoteBolusLedger.Key(peerId: "phone", requestId: "phone-1")

/// Damaged replies from the scripted pump: the session takes nothing from one, and a dose whose reply
/// was damaged after the pump acted is never taken as failed or delivered from it.
@MainActor
@Suite struct DamagedReplyTests {
    /// A reading whose reply fails its CRC isn't taken.
    @Test func aReadingWithABadCRCIsNotTaken() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.answers[MessageKey(InsulinStatusRequest.self)] = .badCRC
        })
        await rig.startHeld()
        #expect(!rig.pump.arrivals(of: InsulinStatusRequest.self).isEmpty)
        #expect(await rig.session.state.reservoirUnits == nil)
        #expect(await rig.session.state.battery?.value == PumpBattery(percent: 80, isCharging: false))
    }

    /// The pump starts the bolus but its signed answer fails the signature check: the outcome is unknown
    /// and blocks, never failed, until the pump's own status or history settles it.
    @Test func anInitiateAnswerWithABadSignatureIsUnknown() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.answers[MessageKey(InitiateBolusRequest.self)] = .badSignature
        })
        await rig.startHeld()
        guard case .started(_, .unknown) = await rig.session.deliver(composed(1.0)) else {
            Issue.record("expected unknown")
            return
        }
        #expect(rig.pump.activeBolus != nil)
        #expect(!(await rig.outcomes(key)).contains { if case .failed = $0 { return true } else { return false } })
    }

    /// A permission answer carrying another request's txId isn't taken as the grant: no InitiateBolus goes
    /// out.
    @Test func aPermissionAnswerWithTheWrongTxIdStartsNothing() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.answers[MessageKey(BolusPermissionRequest.self)] = .wrongTxId
        })
        await rig.startHeld()
        let session = rig.session
        let delivery = Task { await session.deliver(composed(1.0)) }
        await rig.run(for: 70, step: 1)
        _ = await rig.value(of: delivery)
        #expect(!rig.pump.arrivals(of: BolusPermissionRequest.self).isEmpty)
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).isEmpty)
        #expect(rig.pump.activeBolus == nil)
    }

    /// An InitiateBolus answer that arrives twice starts one bolus, followed once to its end.
    @Test func aDuplicatedInitiateAnswerStartsOneBolus() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.answers[MessageKey(InitiateBolusRequest.self)] = .duplicate
        })
        await rig.startHeld()
        #expect(await rig.session.deliver(composed(1.0)) == .started(key, .delivering))
        await rig.run(for: rig.pump.deliverySeconds(milliunits: 1000) + 5)
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).count == 1)
        #expect(rig.pump.completed.count == 1)
        #expect(await rig.outcomes(key) == [.requested, .accepted, .delivering, .delivered(units: 1.0)])
    }
}

/// The scripted pump's own notices (`raisesNotices`), each pairing of change and bit unconfirmed.
@MainActor
@Suite struct PumpNoticeTests {
    /// With notices on, a new alert reaches the session as a notice and is read at once.
    @Test func aNewAlertIsNoticedAndRead() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.raisesNotices = true
        })
        await rig.startHeld()
        let before = rig.pump.arrivals(of: AlertStatusRequest.self).count
        rig.pump.alertBitmap = 1 << 7
        await rig.settle()
        #expect(rig.pump.noticesSent == [.alert])
        #expect(rig.pump.arrivals(of: AlertStatusRequest.self).count == before + 1)
        #expect((await rig.session.state.alerts?.value ?? []).contains { $0.id == 7 })
    }

    /// The default pump sends no notice of its own: the session's timed reads must find the change.
    @Test func theDefaultPumpRaisesNoNotice() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        let before = rig.pump.arrivals(of: AlertStatusRequest.self).count
        rig.pump.alertBitmap = 1 << 7
        rig.pump.batteryPercent = 50
        await rig.settle()
        #expect(rig.pump.noticesSent.isEmpty)
        #expect(rig.pump.arrivals(of: AlertStatusRequest.self).count == before)
    }

    /// A bolus raises a bolus-change notice when it's accepted, when it starts to deliver and when it
    /// ends, each at that moment, even with no request arriving.
    @Test func aBolusIsNoticedAtEachStepOnTime() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.raisesNotices = true
        })
        await rig.startHeld()
        _ = await rig.session.deliver(composed(1.0))
        #expect(rig.pump.noticesSent == [.bolusChange])
        rig.pump.silent = true
        await rig.run(for: rig.pump.deliverySeconds(milliunits: 1000) + 1)
        #expect(rig.pump.activeBolus == nil)
        #expect(rig.pump.noticesSent == [.bolusChange, .bolusChange, .bolusChange])
    }
}
