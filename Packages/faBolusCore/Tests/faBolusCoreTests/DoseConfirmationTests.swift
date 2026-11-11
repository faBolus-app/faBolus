import Foundation
import Testing

@testable import faBolusCore

/// The pump's state the user confirms before a dose, as Tandem's apps ask it: too many boluses, the max
/// hourly bolus, and low insulin. Asked on the phone and on a remote; none changes the dose.
@Suite struct DoseConfirmationTests {
    typealias F = DoseFixtures

    /// The fixture pump (max 25 U, 150 U left) with its calculator reply changed.
    private static func pump(_ change: (inout BolusCalculatorSettings) -> Void) -> PumpState {
        var pump = F.pump()
        var settings = F.settings
        change(&settings)
        pump.bolusCalculator = F.observed(settings, age: 2)
        return pump
    }

    private static func needed(_ units: Double, _ pump: PumpState) -> [DoseConfirmation] {
        DoseComposer.confirmations(units: units, context: F.context(pump: pump))
    }

    // MARK: Too many boluses

    @Test(arguments: [(true, false), (false, true), (true, true)])
    func tooManyBolusesIsAskedForEitherFlag(hourly: Bool, iob: Bool) throws {
        let flags = BolusCalculatorSettings.TooManyBoluses(hourlyLimit: hourly, insulinOnBoard: iob)
        let context = F.context(pump: Self.pump { $0.tooManyBoluses = flags })
        #expect(
            DoseComposer.composePhoneCorrecting(F.phone(.units(2)), context: context).prompt
                == .confirmation(.tooManyBoluses(flags), units: 2))
        // Going on delivers the dose as it was.
        let answers = PhoneDoseAnswers(confirmed: [.tooManyBoluses: .init(.tooManyBoluses(flags), units: 2)])
        let dose = try #require(
            DoseComposer.composePhoneCorrecting(F.phone(.units(2), answers: answers), context: context).dose)
        #expect(dose.units == 2)
    }

    @Test func tooManyBolusesNamesWhatThePumpMayNotTrack() {
        func message(_ hourly: Bool, _ iob: Bool) -> String {
            DoseConfirmation.tooManyBoluses(.init(hourlyLimit: hourly, insulinOnBoard: iob)).message
        }
        #expect(message(true, false).contains("may not track the max hourly bolus"))
        #expect(message(false, true).contains("may not track IOB if"))
        #expect(message(true, true).contains("may not track IOB or the max hourly bolus"))
    }

    @Test func neitherFlagOrNoneReportedAsksNothing() {
        #expect(
            Self.needed(2, Self.pump { $0.tooManyBoluses = .init(hourlyLimit: false, insulinOnBoard: false) }).isEmpty)
        #expect(Self.needed(2, Self.pump { $0.tooManyBoluses = nil }).isEmpty)
    }

    // MARK: Max hourly bolus

    /// Over 1.5 × the max bolus, this dose and the last hour's together; at it, nothing is asked.
    @Test func maxHourlyBolusIsAskedOverOneAndAHalfTimesTheMax() {
        #expect(Self.needed(7.25, Self.pump { $0.bolusedLastHourUnits = 30.25 }).isEmpty)
        #expect(
            Self.needed(7.25, Self.pump { $0.bolusedLastHourUnits = 30.3 })
                == [.maxHourlyBolus(doseUnits: 7.25, lastHourUnits: 30.3, limitUnits: 37.5)])
        #expect(Self.needed(7.25, Self.pump { $0.bolusedLastHourUnits = nil }).isEmpty)
    }

    /// Tandem's app takes the max bolus in whole units here: a 12.5 U max gives an 18 U hourly limit.
    @Test func theMaxBolusIsTakenInWholeUnits() {
        let pump = Self.pump {
            $0.maxBolusUnits = 12.5
            $0.bolusedLastHourUnits = 10
        }
        #expect(Self.needed(8, pump).isEmpty)
        #expect(Self.needed(8.05, pump) == [.maxHourlyBolus(doseUnits: 8.05, lastHourUnits: 10, limitUnits: 18)])
    }

    /// With no max bolus read, the pump's own check is the only one.
    @Test func noMaxBolusAsksNothing() {
        #expect(
            Self.needed(
                20,
                Self.pump {
                    $0.maxBolusUnits = 0
                    $0.bolusedLastHourUnits = 30
                }
            ).isEmpty)
    }

    // MARK: Low insulin

    @Test func lowInsulinIsAskedAboveWhatIsLeftOrUnderTwoUnits() {
        func pump(left: Double) -> PumpState {
            var pump = F.pump()
            pump.reservoirUnits = F.observed(left, age: 2)
            return pump
        }
        #expect(Self.needed(5, pump(left: 4)) == [.lowInsulin(doseUnits: 5, remainingUnits: 4)])
        #expect(Self.needed(4, pump(left: 4)).isEmpty)
        #expect(Self.needed(1, pump(left: 1.5)) == [.lowInsulin(doseUnits: 1, remainingUnits: 1.5)])
        #expect(Self.needed(1, pump(left: 2)).isEmpty)
    }

    /// The lower of the calculator reply's and the insulin reading's, each while current.
    @Test func theLowerCurrentReadingOfWhatIsLeftCounts() {
        var pump = Self.pump { $0.insulinRemainingUnits = 3 }
        #expect(Self.needed(5, pump) == [.lowInsulin(doseUnits: 5, remainingUnits: 3)])
        // The insulin reading is lower.
        pump.reservoirUnits = F.observed(1, age: 2)
        #expect(Self.needed(5, pump) == [.lowInsulin(doseUnits: 5, remainingUnits: 1)])
        // Neither is current: the pump's own check is the only one.
        pump.reservoirUnits = F.observed(1, age: 10 * 60)
        pump.bolusCalculator = F.observed(pump.bolusCalculator!.value, age: 10 * 60)
        #expect(Self.needed(5, pump).isEmpty)
    }

    // MARK: On the phone

    /// Each is asked in turn, and an answer counts only for the dose it showed.
    @Test func eachIsAskedInTurnForTheDoseItShowed() throws {
        var pump = Self.pump {
            $0.tooManyBoluses = .init(hourlyLimit: true, insulinOnBoard: false)
            $0.bolusedLastHourUnits = 35
        }
        pump.reservoirUnits = F.observed(1, age: 2)
        let context = F.context(pump: pump)
        var answers = PhoneDoseAnswers()
        func compose() -> PhoneDoseDecision {
            DoseComposer.composePhoneCorrecting(F.phone(.units(3), answers: answers), context: context)
        }
        func goOn() {
            guard case .confirmation(let c, let units) = compose().prompt else { return }
            answers.confirmed[c.kind] = .init(c, units: units)
        }
        #expect(compose().prompt?.confirmationKind == .tooManyBoluses)
        goOn()
        #expect(compose().prompt?.confirmationKind == .maxHourlyBolus)
        goOn()
        #expect(compose().prompt?.confirmationKind == .lowInsulin)
        // An answer for another dose is asked again.
        answers.confirmed[.lowInsulin] = .init(.lowInsulin(doseUnits: 2.5, remainingUnits: 1), units: 2.5)
        #expect(compose().prompt?.confirmationKind == .lowInsulin)
        goOn()
        #expect(try #require(compose().dose).units == 3)
    }

    /// An answer counts only while what it confirmed still stands: less insulin left asks again.
    @Test func anAnswerWhoseFiguresMovedIsAskedAgain() throws {
        var pump = F.pump()
        pump.reservoirUnits = F.observed(4, age: 2)
        let low = DoseConfirmation.lowInsulin(doseUnits: 5, remainingUnits: 4)
        var answers = PhoneDoseAnswers(confirmed: [.lowInsulin: .init(low, units: 5)])
        #expect(
            DoseComposer.composePhoneCorrecting(F.phone(.units(5), answers: answers), context: F.context(pump: pump))
                .dose != nil)
        pump.reservoirUnits = F.observed(1, age: 2)
        #expect(
            DoseComposer.composePhoneCorrecting(F.phone(.units(5), answers: answers), context: F.context(pump: pump))
                .prompt
                == .confirmation(.lowInsulin(doseUnits: 5, remainingUnits: 1), units: 5))
        answers.confirmed[.lowInsulin] = .init(.lowInsulin(doseUnits: 5, remainingUnits: 1), units: 5)
        #expect(
            DoseComposer.composePhoneCorrecting(F.phone(.units(5), answers: answers), context: F.context(pump: pump))
                .dose != nil)
    }

    /// A resend of a dose just delivered is refused as one, not offered to go on again.
    @Test func aRecentlyDeliveredResendIsntAskedToConfirm() throws {
        var pump = F.pump()
        pump.reservoirUnits = F.observed(1, age: 2)
        let context = F.context(pump: pump)
        var ledger = RemoteBolusLedger()
        var first = F.remote(.units(1), id: "watch-1")
        first.confirmed = [.lowInsulin]
        let dose = try #require(DoseComposer.composeRemote(first, ledger: ledger, context: context).dose)
        _ = ledger.begin(dose.request, now: F.now)
        ledger.markAccepted(dose.request.ledgerKey, bolusId: 7, now: F.now)
        ledger.markDelivering(dose.request.ledgerKey, now: F.now)
        ledger.markDelivered(dose.request.ledgerKey, units: 1, now: F.now)
        let resend = F.remote(.units(1), id: "watch-2")
        #expect(DoseComposer.composeRemote(resend, ledger: ledger, context: context).refusal == .recentlyDelivered)
    }

    /// A calculator dose is asked about at the dose it comes to.
    @Test func aCalculatorDoseIsAskedAtItsUnits() {
        var pump = F.pump()
        pump.reservoirUnits = F.observed(5, age: 2)
        #expect(
            DoseComposer.composePhoneCorrecting(F.phone(F.cgmDose()), context: F.context(pump: pump)).prompt
                == .confirmation(.lowInsulin(doseUnits: 7.25, remainingUnits: 5), units: 7.25))
    }

    // MARK: On a remote

    @Test func aRemoteDoseWithoutTheConfirmationsIsRefusedWithThem() throws {
        var pump = Self.pump { $0.tooManyBoluses = .init(hourlyLimit: false, insulinOnBoard: true) }
        pump.reservoirUnits = F.observed(4, age: 2)
        let context = F.context(pump: pump)
        let needed: [DoseConfirmation] = [
            .tooManyBoluses(.init(hourlyLimit: false, insulinOnBoard: true)),
            .lowInsulin(doseUnits: 7.25, remainingUnits: 4)
        ]
        var request = F.remote(F.carbs(60, estimate: 7.25))
        #expect(
            DoseComposer.composeRemote(request, ledger: .init(), context: context).refusal
                == .needsConfirmation(needed, units: 7.25))
        // One confirmed is not enough: both are named again.
        request.confirmed = [.lowInsulin]
        #expect(
            DoseComposer.composeRemote(request, ledger: .init(), context: context).refusal
                == .needsConfirmation(needed, units: 7.25))
        request.confirmed = [.lowInsulin, .tooManyBoluses]
        let dose = try #require(DoseComposer.composeRemote(request, ledger: .init(), context: context).dose)
        #expect(dose.units == 7.25)
    }

    /// A remote is told each in a few words; its own button names the dose.
    @Test func theRemoteIsToldWhatToConfirm() {
        let low = DoseConfirmation.lowInsulin(doseUnits: 3, remainingUnits: 1.5)
        #expect(
            DoseRefusal.needsConfirmation([low], units: 3).userMessage
                == "Low insulin: 1.50 U left.")
        let all = DoseRefusal.needsConfirmation(
            [
                .tooManyBoluses(.init(hourlyLimit: true, insulinOnBoard: true)),
                .maxHourlyBolus(doseUnits: 3, lastHourUnits: 36, limitUnits: 37.5), low
            ], units: 3)
        #expect(
            all.userMessage
                == "Too many boluses: the pump may not track IOB or the hourly limit. Over the max hourly bolus "
                + "(39.00 of 37.50 U). Low insulin: 1.50 U left.")
        #expect(all.confirmationKinds == [.tooManyBoluses, .maxHourlyBolus, .lowInsulin])
    }
}

extension PhoneDosePrompt {
    fileprivate var confirmationKind: DoseConfirmation.Kind? {
        if case .confirmation(let confirmation, _) = self { return confirmation.kind }
        return nil
    }
}
