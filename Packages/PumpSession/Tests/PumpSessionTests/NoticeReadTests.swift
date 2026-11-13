import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing
import faBolusCore

@testable import PumpSession

/// A qualifying-event notice brings the reads its bits name, as t:connect sends them, and a history sync.
/// The bit values are confirmed; whether a t:slim raises each bit on every change is not.
@MainActor
@Suite struct NoticeReadTests {
    func heldRig() async -> Rig {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        return rig
    }

    func count(_ rig: Rig, _ type: (some Message).Type) -> Int { rig.pump.arrivals(of: type).count }

    /// Each read arrives once more after the notice, with no timer due.
    func expectRead(
        _ events: QualifyingEvent, _ types: [any Message.Type], sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let rig = await heldRig()
        let before = types.map { rig.pump.arrivals(of: $0).count }
        rig.transport.qualifyingEvents(events)
        await rig.settle()
        for (type, was) in zip(types, before) {
            #expect(rig.pump.arrivals(of: type).count == was + 1, "\(type)", sourceLocation: sourceLocation)
        }
    }

    @Test func aBolusNoticeReadsTheBolusStatus() async {
        await expectRead(.bolusChange, [CurrentBolusStatusRequest.self])
    }

    @Test func anIOBNoticeReadsTheIOB() async {
        await expectRead(.iobChange, [ControlIQIOBRequest.self])
    }

    @Test func aCGMNoticeReadsTheGlucoseAndThePumpClock() async {
        await expectRead(
            .cgmChange,
            [
                CGMStatusRequest.self, CurrentEGVGuiDataRequest.self, HomeScreenMirrorRequest.self,
                TimeSinceResetRequest.self
            ])
    }

    @Test func aTimeNoticeReadsThePumpClockAndTheIOB() async {
        await expectRead(.timeChange, [ControlIQIOBRequest.self, CGMStatusRequest.self, TimeSinceResetRequest.self])
    }

    @Test func aSuspendOrResumeNoticeReadsTheCartridgeAndTheIOB() async {
        await expectRead(.pumpSuspend, [InsulinStatusRequest.self, ControlIQIOBRequest.self])
        await expectRead(
            .pumpResume, [InsulinStatusRequest.self, ControlIQIOBRequest.self, CurrentEGVGuiDataRequest.self])
    }

    @Test func aHomeScreenOrBasalNoticeReadsTheBasal() async {
        await expectRead(
            .homeScreenChange,
            [
                CurrentBasalStatusRequest.self, CurrentEGVGuiDataRequest.self, HomeScreenMirrorRequest.self,
                ControlIQInfoV2Request.self
            ])
        await expectRead(
            .basalChange,
            [
                ControlIQIOBRequest.self, HomeScreenMirrorRequest.self, CurrentBasalStatusRequest.self,
                TempRateRequest.self
            ])
    }

    @Test func batteryCartridgeAndControlIQNoticesReadWhatTheyName() async {
        await expectRead(.battery, [CurrentBatteryV2Request.self])
        await expectRead(.controlIQInfo, [ControlIQIOBRequest.self, ControlIQInfoV2Request.self])
    }

    /// Each alert bit reads its own list, not all five.
    @Test func anAlertNoticeReadsOnlyItsOwnList() async {
        let rig = await heldRig()
        let alarms = count(rig, AlarmStatusRequest.self)
        let alerts = count(rig, AlertStatusRequest.self)
        rig.transport.qualifyingEvents(.alert)
        await rig.settle()
        #expect(count(rig, AlertStatusRequest.self) == alerts + 1)
        #expect(count(rig, AlarmStatusRequest.self) == alarms)
    }

    /// Several bits that name the same read send it once.
    @Test func aReadTwoBitsNameGoesOnce() async {
        let rig = await heldRig()
        let iob = count(rig, ControlIQIOBRequest.self)
        rig.transport.qualifyingEvents([.iobChange, .timeChange, .basalChange])
        await rig.settle()
        #expect(count(rig, ControlIQIOBRequest.self) == iob + 1)
    }

    /// A notice for nothing faBolus reads (a BG entry) sends no read but still a history sync.
    @Test func everyNoticeBringsAHistorySync() async {
        let rig = await heldRig()
        let syncs = count(rig, HistoryLogStatusRequest.self)
        let iob = count(rig, ControlIQIOBRequest.self)
        rig.transport.qualifyingEvents(.bg)
        await rig.settle()
        #expect(count(rig, HistoryLogStatusRequest.self) == syncs + 1)
        #expect(count(rig, ControlIQIOBRequest.self) == iob)
    }

    /// Notices during a sync bring one more sync after it, not one each.
    @Test func noticesDuringASyncBringOneMoreSync() async {
        let rig = await heldRig()
        let syncs = count(rig, HistoryLogStatusRequest.self)
        rig.pump.nextAnswers[MessageKey(HistoryLogStatusRequest.self)] = [.silent]
        rig.transport.qualifyingEvents(.bolusChange)
        await rig.settle()
        #expect(await rig.session.historyBusy)
        rig.transport.qualifyingEvents(.bolusChange)
        rig.transport.qualifyingEvents(.iobChange)
        await rig.run(for: 70, step: 1)
        #expect(count(rig, HistoryLogStatusRequest.self) == syncs + 2)
    }

    /// The routine sync stays the backstop: with no notice, the next one is 15 minutes after the last.
    @Test func withoutANoticeTheRoutineSyncStays() async {
        let rig = await heldRig()
        let syncs = count(rig, HistoryLogStatusRequest.self)
        await rig.run(for: 14 * 60, step: 5)
        #expect(count(rig, HistoryLogStatusRequest.self) == syncs)
        await rig.run(for: 2 * 60, step: 5)
        #expect(count(rig, HistoryLogStatusRequest.self) == syncs + 1)
    }

    @Test func aCartridgeNoticeReadsTheInsulinLeftAndTheCartridge() async {
        await expectRead(.remainingInsulin, [InsulinStatusRequest.self, LoadStatusRequest.self])
    }

    @Test func alertBitsReadAtTheAlertsPriorityAndTheRestAtStatus() {
        let reads = NoticeReads.reads(for: [.alarm, .bolusChange])
        let keys = reads.map { (read, _) in MessageKey(read) }
        #expect(keys == [MessageKey(AlarmStatusRequest.self), MessageKey(CurrentBolusStatusRequest.self)])
        #expect(reads.map(\.1) == [.alerts, .status])
    }
}

/// The link clears the qualifying events when it becomes ready and after every notice, against a pump that
/// keeps each bit set, and sends no new notice for it, until the phone clears it (guess #30).
@MainActor
@Suite struct NoticeClearTests {
    func rig(holding held: QualifyingEvent = []) -> Rig {
        Rig(configure: {
            $0.unsupportedReads = []
            $0.holdsNoticesUntilCleared = true
            $0.heldNotices = held
        })
    }

    /// A bit left set by an earlier connection would hide the next notice of its kind: it is cleared as
    /// soon as the link is ready, so the next alert's notice arrives and brings its read.
    @Test func aBitLeftFromAnEarlierConnectionIsClearedOnReady() async {
        let rig = rig(holding: [.alert])
        await rig.startHeld()
        #expect(rig.pump.heldNotices.isEmpty)
        #expect(rig.pump.noticeClears >= 1)
        let before = rig.pump.arrivals(of: AlertStatusRequest.self).count
        rig.transport.qualifyingEvents(.alert)
        await rig.settle()
        #expect(rig.pump.arrivals(of: AlertStatusRequest.self).count == before + 1)
    }

    /// A notice that arrives while a signed write is on the wire isn't cleared then: its clear goes once
    /// the write's reply frees the wire, so the bolus's own notice doesn't stay set.
    @Test func aNoticeDuringASignedWriteIsClearedOnceItsReplyArrives() async {
        let rig = rig()
        await rig.startHeld()
        let clears = rig.pump.noticeClears
        rig.pump.nextAnswers[MessageKey(InitiateBolusRequest.self)] = [.notice(.bolusChange)]
        let session = rig.session
        let result = await rig.run(for: 3, upTo: 120) { await session.deliver(composed(1.0)) }
        #expect(result == .started(RemoteBolusLedger.Key(peerId: "phone", requestId: "phone-1"), .delivering))
        #expect(rig.pump.heldNotices.isEmpty)
        #expect(rig.pump.noticeClears > clears)
    }

    /// While a bit is held the pump sends nothing for it, so a second change of that kind goes unseen
    /// until a notice for another bit carries it: what the clears guard against.
    @Test func aHeldBitIsSeenOnlyWithTheNextNotice() async {
        let rig = rig()
        await rig.startHeld()
        rig.pump.heldNotices = [.battery]
        let before = rig.pump.arrivals(of: CurrentBatteryV2Request.self).count
        rig.transport.qualifyingEvents(.battery)
        await rig.settle()
        #expect(rig.pump.arrivals(of: CurrentBatteryV2Request.self).count == before)
        rig.transport.qualifyingEvents(.alert)
        await rig.settle()
        #expect(rig.pump.arrivals(of: CurrentBatteryV2Request.self).count == before + 1)
        #expect(rig.pump.heldNotices.isEmpty)
    }
}
