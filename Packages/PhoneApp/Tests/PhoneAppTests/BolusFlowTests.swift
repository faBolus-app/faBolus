import Foundation
import PumpScript
import PumpSession
import Testing
@testable import faBolusCore

@testable import PhoneApp

@MainActor
@Suite struct BolusFlowTests {
    /// Text as read: the unit is kept whole, and on the number's line, by invisible joiners.
    static func shown(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

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
        // The new reading asks whether to correct: on the screen, with its doses.
        case .editing: #expect(flow.correctionQuestion?.mgdl == 260)
        default: Issue.record("expected the dose reviewed again, got \(flow.phase)")
        }
        #expect(model.latestOutcome == nil, "nothing was sent")
        await model.shutdown()
    }

    /// Above target the screen asks whether to correct before Confirm: no dose until a card is chosen, and
    /// the card's dose is the one reviewed. Carbs only sends no correction.
    @Test func theCorrectionIsChosenOnTheScreen() async {
        let (phone, model) = await connected()
        let flow = BolusFlow(model: model)
        flow.mode = .carbs
        flow.carbsText = "30"
        flow.glucoseText = "220"
        flow.entryChanged()
        guard let q = flow.correctionQuestion else {
            Issue.record("expected the question")
            return
        }
        #expect(q.above)
        #expect(q.applyUnits > q.declineUnits)
        #expect(flow.unitsText.isEmpty)
        #expect(flow.unavailableReason == BolusFlow.chooseText)
        await phone.driving(model) { await flow.confirm() }
        #expect(flow.phase == .editing, "nothing is composed before a card is chosen")
        flow.chooseCorrection(apply: false)
        #expect(flow.units == q.declineUnits)
        #expect(flow.unavailableReason == nil)
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.units == q.declineUnits)
        #expect(dose.correctionGlucoseMgdl == nil)
        flow.cancel()
        // Corrected instead: that dose, correcting from the typed glucose.
        flow.chooseCorrection(apply: true)
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let corrected) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(corrected.units == q.applyUnits)
        #expect(corrected.correctionGlucoseMgdl == 220)
        flow.cancel()
        // A glucose the user types themselves clears the choice, with no alert: they made the change.
        flow.glucoseText = "240"
        flow.entryEdited()
        #expect(flow.correction == nil)
        #expect(flow.correctionChange == nil)
        #expect(flow.changeAlert == nil)
        #expect(flow.unitsText.isEmpty)
        // Editing the dose by hand leaves the cards.
        flow.unitsTyped("1")
        #expect(flow.unavailableReason == nil)
        flow.useCalculatorDose()
        #expect(flow.unitsText.isEmpty)
        await model.shutdown()
    }

    /// The CGM moves after a card was chosen: Confirm doesn't send the old dose, the screen asks again with
    /// the new doses and says which way the reading went.
    @Test func aNewReadingAfterChoosingAsksAgain() async {
        let phone = Phone()
        phone.mock.pump.glucose = (220, 30)
        let model = await phone.launch()
        _ = await phone.until(model) { model.pump.link == .connected }
        await phone.run(model, for: 12)
        let flow = BolusFlow(model: model)
        flow.mode = .carbs
        flow.carbsText = "30"
        flow.entryChanged()
        #expect(flow.correctionQuestion?.mgdl == 220)
        flow.chooseCorrection(apply: true)
        let chosen = flow.unitsText
        phone.mock.pump.glucose = (180, 5)
        await phone.run(model, for: 30)
        // No view runs here to clear the units: Confirm still sends nothing from the stale choice.
        #expect(flow.unitsText == chosen)
        await phone.driving(model) { await flow.confirm() }
        #expect(flow.phase == .editing)
        #expect(flow.correctionQuestion?.mgdl == 180)
        #expect(flow.correctionChange == .glucose(fromMgdl: 220, toMgdl: 180))
        // Said in an alert first; once seen, a reminder stays by the cards.
        #expect(flow.changeAlert == .glucose(fromMgdl: 220, toMgdl: 180))
        let change = flow.text(for: .glucose(fromMgdl: 220, toMgdl: 180))
        #expect(Self.shown(change.title) == "BG 220 mg/dL → 180 mg/dL")
        #expect(change.message.isEmpty)
        #expect(change.button == "Choose again")
        flow.acknowledgeChange()
        #expect(flow.changeAlert == nil)
        #expect(flow.correctionChange == .glucose(fromMgdl: 220, toMgdl: 180))
        #expect(flow.unavailableReason == BolusFlow.chooseText)
        #expect(model.latestOutcome == nil, "nothing was sent")
        await model.shutdown()
    }

    /// The reading changes just before Confirm, so only the pump's fresh read at Confirm has it: the screen
    /// asks again with the doses from that read, never sends the chosen one.
    @Test func aReadingOnlyConfirmSawAsksAgain() async {
        let phone = Phone()
        phone.mock.pump.glucose = (220, 30)
        let model = await phone.launch()
        _ = await phone.until(model) { model.pump.link == .connected }
        await phone.run(model, for: 12)
        let flow = BolusFlow(model: model)
        flow.mode = .carbs
        flow.carbsText = "30"
        flow.entryChanged()
        flow.chooseCorrection(apply: true)
        phone.mock.pump.glucose = (250, 1)
        await phone.driving(model) { await flow.confirm() }
        #expect(flow.phase == .editing)
        #expect(flow.correctionQuestion?.mgdl == 250)
        #expect(flow.changeAlert == .glucose(fromMgdl: 220, toMgdl: 250))
        flow.acknowledgeChange()
        #expect(model.latestOutcome == nil, "nothing was sent")
        // Chosen again, the new dose is reviewed.
        let q = flow.correctionQuestion
        flow.chooseCorrection(apply: true)
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.units == q?.applyUnits)
        #expect(dose.correctionGlucoseMgdl == 250)
        await model.shutdown()
    }

    /// The CGM drops under 70 after a card was chosen, and only Confirm's fresh read sees it: there's no
    /// question any more. The card's dose (corrected from the old reading) is never offered to keep; the
    /// screen says the question went, in an alert, and once seen the dose is the calculator's for now.
    @Test func aReadingThatEndsTheQuestionSaysSo() async {
        let phone = Phone()
        phone.mock.pump.glucose = (220, 30)
        let model = await phone.launch()
        _ = await phone.until(model) { model.pump.link == .connected }
        await phone.run(model, for: 12)
        let flow = BolusFlow(model: model)
        flow.mode = .carbs
        flow.carbsText = "30"
        flow.entryChanged()
        flow.chooseCorrection(apply: true)
        phone.mock.pump.glucose = (60, 1)
        await phone.driving(model) { await flow.confirm() }
        #expect(flow.phase == .editing, "no Dose changed prompt offering the old card's dose")
        #expect(flow.correctionQuestion == nil)
        #expect(flow.changeAlert == .noQuestion(fromMgdl: 220, toMgdl: 60))
        // What changed as the title, what it means in a line.
        let low = flow.text(for: .noQuestion(fromMgdl: 220, toMgdl: 60))
        #expect(Self.shown(low.title) == "BG 220 mg/dL → 60 mg/dL")
        #expect(low.message.hasPrefix("Dose reduced to "))
        #expect(low.warning == "Eat carbs.")
        #expect(flow.text(for: .noQuestion(fromMgdl: 220, toMgdl: 120)).message.hasPrefix("No correction needed"))
        #expect(flow.text(for: .noQuestion(fromMgdl: 220, toMgdl: nil)).title == "No current BG")
        // A reading the calculator can't correct from is never "no correction needed".
        #expect(flow.text(for: .noQuestion(fromMgdl: 220, toMgdl: 650)).message == "Too high for a carb dose.")
        let tooLow = flow.text(for: .noQuestion(fromMgdl: 220, toMgdl: 15))
        #expect(tooLow.message == "Too low for a carb dose.")
        #expect(tooLow.warning == "Eat carbs.")
        // Nothing goes before the change is seen.
        await phone.driving(model) { await flow.confirm() }
        #expect(flow.phase == .editing)
        flow.acknowledgeChange()
        #expect(flow.changeAlert == nil)
        #expect(flow.correctionChange == nil)
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.correctionGlucoseMgdl == 60, "the reduction for the low applies")
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
        // A number outside what the calculator takes holds the dose too, rather than going on to a refusal.
        flow.glucoseText = "650"
        #expect(flow.unavailableReason == BolusFlow.outOfRangeText)
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

    /// A CGM reading too old to include on a carb dose: the screen says carbs only, and Confirm goes straight
    /// to the review with that dose, with nothing to ask (as on the watch).
    @Test func aReadingTooOldToIncludeGoesCarbsOnly() async {
        let phone = Phone()
        phone.mock.pump.glucose = (180, 30 * 60)
        let model = await phone.launch()
        _ = await phone.until(model) { model.pump.link == .connected }
        await phone.run(model, for: 12)
        let flow = BolusFlow(model: model)
        flow.mode = .carbs
        flow.carbsText = "30"
        flow.entryChanged()
        #expect(!model.staleReadingIncludable)
        let carbsOnly = flow.units
        #expect(carbsOnly != nil)
        await phone.driving(model) { await flow.confirm() }
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

    /// Carbs off on the pump: the food field takes insulin units, as Tandem's app has it, and the dose goes
    /// with no carbs.
    @Test func withCarbsOffTheFoodIsUnits() async {
        let phone = Phone()
        phone.mock.pump.carbEntryEnabled = false
        phone.mock.pump.glucose = nil
        let model = await phone.launch()
        _ = await phone.until(model) { model.pump.link == .connected }
        await phone.run(model, for: 12)
        let flow = BolusFlow(model: model)
        flow.mode = .carbs
        #expect(flow.carbsOff)
        flow.carbsText = "3"
        flow.carbsEdited()
        #expect(flow.food == .insulin(units: 3))
        #expect(flow.recommendation.units == 3)
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.units == 3)
        #expect(dose.request.carbsGrams == nil)
        #expect(dose.request.foodInsulinUnits == 3)
        flow.cancel()
        await model.shutdown()
    }

    /// With carbs off there are no carbs in the dose, so the dose without the correction is "no correction".
    @Test func withCarbsOffTheDoseWithoutTheCorrectionIsNoCorrection() {
        #expect(BolusFlow.cautionLine(.checkBG) == "CGM says check BG: carbs only")
        #expect(BolusFlow.cautionLine(.checkBG, carbsOff: true) == "CGM says check BG: no correction")
        #expect(BolusFlow.noCorrectionTitle(true) == "No correction")
        #expect(BolusFlow.noCorrectionTitle(false) == "Carbs only")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = StaleBolusPrompt.warningMessage(
            glucoseMgdl: 180, glucoseDate: at.addingTimeInterval(-600), now: at, carbsOff: true)
        #expect(stale.contains("bolus with no correction, or cancel?"))
    }

    /// Carbs turned off on the pump after the carbs were typed: the grams are never taken as units. Confirm
    /// reads the pump and says to enter the dose again.
    @Test func carbsTurnedOffAfterTypingAreEnteredAgain() async {
        let phone = Phone()
        phone.mock.pump.glucose = nil
        let model = await phone.launch()
        _ = await phone.until(model) { model.pump.link == .connected }
        await phone.run(model, for: 12)
        let flow = BolusFlow(model: model)
        flow.mode = .carbs
        flow.carbsText = "30"
        flow.carbsEdited()
        #expect(flow.food == .carbs(grams: 30))
        phone.mock.pump.carbEntryEnabled = false
        await phone.driving(model) { await flow.confirm() }
        #expect(flow.phase == .refused(DoseRefusal.carbEntryChanged(carbsOff: true).userMessage))
        // The screen now has carbs off too: it holds the button until the food is typed again, as units.
        #expect(flow.carbsOff)
        #expect(flow.foodNeedsReentry)
        flow.dismissResult()
        #expect(flow.unavailableReason == DoseRefusal.carbEntryChanged(carbsOff: true).userMessage)
        flow.carbsText = "3"
        flow.carbsEdited()
        #expect(!flow.foodNeedsReentry)
        #expect(flow.food == .insulin(units: 3))
        await model.shutdown()
    }

    /// The pump flags too many boluses: the screen asks, in the pump's words, and Deliver sends the dose
    /// it showed.
    @Test func aConfirmationIsAskedAndGoingOnReviewsTheDose() async {
        let phone = Phone()
        phone.mock.pump.tooManyBolusesIOB = true
        let model = await phone.launch()
        _ = await phone.until(model) { model.pump.link == .connected }
        await phone.run(model, for: 12)
        let flow = BolusFlow(model: model)
        flow.mode = .units
        flow.unitsTyped("1.5")
        await phone.driving(model) { await flow.confirm() }
        guard case .prompt(let prompt) = flow.phase, case .confirmation(.tooManyBoluses, 1.5) = prompt else {
            Issue.record("expected the too-many-boluses question, got \(flow.phase)")
            return
        }
        let text = flow.text(for: prompt)
        #expect(text.title == "Too many boluses")
        #expect(text.message.contains("may not track IOB"))
        #expect(text.choices.map(\.0) == [.goOn])
        flow.choose(.goOn)
        await phone.driving(model) {
            while flow.phase == .composing { await Task.yield() }
        }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.units == 1.5)
        flow.cancel()
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
        let d = StackingGuard.Disclosure(friction: .disclose, message: "At the pump's max bolus.")
        let s = StackingGuard.Disclosure(friction: .disclose, message: "A bolus was given 10 minutes ago.")
        let dose = ComposedDose(
            request: DoseRequest(id: "x", origin: .phone, shape: .now(units: 1), carbsGrams: nil, bgMgdl: nil),
            calculatorIOBUnits: nil, correctionGlucoseMgdl: nil, calculatorCarbUnits: nil,
            usedIncludedStaleGlucose: false,
            notices: [.cartridgeStateUnknown, .atPumpMax(d), .stacking(s)])
        let notices = BolusFlow.notices(dose)
        #expect(notices.count == 3)
        #expect(notices[0] == "A bolus was given 10 minutes ago.")
        #expect(notices[1] == "At the pump's max bolus.")
        #expect(notices[2].contains("cartridge"))
    }
}
