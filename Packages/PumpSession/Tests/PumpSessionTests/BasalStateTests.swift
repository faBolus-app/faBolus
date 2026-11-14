import Foundation
import PumpScript
import TandemMessages
import Testing
import faBolusCore

@testable import PumpSession

/// The basal state from the pump's home-screen basal icon, its basal rate and a temp rate's percent, as
/// t:connect's dashboard shows it. The icon's byte is pumpX2's; which icon a t:slim shows when is unconfirmed.
@Suite struct BasalStateReadingTests {
    private var state = PumpState()
    private var alerts = PumpAlertLists()
    private var basal = PumpBasalParts()
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    private mutating func apply(_ message: any TandemMessages.Message, after seconds: TimeInterval = 1) {
        now.addTimeInterval(seconds)
        _ = PumpReadings.apply(
            message, to: &state, alerts: &alerts, basal: &basal, context: .init(receivedAt: now, anchor: nil))
    }

    private func mirror(basal icon: UInt8) -> HomeScreenMirrorResponse {
        var cargo = [UInt8](repeating: 0, count: 9)
        cargo[0] = 4
        cargo[1] = 255
        cargo[5] = icon
        return HomeScreenMirrorResponse(cargo: cargo)
    }

    private func rate(_ milliunits: UInt32) -> CurrentBasalStatusResponse {
        CurrentBasalStatusResponse(cargo: le32(milliunits) + le32(milliunits) + [0])
    }

    private func tempRate(percent: UInt8?) -> TempRateResponse {
        TempRateResponse(cargo: [percent == nil ? 0 : 1, percent ?? 0] + le32(500_000_000) + le32(1800))
    }

    @Test mutating func aSuspendIconIsSuspendedUntilTheIconSaysOtherwise() {
        apply(rate(800))
        #expect(state.basalDeliveryState?.value == .active(unitsPerHour: 0.8))
        apply(mirror(basal: 4))
        #expect(state.basalDeliveryState?.value == .suspended)
        // A rate read during the suspension doesn't end it, and is the rate once delivery is back.
        apply(rate(0))
        #expect(state.basalDeliveryState?.value == .suspended)
        apply(rate(900))
        #expect(state.basalDeliveryState?.value == .suspended)
        apply(mirror(basal: 0))
        #expect(state.basalDeliveryState?.value == .active(unitsPerHour: 0.9))
    }

    @Test mutating func aSuspensionNeedsNoRate() {
        apply(mirror(basal: 4))
        #expect(state.basalDeliveryState?.value == .suspended)
        apply(mirror(basal: 0))
        #expect(state.basalDeliveryState == nil)
    }

    @Test mutating func aTempRateIconShowsTheRateWithItsPercentOnceRead() {
        apply(rate(1200))
        apply(mirror(basal: 2))
        #expect(state.basalDeliveryState?.value == .tempRate(unitsPerHour: 1.2, percent: nil))
        #expect(basal.needsTempPercent)
        apply(tempRate(percent: 150))
        #expect(state.basalDeliveryState?.value == .tempRate(unitsPerHour: 1.2, percent: 150))
        #expect(!basal.needsTempPercent)
        // The same icon again keeps the percent.
        apply(mirror(basal: 2))
        #expect(state.basalDeliveryState?.value == .tempRate(unitsPerHour: 1.2, percent: 150))
    }

    /// The next temp rate's percent is read again, not taken from the last one.
    @Test mutating func theTempRatesPercentGoesWhenTheIconStopsShowingIt() {
        apply(rate(1200))
        apply(mirror(basal: 2))
        apply(tempRate(percent: 150))
        apply(mirror(basal: 0))
        #expect(state.basalDeliveryState?.value == .active(unitsPerHour: 1.2))
        apply(mirror(basal: 2))
        #expect(state.basalDeliveryState?.value == .tempRate(unitsPerHour: 1.2, percent: nil))
    }

    @Test mutating func aTempRateReplyWithoutTheIconChangesNothing() {
        apply(rate(800))
        apply(tempRate(percent: 150))
        #expect(state.basalDeliveryState?.value == .active(unitsPerHour: 0.8))
        apply(mirror(basal: 2))
        #expect(state.basalDeliveryState?.value == .tempRate(unitsPerHour: 0.8, percent: nil))
    }

    @Test mutating func aTempRateThatSaysNoneRunningLeavesNoPercent() {
        apply(rate(800))
        apply(mirror(basal: 2))
        apply(tempRate(percent: nil))
        #expect(state.basalDeliveryState?.value == .tempRate(unitsPerHour: 0.8, percent: nil))
        #expect(!basal.needsTempPercent)
    }

    /// t:connect reads no percent for a zero temp rate, and nothing is delivered whatever rate was last read.
    @Test mutating func aZeroTempRateIconIsATempRateOfZeroPercent() {
        apply(rate(800))
        apply(mirror(basal: 3))
        #expect(state.basalDeliveryState?.value == .tempRate(unitsPerHour: 0, percent: 0))
        #expect(!basal.needsTempPercent)
        var unread = PumpBasalParts()
        unread.icon = Observed(.zeroTempRate, measuredAt: now, receivedAt: now)
        #expect(unread.state?.value == .tempRate(unitsPerHour: 0, percent: 0))
    }

    /// Basal-IQ's suspension is its own state, not the pump's: a bolus still goes. It rests on the icon alone.
    @Test mutating func aBasalIQSuspendIconIsBasalIQsSuspension() {
        apply(rate(800))
        apply(mirror(basal: 5))
        #expect(state.basalDeliveryState?.value == .basalIQSuspended)
        #expect(state.basalDeliveryState?.value.isSuspended == false)
        apply(mirror(basal: 0))
        #expect(state.basalDeliveryState?.value == .active(unitsPerHour: 0.8))
    }

    /// Without the mirror, or with an icon TandemKit doesn't name, the rate shows as before.
    @Test mutating func anOtherOrUnknownIconShowsTheRate() {
        apply(rate(800))
        for icon: UInt8 in [0, 1, 6, 7, 200, 99] {
            apply(mirror(basal: icon))
            #expect(state.basalDeliveryState?.value == .active(unitsPerHour: 0.8), "\(icon)")
        }
    }

    /// The state is as old as the oldest read it rests on.
    @Test mutating func theStateIsDatedByItsOldestRead() {
        apply(mirror(basal: 0))
        let iconAt = now
        apply(rate(800), after: 600)
        #expect(state.basalDeliveryState?.measuredAt == iconAt)
        apply(mirror(basal: 0), after: 60)
        #expect(state.basalDeliveryState?.measuredAt == now.addingTimeInterval(-60))
    }

    @Test mutating func aPhoneClockStepMovesTheParts() {
        apply(rate(800))
        apply(mirror(basal: 0))
        let iconAt = now
        basal.phoneClockSet(by: -3600)
        apply(rate(800), after: 1)
        #expect(state.basalDeliveryState?.measuredAt == iconAt.addingTimeInterval(-3600))
    }
}

/// Through the session: the reads the basal icon brings, and the state they give.
@MainActor
@Suite struct BasalStateSessionTests {
    func heldRig() async -> Rig {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        return rig
    }

    @Test func aSuspendedPumpShowsSuspendedAfterAHomeScreenNotice() async {
        let rig = await heldRig()
        #expect(await rig.session.state.basalDeliveryState?.value == .active(unitsPerHour: 0.8))
        rig.pump.basalIcon = 4
        rig.pump.basalMilliunitsPerHour = 0
        rig.transport.qualifyingEvents(.homeScreenChange)
        await rig.settle()
        #expect(await rig.session.state.basalDeliveryState?.value == .suspended)
        rig.pump.basalIcon = 0
        rig.pump.basalMilliunitsPerHour = 800
        rig.transport.qualifyingEvents(.homeScreenChange)
        await rig.settle()
        #expect(await rig.session.state.basalDeliveryState?.value == .active(unitsPerHour: 0.8))
    }

    /// The icon showing a temp rate brings one TempRate read, as t:connect sends it, and its percent shows.
    @Test func aTempRateIconBringsOneTempRateRead() async {
        let rig = await heldRig()
        let reads = rig.pump.arrivals(of: TempRateRequest.self).count
        rig.pump.basalIcon = 2
        rig.pump.tempRatePercent = 150
        rig.pump.basalMilliunitsPerHour = 1200
        rig.transport.qualifyingEvents(.homeScreenChange)
        await rig.settle()
        #expect(await rig.session.state.basalDeliveryState?.value == .tempRate(unitsPerHour: 1.2, percent: 150))
        #expect(rig.pump.arrivals(of: TempRateRequest.self).count == reads + 1)
        await rig.session.refreshGlucose()
        await rig.settle()
        #expect(rig.pump.arrivals(of: TempRateRequest.self).count == reads + 1)
    }

    /// A TempRate the pump refuses isn't asked for again after every other reply.
    @Test func aRefusedPercentIsAskedForOnlyAfterAMirror() async {
        let rig = await heldRig()
        rig.pump.basalIcon = 2
        rig.pump.nextAnswers[MessageKey(TempRateRequest.self)] = [.error(code: 0, drops: false)]
        rig.transport.qualifyingEvents(.homeScreenChange)
        await rig.settle()
        let reads = rig.pump.arrivals(of: TempRateRequest.self).count
        #expect(await rig.session.state.basalDeliveryState?.value == .tempRate(unitsPerHour: 0.8, percent: nil))
        rig.transport.qualifyingEvents([.iobChange, .battery])
        await rig.settle()
        #expect(rig.pump.arrivals(of: TempRateRequest.self).count == reads)
    }
}
