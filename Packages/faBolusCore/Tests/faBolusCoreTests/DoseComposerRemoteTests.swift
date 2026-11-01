import Foundation
import Testing

@testable import faBolusCore

/// One test per remote-dose check, each from `DoseComposer.composeRemote`.
@Suite struct DoseComposerRemoteTests {
    typealias F = DoseFixtures

    private func compose(
        _ request: RemoteDoseRequest, ledger: RemoteBolusLedger = .init(), context: DoseContext = F.context()
    ) -> RemoteDoseDecision {
        DoseComposer.composeRemote(request, ledger: ledger, context: context)
    }

    /// A ledger holding `dose`, delivered in full at `F.now`.
    private func delivered(_ dose: ComposedDose) -> RemoteBolusLedger {
        var ledger = RemoteBolusLedger()
        _ = ledger.begin(dose.request, now: F.now)
        ledger.markAccepted(dose.request.ledgerKey, bolusId: 7, now: F.now)
        ledger.markDelivering(dose.request.ledgerKey, now: F.now)
        ledger.markDelivered(dose.request.ledgerKey, units: dose.units, now: F.now)
        return ledger
    }

    // MARK: - The phone recomputes and is authoritative

    @Test func carbRequestDeliversThePhonesRecompute() throws {
        let dose = try #require(compose(F.remote(F.carbs(60, estimate: 7.25))).dose)
        #expect(dose.units == 7.25)
        #expect(dose.request.carbsGrams == 60)
        #expect(dose.request.bgMgdl == 180)
        #expect(dose.correctionGlucoseMgdl == 180)
        #expect(dose.calculatorIOBUnits == 0.5)
        #expect(!dose.usedIncludedStaleGlucose)
        #expect(dose.request.origin == .remote(peerId: "garmin", sentAt: F.now.addingTimeInterval(-3)))
    }

    /// A calculated dose rounds down to the pump's 0.05 U step, never up: 23.8 g at 10 g/U is 2.38 U.
    @Test func calculatedDoseRoundsDown() throws {
        let dose = try #require(
            compose(F.remote(F.carbs(23.8, estimate: 2.35), glucose: nil), context: carbsOnly()).dose)
        #expect(dose.units == 2.35)
    }

    /// Units the user dialed go to the pump as sent: no recompute and no rounding.
    @Test func unitsRequestDeliversUnitsAsSent() throws {
        let dose = try #require(compose(F.remote(.units(2.37))).dose)
        #expect(dose.units == 2.37)
        #expect(dose.request.carbsGrams == nil)
        #expect(dose.calculatorIOBUnits == nil)
        #expect(dose.correctionGlucoseMgdl == nil)
    }

    /// A carbs value of zero is a correction-only dose, not a units request of nothing.
    @Test func zeroCarbsIsACorrection() throws {
        let dose = try #require(compose(F.remote(F.carbs(0, estimate: 1.25))).dose)
        #expect(dose.units == 1.25)
    }

    // MARK: - Access: the only gate

    @Test func remotesReadOnlyRefuses() {
        var access = F.openAccess
        access.remotesReadOnly = true
        #expect(
            compose(F.remote(.units(1)), context: F.context(access: access)).refusal
                == .unavailable(.accessDenied(.remotesReadOnly)))
    }

    @Test func remoteBolusTurnedOffRefuses() {
        var access = F.openAccess
        access.garminBolusEnabled = false
        #expect(
            compose(F.remote(.units(1)), context: F.context(access: access)).refusal
                == .unavailable(.accessDenied(.remoteBolusDisabled)))
    }

    /// The phone's own read-only switch doesn't govern remotes.
    @Test func phoneReadOnlyDoesNotApplyToRemotes() {
        var access = F.openAccess
        access.phoneReadOnly = true
        #expect(compose(F.remote(.units(1)), context: F.context(access: access)).dose != nil)
    }

    @Test func aPumpThatCantTakeADoseRefuses() {
        for model in [PumpModel.mobi, .unknown] {
            var pump = F.pump()
            pump.model = model
            var access = F.openAccess
            access.capabilities = model.capabilities
            #expect(
                compose(F.remote(.units(1)), context: F.context(pump: pump, access: access)).refusal
                    == .unavailable(.accessDenied(.capabilityUnavailable)))
            // The pump's own model governs even when the access context says otherwise.
            #expect(
                compose(F.remote(.units(1)), context: F.context(pump: pump)).refusal
                    == .unavailable(.accessDenied(.capabilityUnavailable)))
            #expect(
                DoseComposer.composePhone(F.phone(.units(1)), context: F.context(pump: pump)).refusal
                    == .unavailable(.accessDenied(.capabilityUnavailable)))
        }
    }

    // MARK: - Freshness

    @Test func requestWithoutASendTimeIsRefused() {
        #expect(compose(F.remote(.units(1), sentAt: nil)).refusal == .requestTooOld)
    }

    @Test func requestOlderThanTwoMinutesIsRefused() {
        #expect(compose(F.remote(.units(1), sentAt: F.now.addingTimeInterval(-121))).refusal == .requestTooOld)
        #expect(compose(F.remote(.units(1), sentAt: F.now.addingTimeInterval(-119))).dose != nil)
    }

    @Test func requestDatedInTheFutureIsRefused() {
        #expect(compose(F.remote(.units(1), sentAt: F.now.addingTimeInterval(31))).refusal == .requestTooOld)
        #expect(compose(F.remote(.units(1), sentAt: F.now.addingTimeInterval(29))).dose != nil)
    }

    /// A request composed before the last bolus was sent was built on the state before it.
    @Test func requestComposedBeforeTheLastDeliveryIsRefused() {
        let sentAt = F.now.addingTimeInterval(-10)
        #expect(
            compose(
                F.remote(.units(1), sentAt: sentAt), context: F.context(lastDeliveryAt: sentAt.addingTimeInterval(1))
            )
            .refusal == .supersededByDelivery)
        #expect(
            compose(
                F.remote(.units(1), sentAt: sentAt), context: F.context(lastDeliveryAt: sentAt.addingTimeInterval(-1))
            )
            .dose != nil)
    }

    /// A delivery at the very moment the request was sent doesn't supersede it; one a moment later does.
    @Test func supersessionIsStrictlyLater() {
        let sentAt = F.now.addingTimeInterval(-10)
        #expect(
            compose(F.remote(.units(1), sentAt: sentAt), context: F.context(lastDeliveryAt: sentAt)).dose != nil)
    }

    // MARK: - The pump and the ledger

    /// The pump notices ride on a remote dose too, without changing it.
    @Test func remoteDoseCarriesPumpNotices() throws {
        var pump = F.pump()
        pump.reservoirUnits = F.observed(10, age: 1)
        let dose = try #require(compose(F.remote(.units(25)), context: F.context(pump: pump)).dose)
        #expect(dose.units == 25)
        #expect(dose.notices.contains { if case .atPumpMax = $0 { true } else { false } })
        #expect(dose.notices.contains { if case .moreThanReservoir = $0 { true } else { false } })
    }

    /// A CGM LOW or HIGH gives no calculated dose, as on the pump: refused, never carbs only. A units
    /// request isn't calculated, so it goes ahead.
    @Test func outOfRangeReadingRefusesACalculatedDose() {
        for mgdl in [39, 401] {
            let context = F.context(pump: F.pump(glucose: mgdl))
            #expect(
                compose(F.remote(F.carbs(60, estimate: 6), glucose: mgdl), context: context).refusal
                    == .implausibleGlucose(mgdl: mgdl))
            #expect(compose(F.remote(.units(2)), context: context).dose?.units == 2)
        }
    }

    /// A remote size limit that is set but isn't a usable number refuses rather than switching off.
    @Test func unusableRemoteLimitRefuses() {
        for limit in [0, -1, Double.nan] {
            #expect(compose(F.remote(.units(1)), context: F.context(remoteSizeLimitUnits: limit)).refusal != nil)
        }
    }

    @Test func pumpNotConnectedRefuses() {
        var pump = F.pump()
        pump.link = .authenticating
        #expect(compose(F.remote(.units(1)), context: F.context(pump: pump)).refusal == .unavailable(.pumpNotLinked))
    }

    @Test func cartridgeLoadingRefuses() {
        var pump = F.pump()
        pump.cartridge = F.observed(CartridgeLoadState(rawValue: 1), age: 2)
        #expect(compose(F.remote(.units(1)), context: F.context(pump: pump)).refusal == .unavailable(.noCartridge))
    }

    /// An unread cartridge state allows the bolus, with a notice; the pump refuses without a cartridge.
    @Test func cartridgeUnknownDeliversWithANotice() throws {
        var pump = F.pump()
        pump.cartridge = nil
        let dose = try #require(compose(F.remote(.units(1)), context: F.context(pump: pump)).dose)
        #expect(dose.notices.contains(.cartridgeStateUnknown))
        #expect(compose(F.remote(.units(1))).dose?.notices.contains(.cartridgeStateUnknown) == false)
    }

    @Test func ledgerBlockRefuses() {
        let since = F.now.addingTimeInterval(-600)
        #expect(
            compose(F.remote(.units(1)), context: F.context(bolusBlock: .unknownOutcome(since: since))).refusal
                == .blocked(.unknownOutcome(since: since)))
        #expect(
            compose(F.remote(.units(1)), context: F.context(bolusBlock: .bolusInProgress)).refusal
                == .unavailable(.bolusInFlight))
    }

    /// A resent request is answered from the ledger before any check, so the remote gets the first
    /// request's outcome back even when the resend would now fail a check: here it is late, remotes are
    /// read-only, and the delivered bolus has raised IOB enough to change the recompute.
    @Test func resentRequestGetsItsRecordedOutcome() throws {
        let request = F.remote(F.carbs(60, estimate: 7.25))
        let ledger = delivered(try #require(compose(request).dose))

        var pump = F.pump()
        pump.insulinOnBoard = F.observed(7.75, age: 1)
        var access = F.openAccess
        access.remotesReadOnly = true
        let later = F.context(pump: pump, access: access, now: F.now.addingTimeInterval(300))
        #expect(
            compose(request, ledger: ledger, context: later)
                == .alreadyRecorded(.delivered(units: 7.25)))
    }

    /// The same request ID for a different dose is refused, never replayed or delivered.
    @Test func requestIdReusedForADifferentDoseIsRefused() throws {
        let first = try #require(compose(F.remote(.units(1))).dose)
        var ledger = RemoteBolusLedger()
        _ = ledger.begin(first.request, now: F.now)
        #expect(compose(F.remote(.units(2)), ledger: ledger).refusal == .requestIdReused)
        #expect(compose(F.remote(F.carbs(60, estimate: 7.25)), ledger: ledger).refusal == .requestIdReused)
        #expect(compose(F.remote(.units(1)), ledger: ledger) == .alreadyRecorded(.requested))
    }

    /// The remote missed the outcome and the user sent the same dose again under a new request ID: refused
    /// while the delivery is recent, so it isn't given twice.
    @Test func sameDoseJustDeliveredUnderANewIdIsRefused() throws {
        let ledger = delivered(try #require(compose(F.remote(.units(2))).dose))
        let resend = F.remote(.units(2), id: "watch-2")
        #expect(compose(resend, ledger: ledger).refusal == .recentlyDelivered)
        // A different dose, or the same one once the window has passed, goes ahead.
        #expect(compose(F.remote(.units(2.5), id: "watch-2"), ledger: ledger).dose != nil)
        let later = F.now.addingTimeInterval(RemoteBolusLedger.recentDuplicateWindowSec + 1)
        #expect(
            compose(
                F.remote(.units(2), sentAt: later.addingTimeInterval(-3), id: "watch-2"), ledger: ledger,
                context: F.context(now: later)
            ).dose != nil)
    }

    /// After a carb bolus the IOB rises and the recompute for the same carbs drops. A resend under a new ID
    /// is still the same request, recognized by what the remote sent, and refused.
    @Test func sameCarbDoseResentAfterItRaisedIOBIsRefused() throws {
        let ledger = delivered(try #require(compose(F.remote(F.carbs(60, estimate: 7.25))).dose))
        var pump = F.pump()
        pump.insulinOnBoard = F.observed(7.75, age: 1)
        pump.bolusCalculator = F.observed(F.settings(reportedIOB: 7.75), age: 1)
        // 60 g at 180 with 7.75 U on board: the correction is gone, 6.00 U.
        let resend = F.remote(F.carbs(60, estimate: 6), id: "watch-2")
        #expect(compose(resend, ledger: ledger, context: F.context(pump: pump)).refusal == .recentlyDelivered)
        #expect(compose(resend, context: F.context(pump: pump)).dose?.units == 6)
    }

    /// A remote request can't claim the phone's surface or peer.
    @Test func requestNamingThePhoneIsRefused() {
        var request = F.remote(.units(1))
        request.surface = .phoneUI
        #expect(compose(request).refusal == .notARemote)
        request = F.remote(.units(1))
        request.peerId = DoseRequest.Origin.phonePeerId
        #expect(compose(request).refusal == .notARemote)
    }

    // MARK: - Calculator requests

    @Test func carbRequestWithoutAnEstimateIsRefused() {
        #expect(compose(F.remote(F.carbs(60, estimate: nil))).refusal == .missingEstimate)
        #expect(compose(F.remote(F.carbs(60, estimate: .nan))).refusal == .missingEstimate)
    }

    @Test func estimateMoreThanATenthOffIsRefused() {
        #expect(
            compose(F.remote(F.carbs(60, estimate: 7.36))).refusal == .doseChanged(estimateUnits: 7.36, doseUnits: 7.25)
        )
        #expect(
            compose(F.remote(F.carbs(60, estimate: 7.14))).refusal == .doseChanged(estimateUnits: 7.14, doseUnits: 7.25)
        )
        // Exactly 0.10 U apart is within the limit, either way.
        #expect(compose(F.remote(F.carbs(60, estimate: 7.35))).dose?.units == 7.25)
        #expect(compose(F.remote(F.carbs(60, estimate: 7.15))).dose?.units == 7.25)
    }

    /// The calculator inputs have to be read for this attempt: a reading from before the attempt
    /// started is refused even inside its window.
    @Test func inputsReadBeforeTheAttemptAreRefused() {
        for reading in [PumpState.Reading.insulinOnBoard, .bolusCalculator] {
            var pump = F.pump()
            let before = F.requestedAt.addingTimeInterval(-1)
            if reading == .insulinOnBoard {
                pump.insulinOnBoard = Observed(0.5, measuredAt: before, receivedAt: before)
            } else {
                pump.bolusCalculator = Observed(F.settings, measuredAt: before, receivedAt: before)
            }
            #expect(
                compose(F.remote(F.carbs(60, estimate: 7.25)), context: F.context(pump: pump)).refusal
                    == .pumpSettingsNotVerified)
        }
    }

    /// Received for this attempt but measured outside its window is refused too.
    @Test func inputsOutsideTheirWindowAreRefused() {
        var pump = F.pump()
        pump.insulinOnBoard = Observed(
            0.5, measuredAt: F.now.addingTimeInterval(-3600), receivedAt: F.now)
        #expect(
            compose(F.remote(F.carbs(60, estimate: 7.25)), context: F.context(pump: pump)).refusal
                == .pumpSettingsNotVerified)
    }

    /// Without the calculator reply's own IOB the cross-check can't run, so IOB isn't verified.
    @Test func iobWithoutTheCrossCheckIsRefused() {
        var pump = F.pump()
        pump.bolusCalculator = F.observed(F.settings(reportedIOB: nil), age: 2)
        #expect(
            compose(F.remote(F.carbs(60, estimate: 7.25)), context: F.context(pump: pump)).refusal
                == .pumpSettingsNotVerified)
    }

    @Test func settingsNeverReadAreRefused() {
        var pump = F.pump()
        pump.bolusCalculator = nil
        #expect(
            compose(F.remote(F.carbs(60, estimate: 7.25)), context: F.context(pump: pump)).refusal
                == .pumpSettingsNotVerified)
        pump = F.pump()
        pump.insulinOnBoard = nil
        #expect(
            compose(F.remote(F.carbs(60, estimate: 7.25)), context: F.context(pump: pump)).refusal
                == .pumpSettingsNotVerified)
    }

    /// The pump's calculator rejects a target outside 40–400 when correcting; the phone refuses rather
    /// than send its zero.
    @Test func settingsTheCalculatorRejectsAreRefused() {
        var pump = F.pump()
        pump.bolusCalculator = F.observed(
            F.settings(target: 30), age: 2)
        #expect(
            compose(F.remote(F.carbs(60, estimate: 0)), context: F.context(pump: pump)).refusal
                == .pumpSettingsUnusable)
    }

    // MARK: - Stale glucose

    private func staleGlucose(age: TimeInterval = 10 * 60) -> DoseContext {
        F.context(pump: F.pump(glucose: 180, glucoseAge: age))
    }

    private func carbsOnly() -> DoseContext { F.context(pump: F.pump(glucose: nil)) }

    /// Without the user asking to include it, a stale reading drops out: the dose is carbs only.
    @Test func staleGlucoseIsLeftOutUnlessIncluded() throws {
        let dose = try #require(compose(F.remote(F.carbs(60, estimate: 6)), context: staleGlucose()).dose)
        #expect(dose.units == 6)
        #expect(dose.correctionGlucoseMgdl == nil)
        #expect(compose(F.remote(F.carbs(60, estimate: 7.25)), context: staleGlucose()).refusal != nil)
    }

    @Test func includedStaleGlucoseIsUsedWhenItMatches() throws {
        let dose = try #require(
            compose(F.remote(F.carbs(60, estimate: 7.25), includeStale: true), context: staleGlucose()).dose)
        #expect(dose.units == 7.25)
        #expect(dose.correctionGlucoseMgdl == 180)
        #expect(dose.usedIncludedStaleGlucose)
    }

    /// The stale reading must be the one the remote estimated from.
    @Test func includedStaleGlucoseThatDoesntMatchIsLeftOut() throws {
        let dose = try #require(
            compose(F.remote(F.carbs(60, estimate: 6), glucose: 170, includeStale: true), context: staleGlucose()).dose)
        #expect(dose.correctionGlucoseMgdl == nil)
        #expect(!dose.usedIncludedStaleGlucose)
    }

    /// A reading older than 15 minutes is never included.
    @Test func includedStaleGlucoseOlderThanTheLimitIsLeftOut() throws {
        let context = staleGlucose(age: 30 * 60)
        let dose = try #require(compose(F.remote(F.carbs(60, estimate: 6), includeStale: true), context: context).dose)
        #expect(dose.correctionGlucoseMgdl == nil)
    }

    /// A fresh reading always wins, whatever the remote estimated from or asked to include.
    @Test func freshGlucoseIsUsedOverTheRemotesValue() throws {
        let dose = try #require(
            compose(F.remote(F.carbs(60, estimate: 7.25), glucose: 170, includeStale: true)).dose)
        #expect(dose.correctionGlucoseMgdl == 180)
        #expect(!dose.usedIncludedStaleGlucose)
    }

    // MARK: - Limits

    @Test func belowThePumpsMinimumIsRefused() {
        #expect(compose(F.remote(.units(0.04))).refusal == .unavailable(.belowMinimum(0.05)))
        #expect(compose(F.remote(.units(0.05))).dose != nil)
        #expect(compose(F.remote(.units(0))).refusal == .nothingToDeliver)
    }

    @Test func aboveThePumpsKnownMaxIsRefused() {
        #expect(compose(F.remote(.units(25.05))).refusal == .unavailable(.aboveMax(25)))
        #expect(compose(F.remote(.units(25))).dose != nil)
    }

    /// With the max unread, the app adds no limit of its own and the request goes to the pump.
    @Test func maxUnknownGoesToThePump() throws {
        var pump = F.pump()
        pump.bolusCalculator = nil
        let dose = try #require(compose(F.remote(.units(40)), context: F.context(pump: pump)).dose)
        #expect(dose.units == 40)
    }

    @Test func aboveTheRemoteSizeLimitIsRefused() {
        let context = F.context(remoteSizeLimitUnits: 5)
        #expect(compose(F.remote(.units(5.05)), context: context).refusal == .aboveRemoteLimit(5))
        #expect(compose(F.remote(.units(5)), context: context).dose != nil)
        #expect(compose(F.remote(F.carbs(60, estimate: 7.25)), context: context).refusal == .aboveRemoteLimit(5))
    }

    // MARK: - Malformed requests

    @Test func requestWithNoAmountIsRefused() {
        #expect(compose(F.remote(nil)).refusal == .noDoseSpecified)
    }

    @Test func amountsThatArentNumbersAreRefused() {
        for bad in [Double.nan, .infinity, -1] {
            #expect(compose(F.remote(.units(bad))).refusal == .invalidAmount)
            #expect(compose(F.remote(F.carbs(bad, estimate: 1))).refusal == .invalidAmount)
        }
    }

    // MARK: - v1 messages

    @Test func v1BolusRequestMapsToARemoteRequest() throws {
        var command = RemoteCommand(
            kind: .bolusRequest, requestId: "r1", sentAt: 1_800_000_000, carbsGrams: 0, bgMgdl: 179.6)
        command.remoteEstimateUnits = 1.2
        command.includeStaleBG = true
        let request = try #require(RemoteDoseRequest(v1: command, peerId: "garmin", surface: .garmin))
        #expect(request.id == "r1")
        #expect(request.amount == .calculator(carbsGrams: 0, estimateUnits: 1.2))
        #expect(request.glucoseMgdl == 180)
        #expect(request.includeStaleGlucose)
        #expect(request.sentAt == Date(timeIntervalSince1970: 1_800_000_000))

        let units = try #require(
            RemoteDoseRequest(v1: RemoteCommand(kind: .bolusRequest, units: 2), peerId: "garmin", surface: .garmin))
        #expect(units.amount == .units(2))
        let empty = try #require(
            RemoteDoseRequest(v1: RemoteCommand(kind: .bolusRequest, bgMgdl: .nan), peerId: "garmin", surface: .garmin))
        #expect(empty.amount == nil)
        #expect(empty.glucoseMgdl == nil)
        #expect(RemoteDoseRequest(v1: RemoteCommand(kind: .cancelBolus), peerId: "garmin", surface: .garmin) == nil)
    }

    /// An extended bolus isn't offered, so its request has no amount and is refused rather than delivered
    /// all at once.
    @Test func v1ExtendedRequestIsRefused() throws {
        var command = RemoteCommand(kind: .bolusRequest, sentAt: Int(F.now.timeIntervalSince1970), units: 6)
        command.extendedNowUnits = 2
        command.extendedMinutes = 120
        let request = try #require(RemoteDoseRequest(v1: command, peerId: "garmin", surface: .garmin))
        #expect(request.amount == nil)
        #expect(compose(request).refusal == .noDoseSpecified)
    }

    // MARK: - The two IOB readings

    /// Right after a bolus the IOB reading can lag the calculator reply's own IOB. When they disagree by
    /// more than a step, IOB isn't verified and a remote carb request is refused.
    @Test func disagreeingIOBReadingsAreRefused() {
        var pump = F.pump()
        pump.bolusCalculator = F.observed(
            F.settings(target: 110, reportedIOB: 1.5),
            age: 2)
        #expect(
            compose(F.remote(F.carbs(60, estimate: 7.25)), context: F.context(pump: pump)).refusal
                == .pumpSettingsNotVerified)
        // Within a step they agree.
        pump.bolusCalculator = F.observed(
            F.settings(target: 110, reportedIOB: 0.55),
            age: 2)
        #expect(compose(F.remote(F.carbs(60, estimate: 7.25)), context: F.context(pump: pump)).dose?.units == 7.25)
    }
}
