import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

extension PumpSession {
    fileprivate func misses(_ key: MessageKey) -> Int { unanswered[key]?.count ?? 0 }
}

@MainActor
@Suite struct SessionHousekeepingTests {
    private func graceRig() async -> Rig {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.apiVersion = (major: 4, minor: 0)
        })
        await rig.startHeld()
        return rig
    }

    private func graceDetail(_ rig: Rig) async -> String? {
        await rig.session.state.alerts?.value.first { $0.kind == .cgmAlert && $0.id == 32 }?.detail
    }

    /// The phone's clock set back an hour doesn't move the grace period's end: the time left still counts
    /// down from the read.
    @Test func theGraceTimeLeftFollowsAPhoneClockSet() async {
        let rig = await graceRig()
        rig.pump.graceSecondsLeft = 2200
        rig.pump.cgmAlertBitmap = 1 << 32
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        #expect(await graceDetail(rig) == "About 2 hours of the sensor's grace period are left.")
        rig.clock.setWallClock(by: -3600)
        await rig.run(for: 120)
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        #expect(await graceDetail(rig) == "About 30 minutes of the sensor's grace period are left.")
    }

    /// The grace-period read lost to a drop is asked again on the next connection.
    @Test func aGraceReadLostToADropIsAskedAgain() async {
        let rig = await graceRig()
        rig.pump.graceSecondsLeft = 3600
        rig.pump.nextAnswers[MessageKey(CgmStatusV2Request.self)] = [.drop(acted: false)]
        rig.pump.cgmAlertBitmap = 1 << 32
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        await rig.untilConnected()
        await rig.run(for: 20, step: 1)
        #expect(rig.pump.arrivals(of: CgmStatusV2Request.self).count == 2)
        #expect(await graceDetail(rig) == "About 2 hours of the sensor's grace period are left.")
    }

    /// A pump notice doesn't ask again a read resting after the pump left it unanswered twice.
    @Test func aNoticeDoesntAskARestingRead() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.pump.answers[MessageKey(InsulinStatusRequest.self)] = .silent
        let resting = MessageKey(InsulinStatusRequest.self)
        for _ in 0..<200 where await rig.session.misses(resting) < 2 {
            await rig.run(for: 5, step: 1)
        }
        let now = await rig.session.uptime()
        #expect(await rig.session.restingAfterNoAnswer(InsulinStatusRequest(), now: now))
        let asked = rig.pump.arrivals(of: InsulinStatusRequest.self).count
        rig.transport.qualifyingEvents(.remainingInsulin)
        await rig.run(for: 5, step: 1)
        #expect(rig.pump.arrivals(of: InsulinStatusRequest.self).count == asked)
    }

    /// A UserInteraction this pump's class is suspected of rejecting isn't sent when the bolus screen
    /// opens: its rejection could drop the link just before a dose.
    @Test func aSuspectedUserInteractionIsntSent() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = [MessageKey(UserInteractionRequest.self)]
            $0.apiVersion = (major: 4, minor: 0)
        })
        await rig.startHeld()
        let session = rig.session
        // The rejection's drop comes on the pump's clock, so the clock is moved until the write is answered.
        await rig.run(upTo: 30) { await session.bolusScreenOpened() }
        await rig.untilConnected(limit: 30)
        await rig.run(for: 12, step: 1)
        #expect(rig.pump.arrivals(of: UserInteractionRequest.self).count == 1)
        await rig.run(upTo: 30) { await session.bolusScreenOpened() }
        #expect(rig.pump.arrivals(of: UserInteractionRequest.self).count == 1)
    }

    /// A clear waiting for the pump after a drop waits for this connection's alert read, not the list the
    /// last connection left; one whose wait ends with no such read sends nothing and is unconfirmed.
    @Test func aWaitingClearWaitsForThisConnectionsAlerts() async throws {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.alertBitmap = 1 << 7
        })
        await rig.startHeld()
        let alert = try #require(await rig.session.state.alerts?.value.first)
        rig.pump.answers[MessageKey(AlertStatusRequest.self)] = .silent
        rig.transport.drop()
        let session = rig.session
        let early = Task { await session.dismiss(alert, waitingForLinkUpTo: 20) }
        let dismiss = Task { await session.dismiss(alert, waitingForLinkUpTo: 150) }
        await rig.untilConnected()
        await rig.run(for: 25, step: 1)
        #expect(await rig.value(of: early) == .unconfirmed)
        #expect(rig.pump.arrivals(of: DismissNotificationRequest.self).isEmpty)
        rig.pump.answers[MessageKey(AlertStatusRequest.self)] = .normal
        await rig.run(for: 120, step: 2)
        _ = await rig.value(of: dismiss)
        #expect(rig.pump.arrivals(of: DismissNotificationRequest.self).count == 1)
    }
}
