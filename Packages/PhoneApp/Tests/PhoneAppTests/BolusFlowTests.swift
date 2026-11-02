import Foundation
import PumpScript
import PumpSession
import Testing
@testable import faBolusCore

@testable import PhoneApp

@MainActor
@Suite struct BolusFlowTests {
    func connected() async -> (Phone, AppModel) {
        let phone = Phone()
        let model = await phone.launch()
        _ = await phone.until(model) { model.pump.link == .connected }
        // The link has held, so the delivery's untested commands may go out.
        await phone.run(model, for: 12)
        return (phone, model)
    }

    /// A review left open while the pump's readings move on isn't sent as it was: Deliver reads the pump
    /// again and shows the new dose, and nothing reaches the pump until that one is confirmed.
    @Test func aReviewLeftOpenIsReadAgainBeforeItIsSent() async {
        let (phone, model) = await connected()
        let flow = BolusFlow(model: model)
        flow.mode = .carbs
        flow.carbsText = "30"
        flow.entryChanged()
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let reviewed) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        phone.mock.pump.glucose = (260, 30)
        await phone.run(model, for: 30)
        await phone.driving(model) { await flow.deliver() }
        switch flow.phase {
        case .review(let fresh): #expect(fresh.units != reviewed.units)
        case .prompt: break
        default: Issue.record("expected the dose reviewed again, got \(flow.phase)")
        }
        #expect(model.latestOutcome == nil, "nothing was sent")
        await model.shutdown()
    }

    /// A typed glucose that isn't a number holds the dose: it isn't quietly replaced by the CGM reading.
    @Test func aGlucoseThatIsntANumberHoldsTheDose() async {
        let (phone, model) = await connected()
        let flow = BolusFlow(model: model)
        flow.mode = .carbs
        flow.carbsText = "30"
        flow.glucoseText = "212.0"
        flow.unitsTyped("2")
        #expect(flow.unavailableReason == BolusFlow.invalidGlucoseText)
        await phone.driving(model) { await flow.confirm() }
        #expect(flow.phase == .refused(BolusFlow.invalidGlucoseText))
        flow.glucoseText = ""
        #expect(flow.unavailableReason == nil)
        await model.shutdown()
    }

    /// Units typed, confirmed, reviewed and sent: the pump delivers exactly that dose and the banner says so.
    @Test func aUnitsBolusIsReviewedThenDelivered() async {
        let (phone, model) = await connected()
        let flow = BolusFlow(model: model)
        flow.mode = .units
        flow.unitsTyped("1.5")
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.units == 1.5)
        await phone.driving(model) { await flow.deliver() }
        guard case .done(.started) = flow.phase else {
            Issue.record("expected a started delivery, got \(flow.phase)")
            return
        }
        #expect(
            await phone.until(model) {
                if case .delivered(let u) = model.latestOutcome?.outcome { return u == 1.5 }
                return false
            })
        #expect(flow.unitsText.isEmpty, "the screen is cleared for the next dose")
        await model.shutdown()
    }

    /// No current CGM reading on a carb dose: the composer asks, and "carbs only" sends the carbs-only dose
    /// it offered.
    @Test func aStaleReadingAsksAndCarbsOnlySendsWhatItOffered() async {
        let phone = Phone()
        phone.mock.pump.glucose = (180, 30 * 60)
        let model = await phone.launch()
        _ = await phone.until(model) { model.pump.link == .connected }
        await phone.run(model, for: 12)
        let flow = BolusFlow(model: model)
        flow.mode = .carbs
        flow.carbsText = "30"
        flow.entryChanged()
        #expect(flow.units != nil)
        await phone.driving(model) { await flow.confirm() }
        guard case .prompt(.staleGlucose(_, _, let carbsOnly)) = flow.phase else {
            Issue.record("expected the stale-glucose prompt, got \(flow.phase)")
            return
        }
        // As the dialog does it: the choice, then the dialog closes, which cancels a prompt still showing.
        flow.choose(.carbsOnly)
        if case .prompt = flow.phase { flow.cancel() }
        await phone.driving(model) {
            while flow.phase == .composing { await Task.yield() }
        }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.units == carbsOnly)
        #expect(dose.correctionGlucoseMgdl == nil)
        flow.cancel()
        #expect(flow.phase == .editing)
        await model.shutdown()
    }

    /// Read-only: the screen says why and the composer refuses; nothing reaches the pump.
    @Test func readOnlyRefusesBeforeAnythingIsSent() async {
        let (phone, model) = await connected()
        model.settings.phoneReadOnly = true
        let flow = BolusFlow(model: model)
        flow.mode = .units
        flow.unitsTyped("1")
        #expect(flow.unavailableReason != nil)
        await phone.driving(model) { await flow.confirm() }
        guard case .refused = flow.phase else {
            Issue.record("expected a refusal, got \(flow.phase)")
            return
        }
        #expect(phone.mock.pump.completed.isEmpty)
        await model.shutdown()
    }

    @Test func entryParsingNeverTurnsNothingIntoZero() {
        #expect(BolusFlow.parseNumber("1,25") == 1.25)
        #expect(BolusFlow.parseNumber("2") == 2)
        for junk in ["", " ", "abc", "-1", "nan"] { #expect(BolusFlow.parseNumber(junk) == nil) }
    }

    /// Notices are text above the confirm, most important first.
    @Test func noticesAreRankedMostImportantFirst() {
        let d = StackingGuard.Disclosure(friction: .disclose, message: "More than the reservoir holds.")
        let s = StackingGuard.Disclosure(friction: .disclose, message: "A bolus was given 10 minutes ago.")
        let dose = ComposedDose(
            request: DoseRequest(id: "x", origin: .phone, shape: .now(units: 1), carbsGrams: nil, bgMgdl: nil),
            calculatorIOBUnits: nil, correctionGlucoseMgdl: nil, calculatorCarbUnits: nil,
            usedIncludedStaleGlucose: false,
            notices: [.cartridgeStateUnknown, .stacking(s), .moreThanReservoir(d)])
        let notices = BolusFlow.notices(dose)
        #expect(notices.count == 3)
        #expect(notices[0] == "More than the reservoir holds.")
        #expect(notices[1] == "A bolus was given 10 minutes ago.")
        #expect(notices[2].contains("cartridge"))
    }
}
