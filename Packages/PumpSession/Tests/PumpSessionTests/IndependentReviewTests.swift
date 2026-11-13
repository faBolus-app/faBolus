import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

private let key = RemoteBolusLedger.Key(peerId: "phone", requestId: "phone-1")

/// The target pump (API 4.0, P2) has no recorded evidence for most reads, so they go as probes, and the
/// first op-77 stops the untested ones for the connection. The essential reads go first and the reads its
/// class is suspected of rejecting go last, so a rejected one never costs the clock, the bolus status, the
/// calculator inputs or a cancel.
@MainActor
@Suite struct TargetPumpTests {
    private func p2(_ pump: ScriptedPump) {
        pump.apiVersion = (4, 0)
        pump.serialNumber = 1693
        pump.unsupportedReads = []
        pump.answers[MessageKey(HomeScreenMirrorRequest.self)] = .error(code: 1, drops: false)
    }

    @Test func aRejectedSuspectedReadDoesntStopTheEssentialOnes() async {
        let rig = Rig(configure: p2)
        await rig.startHeld()
        let state = await rig.session.state
        #expect(state.bolusCalculator?.value.insulinOnBoardUnits == 0.5)
        #expect(state.insulinOnBoard?.value == 0.5)
        #expect(state.bolusState?.value == .noBolus)
        #expect(state.glucose?.value.mgdl == 120)
        guard case .started(_, .delivering) = await rig.session.deliver(composed(1.0)) else {
            Issue.record("a delivery must still go through")
            return
        }
        #expect(await rig.session.cancelBolus() == .cancelled)
    }
}

@MainActor
@Suite struct CancelFallbackTests {
    /// The pump can't be asked which bolus it is delivering: the newest bolus that may still be delivering
    /// is cancelled by its recorded ID, never reported as "no bolus".
    @Test func aFailedStatusReadFallsBackToTheRecordedBolus() async {
        var saved = RemoteBolusLedger()
        _ = saved.begin(DoseRequest(id: "phone-1", origin: .phone, shape: .now(units: 5)))
        saved.markAccepted(key, bolusId: 10650, pumpKey: "tandem|1693")
        let rig = Rig(
            ledger: saved,
            configure: {
                $0.unsupportedReads = []
                $0.startBolus(id: 10650, milliunits: 5000)
            })
        await rig.startHeld()
        rig.pump.answers[MessageKey(CurrentBolusStatusRequest.self)] = .silent
        let session = rig.session
        // The status read waits out its 60 s deadline; a routine read that takes the wire before the cancel
        // goes out holds it for its own, since requests go one at a time.
        let cancel = await rig.run(upTo: 130, step: 1) { await session.cancelBolus() }
        #expect(cancel == .cancelled)
        #expect(rig.pump.arrivals(of: CancelBolusRequest.self).count == 1)
    }

    @Test func aFailedStatusReadWithNothingRecordedIsUnconfirmed() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.pump.answers[MessageKey(CurrentBolusStatusRequest.self)] = .silent
        let session = rig.session
        let cancel = Task { await session.cancelBolus() }
        await rig.run(for: 62, step: 1)
        #expect(await rig.value(of: cancel) == .unconfirmed)
    }
}

@MainActor
@Suite struct ConcurrentDeliveryTests {
    /// A second request while one is being delivered is refused outright, so it can't share or clear the
    /// first one's state, and the first one's cancel still works.
    @Test func aSecondDeliveryWhileOneRunsIsRefused() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.pump.answers[MessageKey(RemoteBgEntryRequest.self)] = .silent
        let session = rig.session
        let first = Task { await session.deliver(composed(1.0, bg: 180)) }
        #expect(await rig.until { rig.pump.arrivals(of: RemoteBgEntryRequest.self).count == 1 })
        #expect(await session.deliver(composed(0.5, id: "phone-2")) == .notStarted(.blocked(.bolusInProgress)))
        #expect(await session.cancelBolus() == .stoppedBeforeStart)
        await rig.run(for: 62, step: 1)
        #expect(await rig.value(of: first) == .started(key, .failed(reason: PumpSession.cancelledBeforeStartReason)))
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).isEmpty)
    }
}

@MainActor
@Suite struct UnknownOnALiveLinkTests {
    /// The InitiateBolus reply names another bolus while the pump delivers this one: unknown, and settled
    /// from history within a minute on the same connection, not at the next routine sync.
    @Test func anUnknownOutcomeIsSearchedForSoon() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.pump.nextAnswers[MessageKey(InitiateBolusRequest.self)] = [.cargo([0x00, 0x0f, 0x27, 0x00, 0x00, 0x00])]
        guard case .started(_, .unknown) = await rig.session.deliver(composed(1.0)) else {
            Issue.record("expected unknown")
            return
        }
        await rig.run(for: 60, step: 1)
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 1.0))
    }
}

@MainActor
@Suite struct RejectedPairingRetryTests {
    @Test func aRejectedStoredPairingIsTriedOnceMoreOnTheNextForeground() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.rejectsPairing = true
        })
        await rig.start()
        #expect(await rig.events.contains(.linkFailed(.pairingRejected)))
        rig.pump.rejectsPairing = false
        await rig.session.setAppActive(false)
        await rig.session.setAppActive(true)
        await rig.settle()
        #expect(await rig.session.state.link == .connected)
    }
}

@MainActor
@Suite struct NoProbeWhileTrackingTests {
    /// On API 4.0 the calculator, IOB and glucose reads have no recorded evidence, so each goes as a probe.
    /// While a bolus is followed none of them goes out, though they come due when the connection holds:
    /// only the bolus's own status reads do. They follow once the bolus is done.
    @Test func untestedReadsWaitUntilTheBolusIsDone() async {
        let rig = Rig(configure: {
            $0.apiVersion = (4, 0)
            $0.unsupportedReads = []
        })
        await rig.start()
        let session = rig.session
        let delivery = Task { await session.deliver(composed(5.0)) }
        #expect(await rig.value(of: delivery) == .started(key, .delivering))
        #expect(await session.tracked != nil)
        #expect(await session.isUntested(ControlIQIOBRequest()))
        let before = rig.pump.arrivals.count

        // Past the hold window, with the bolus (15 s pending, then 0.025 U/s) still delivering.
        await rig.run(for: 40, step: 1)
        #expect(await session.tracked != nil)
        let whileTracked = rig.pump.arrivals[before...].map {
            MessageKey(characteristic: $0.characteristic, opCode: $0.opCode)
        }
        #expect(whileTracked.contains(MessageKey(CurrentBolusStatusRequest.self)))
        for probe in [
            MessageKey(ControlIQIOBRequest.self), MessageKey(BolusCalcDataSnapshotRequest.self),
            MessageKey(CurrentEgvGuiDataV2Request.self)
        ] {
            #expect(!whileTracked.contains(probe))
        }

        await rig.run(for: rig.pump.deliverySeconds(milliunits: 5000) - 40 + 5, step: 1)
        #expect(await session.tracked == nil)
        #expect(!rig.pump.arrivals(of: ControlIQIOBRequest.self).isEmpty)
    }
}

@MainActor
@Suite struct InitiateDeadlineTests {
    /// The BG entry goes unanswered while `elapsed` passes, as when the app is suspended mid-delivery;
    /// the carb entry is answered at once. Returns the delivery's outcome.
    private func deliver(after elapsed: Double, rig: Rig) async -> DeliveryResult? {
        await rig.startHeld()
        rig.pump.nextAnswers[MessageKey(RemoteBgEntryRequest.self)] = [.silent]
        let session = rig.session
        let delivery = Task { await session.deliver(composed(1.0, carbs: 20, bg: 180, carbUnits: 1.0)) }
        #expect(await rig.until { rig.pump.arrivals(of: RemoteBgEntryRequest.self).count == 1 })
        // One step: the entry times out inside it, and nothing else moves the clock before the check.
        rig.clock.advance(by: elapsed)
        return await rig.value(of: delivery)
    }

    @Test func justUnderTwoMinutesAfterConfirmTheBolusStarts() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        #expect(await deliver(after: 119, rig: rig) == .started(key, .delivering))
        #expect(rig.pump.arrivals(of: RemoteCarbEntryRequest.self).count == 1)
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).count == 1)
    }

    @Test func justOverTwoMinutesAfterConfirmNothingIsStarted() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        let result = await deliver(after: 121, rig: rig)
        #expect(
            result
                == .started(
                    key, .failed(reason: "Too long passed since the bolus was confirmed, so it wasn't started.")))
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).isEmpty)
        #expect(rig.pump.arrivals(of: BolusPermissionReleaseRequest.self).count == 1)
        #expect(await rig.ledger.block == nil)
    }
}
