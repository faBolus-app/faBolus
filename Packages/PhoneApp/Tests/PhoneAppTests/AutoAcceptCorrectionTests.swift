import Foundation
import PumpScript
import PumpSession
import RemoteProtocol
import Testing
@testable import faBolusCore

@testable import PhoneApp

/// Settings → Auto-accept corrections: the calculator's correction question answered yes for the user. It
/// answers only that question, only when it would be asked, and every dose still goes through the composer.
@MainActor
@Suite struct AutoAcceptCorrectionTests {
    /// A launched phone with the pump at `glucose` (mg/dL, seconds old; nil for none), the setting on.
    func phone(
        glucose: (Int, Double)? = (220, 30), autoAccept: Bool = true, _ configure: (ScriptedPump) -> Void = { _ in }
    ) async -> (Phone, AppModel) {
        let phone = Phone()
        phone.mock.pump.glucose = glucose
        configure(phone.mock.pump)
        let model = await phone.launch()
        _ = await phone.until(model) { model.pump.link == .connected }
        // The link has held, so the delivery's untested commands may go out.
        await phone.run(model, for: 12)
        model.settings.autoAcceptCorrection = autoAccept
        return (phone, model)
    }

    func carbs(_ model: AppModel, _ grams: String = "30", glucose: String = "") -> BolusFlow {
        let flow = BolusFlow(model: model)
        flow.mode = .carbs
        flow.carbsText = grams
        flow.glucoseText = glucose
        flow.entryEdited()
        return flow
    }

    @Test func itIsOffByDefault() throws {
        let suite = "settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: defaults)
        #expect(!s.autoAcceptCorrection)
        s.autoAcceptCorrection = true
        #expect(AppSettings(defaults: defaults).autoAcceptCorrection)
        #expect(s.watchPreferences.autoAcceptCorrection)
    }

    /// Off, the question waits for a card exactly as before.
    @Test func offTheQuestionWaitsForACard() async {
        let (phone, model) = await phone(autoAccept: false)
        let flow = carbs(model)
        #expect(flow.correctionQuestion?.mgdl == 220)
        #expect(flow.correction == nil)
        #expect(flow.autoCorrection == nil)
        #expect(flow.unavailableReason == BolusFlow.chooseText)
        await phone.driving(model) { await flow.confirm() }
        #expect(flow.phase == .editing)
        await model.shutdown()
    }

    /// Above target: both cards still show, the corrected one chosen, and Confirm reviews that dose, which
    /// corrects from the reading.
    @Test func aboveTargetTheCorrectionIsChosen() async {
        let (phone, model) = await phone(glucose: (220, 30))
        let flow = carbs(model)
        guard let q = flow.correctionQuestion else {
            Issue.record("expected the question to show")
            return
        }
        #expect(q.above)
        #expect(flow.correction == BolusFlow.CorrectionChoice(question: q, apply: true))
        #expect(flow.autoCorrection != nil)
        #expect(flow.units == q.applyUnits)
        #expect(flow.unavailableReason == nil)
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.units == q.applyUnits)
        #expect(dose.correctionGlucoseMgdl == 220, "the review shows the correction")
        #expect(model.latestOutcome == nil, "the review is still the user's to confirm")
        await model.shutdown()
    }

    /// Below target, from 70 up: the reduction is chosen.
    @Test func belowTargetTheReductionIsChosen() async {
        let (phone, model) = await phone(glucose: (80, 30))
        let flow = carbs(model)
        guard let q = flow.correctionQuestion else {
            Issue.record("expected the question to show")
            return
        }
        #expect(!q.above)
        #expect(q.applyUnits < q.declineUnits)
        #expect(flow.correction?.apply == true)
        #expect(flow.units == q.applyUnits)
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.units == q.applyUnits)
        #expect(dose.correctionGlucoseMgdl == 80)
        await model.shutdown()
    }

    /// A typed glucose asks the same question, and is answered the same way.
    @Test func aTypedGlucoseIsAnsweredToo() async {
        let (phone, model) = await phone(glucose: nil)
        let flow = carbs(model, glucose: "240")
        #expect(flow.correction?.apply == true)
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.correctionGlucoseMgdl == 240)
        await model.shutdown()
    }

    /// The other card can still be tapped, and is the user's answer: it holds, and Confirm sends it.
    @Test func theOtherCardCanStillBeTapped() async {
        let (phone, model) = await phone(glucose: (220, 30))
        let flow = carbs(model)
        let q = flow.correctionQuestion
        flow.chooseCorrection(apply: false)
        #expect(flow.correction?.apply == false)
        #expect(flow.autoCorrection == nil)
        #expect(flow.units == q?.declineUnits)
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.units == q?.declineUnits)
        #expect(dose.correctionGlucoseMgdl == nil)
        await model.shutdown()
    }

    /// A dose typed by hand is sent as typed, with nothing chosen for it, as without the setting.
    @Test func anEditedDoseIsSentAsTyped() async {
        let (phone, model) = await phone(glucose: (220, 30))
        let flow = carbs(model)
        flow.unitsTyped("1")
        #expect(flow.correction == nil)
        #expect(flow.autoCorrection == nil)
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.units == 1)
        flow.cancel()
        // Back to the calculator: the corrected card again.
        flow.useCalculatorDose()
        #expect(flow.correction?.apply == true)
        await model.shutdown()
    }

    /// No question, nothing answered: a stale reading, one the pump flags, a BG under 70 and no reading at
    /// all each give the dose they give without the setting, and a stale or flagged one corrects nothing.
    @Test func withNoQuestionNothingIsAnswered() async {
        // Stale, too old to include: carbs only.
        do {
            let (phone, model) = await phone(glucose: (220, 30 * 60))
            let flow = carbs(model)
            #expect(flow.correctionQuestion == nil && flow.correction == nil)
            await phone.driving(model) { await flow.confirm() }
            guard case .review(let dose) = flow.phase else {
                Issue.record("stale: expected the review, got \(flow.phase)")
                return
            }
            #expect(dose.correctionGlucoseMgdl == nil)
            await model.shutdown()
        }
        // Stale but includable: still asked whether to include it, never included for the user.
        do {
            let (phone, model) = await phone(glucose: (220, 9 * 60))
            let flow = carbs(model)
            #expect(flow.correctionQuestion == nil && flow.correction == nil)
            await phone.driving(model) { await flow.confirm() }
            guard case .prompt(.staleGlucose) = flow.phase else {
                Issue.record("stale includable: expected the stale-reading prompt, got \(flow.phase)")
                return
            }
            await model.shutdown()
        }
        // The pump won't let its reading fill in a correction.
        do {
            let (phone, model) = await phone(glucose: (220, 30)) { $0.glucoseAutoFillAllowed = false }
            let flow = carbs(model)
            #expect(flow.correctionQuestion == nil && flow.correction == nil)
            #expect(flow.currentReading == nil)
            await phone.driving(model) { await flow.confirm() }
            if case .review(let dose) = flow.phase {
                #expect(dose.correctionGlucoseMgdl == nil)
            } else if case .prompt(.pumpGlucoseCaution) = flow.phase {
            } else {
                Issue.record("caution: expected carbs only, got \(flow.phase)")
            }
            await model.shutdown()
        }
        // Under 70: no question, the calculator's reduction as always.
        do {
            let (_, model) = await phone(glucose: (60, 30))
            let flow = carbs(model)
            #expect(flow.correctionQuestion == nil && flow.correction == nil)
            #expect(flow.units == flow.recommendation.units)
            await model.shutdown()
        }
        // No reading at all.
        do {
            let (phone, model) = await phone(glucose: nil)
            let flow = carbs(model)
            #expect(flow.correctionQuestion == nil && flow.correction == nil)
            await phone.driving(model) { await flow.confirm() }
            guard case .review(let dose) = flow.phase else {
                Issue.record("no reading: expected the review, got \(flow.phase)")
                return
            }
            #expect(dose.correctionGlucoseMgdl == nil)
            await model.shutdown()
        }
    }

    /// A new reading while the screen is open: the chosen card follows it, with nothing to choose again,
    /// as the dose with no question follows the calculator.
    @Test func aNewReadingWhileEditingIsFollowed() async {
        let (phone, model) = await phone(glucose: (220, 30))
        let flow = carbs(model)
        #expect(flow.correction?.question.mgdl == 220)
        phone.mock.pump.glucose = (180, 5)
        #expect(await phone.until(model) { flow.currentReading == 180 }, "the screen has the new reading")
        flow.entryChanged()
        #expect(flow.correctionQuestion?.mgdl == 180)
        #expect(flow.correction?.question.mgdl == 180)
        #expect(flow.correction?.apply == true)
        #expect(flow.units == flow.correctionQuestion?.applyUnits)
        #expect(flow.changeAlert == nil)
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.correctionGlucoseMgdl == 180)
        await model.shutdown()
    }

    /// The reading moves just before Confirm, so only the pump's fresh read sees it: nothing is sent, the
    /// screen says the BG changed, and once seen the corrected dose from the new reading is chosen.
    @Test func aReadingOnlyConfirmSawIsSaid() async {
        let (phone, model) = await phone(glucose: (220, 30))
        let flow = carbs(model)
        let first = flow.units
        phone.mock.pump.glucose = (250, 1)
        await phone.driving(model) { await flow.confirm() }
        #expect(flow.phase == .editing)
        #expect(flow.correctionQuestion?.mgdl == 250)
        #expect(flow.changeAlert == .glucose(fromMgdl: 220, toMgdl: 250))
        #expect(flow.text(for: .glucose(fromMgdl: 220, toMgdl: 250)).button == "See the dose")
        // Confirm waits for the alert to be seen.
        await phone.driving(model) { await flow.confirm() }
        #expect(flow.phase == .editing)
        flow.acknowledgeChange()
        #expect(flow.changeAlert == nil)
        #expect(flow.correction?.question.mgdl == 250)
        #expect(flow.units != first)
        let q = flow.correctionQuestion
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.units == q?.applyUnits)
        #expect(dose.correctionGlucoseMgdl == 250)
        #expect(model.latestOutcome == nil, "nothing was sent")
        await model.shutdown()
    }

    /// The screen had no question (a BG under 70) and the pump's fresh read at Confirm asks one: the setting
    /// answers it, and the screen says the BG changed before that dose can be confirmed.
    @Test func aQuestionOnlyConfirmSawIsSaid() async {
        let (phone, model) = await phone(glucose: (60, 30))
        let flow = carbs(model)
        #expect(flow.correctionQuestion == nil)
        phone.mock.pump.glucose = (90, 1)
        await phone.driving(model) { await flow.confirm() }
        #expect(flow.phase == .editing)
        #expect(flow.correctionQuestion?.mgdl == 90)
        #expect(flow.changeAlert == .glucose(fromMgdl: 60, toMgdl: 90))
        #expect(flow.text(for: .glucose(fromMgdl: 60, toMgdl: 90)).button == "See the dose")
        flow.acknowledgeChange()
        #expect(flow.correction?.apply == true)
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.correctionGlucoseMgdl == 90)
        #expect(model.latestOutcome == nil, "nothing was sent")
        await model.shutdown()
    }

    /// A review left open while the reading moves: Deliver reads the pump again and nothing goes; the screen
    /// says the BG changed before the new dose can be confirmed.
    @Test func aReadingThatMovesUnderTheReviewIsSaid() async {
        let (phone, model) = await phone(glucose: (220, 30))
        let flow = carbs(model)
        await phone.driving(model) { await flow.confirm() }
        guard case .review = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        phone.mock.pump.glucose = (260, 1)
        await phone.run(model, for: 2)
        await phone.driving(model) { await flow.deliver() }
        #expect(flow.phase == .editing)
        #expect(flow.changeAlert == .glucose(fromMgdl: 220, toMgdl: 260))
        #expect(model.latestOutcome == nil, "nothing was sent")
        await model.shutdown()
    }

    /// The fresh read at Confirm is under 70: the question went, which is said, and once seen the dose is
    /// the calculator's reduction.
    @Test func aReadingThatEndsTheQuestionIsSaid() async {
        let (phone, model) = await phone(glucose: (220, 30))
        let flow = carbs(model)
        phone.mock.pump.glucose = (60, 1)
        await phone.driving(model) { await flow.confirm() }
        #expect(flow.phase == .editing)
        #expect(flow.correctionQuestion == nil)
        #expect(flow.changeAlert == .noQuestion(fromMgdl: 220, toMgdl: 60))
        flow.acknowledgeChange()
        #expect(flow.changeAlert == nil)
        await phone.driving(model) { await flow.confirm() }
        guard case .review(let dose) = flow.phase else {
            Issue.record("expected the review, got \(flow.phase)")
            return
        }
        #expect(dose.correctionGlucoseMgdl == 60, "the reduction for the low applies")
        #expect(model.latestOutcome == nil, "nothing was sent")
        await model.shutdown()
    }

    /// A card the user tapped that went stale is theirs to choose again: the setting doesn't choose for it.
    @Test func aTappedCardThatWentStaleIsAskedAgain() async {
        let (phone, model) = await phone(glucose: (220, 30))
        let flow = carbs(model)
        flow.chooseCorrection(apply: false)
        phone.mock.pump.glucose = (250, 1)
        await phone.driving(model) { await flow.confirm() }
        #expect(flow.changeAlert == .glucose(fromMgdl: 220, toMgdl: 250))
        #expect(flow.text(for: .glucose(fromMgdl: 220, toMgdl: 250)).button == "Choose again")
        flow.acknowledgeChange()
        #expect(flow.correction == nil)
        #expect(flow.unavailableReason == BolusFlow.chooseText)
        await model.shutdown()
    }

    /// The pump's own confirmations are still asked: the setting answers only the correction question.
    @Test func thePumpsConfirmationsAreStillAsked() async {
        let (phone, model) = await phone(glucose: (220, 30)) { $0.tooManyBolusesIOB = true }
        let flow = carbs(model)
        #expect(flow.correction?.apply == true)
        await phone.driving(model) { await flow.confirm() }
        guard case .prompt(.confirmation(.tooManyBoluses, _)) = flow.phase else {
            Issue.record("expected the too-many-boluses question, got \(flow.phase)")
            return
        }
        await model.shutdown()
    }

    /// The watch is told through its config, and asks again once the setting is off.
    @Test func theWatchConfigCarriesIt() async throws {
        let (phone, model) = await phone(autoAccept: false)
        #expect(try #require(model.watch?.config).autoAcceptCorrection == false)
        model.settings.autoAcceptCorrection = true
        await phone.settle(model)
        let on = try #require(model.watch?.config)
        #expect(on.autoAcceptCorrection)
        model.settings.autoAcceptCorrection = false
        await phone.settle(model)
        let off = try #require(model.watch?.config)
        #expect(!off.autoAcceptCorrection)
        #expect(on.revision != off.revision, "a watch holding the old config fetches the new one")
        await model.shutdown()
    }
}
