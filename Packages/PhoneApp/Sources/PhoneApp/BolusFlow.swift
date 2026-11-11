import Foundation
import Observation
import PumpSession
import faBolusCore

/// The phone's bolus screen, without its views: what's entered, the suggestion, and the steps from Confirm
/// to the pump. All dose checks are the composer's (`DoseComposer.composePhone`) and the session's; this
/// only asks the composer, shows what it asks, and passes on the user's answers, each naming the dose it
/// showed.
@Observable @MainActor
public final class BolusFlow {
    public enum Phase: Equatable {
        case editing
        /// Reading the dose inputs from the pump and composing.
        case composing
        /// The composer has a question.
        case prompt(PhoneDosePrompt)
        /// The dose is ready: the last check before it's sent, with its notices.
        case review(ComposedDose)
        case delivering
        /// The session's answer. A started dose's later moves come through the model's banner.
        case done(DeliveryResult)
        /// Nothing was sent, and why.
        case refused(String)
    }

    public let model: AppModel
    public var mode: BolusEntryMode
    public var carbsText = ""
    /// A glucose the user typed; empty corrects from the current CGM reading.
    public var glucoseText = ""
    /// Units to deliver. In carbs mode it follows the suggestion until the user changes it.
    public var unitsText = ""
    public private(set) var unitsEdited = false
    public private(set) var phase: Phase = .editing
    private var attempt: PhoneDoseEntry?
    /// The card the user chose, for the question it answered.
    private var correctionAnswer: CorrectionChoice?
    /// The composer's question from the pump's fresh read at Confirm, ahead of the screen's own: it holds
    /// until the screen's question changes from what it was then.
    private var composerQuestion: ComposerQuestion?

    public init(model: AppModel) {
        self.model = model
        mode = model.settings.defaultBolusMode
    }

    // MARK: Entry

    public var carbs: Double? { Self.parseNumber(carbsText) }
    public var typedGlucose: Int? { model.settings.glucoseUnit.parse(glucoseText.trimmingCharacters(in: .whitespaces)) }
    /// Something is typed in the glucose field that isn't a glucose: the dose waits for it to be fixed or
    /// cleared, rather than quietly correcting from the CGM instead.
    public var glucoseTextInvalid: Bool {
        mode == .carbs && typedGlucose == nil && !glucoseText.trimmingCharacters(in: .whitespaces).isEmpty
    }
    public var units: Double? { Self.parseNumber(unitsText) }

    /// A positive number, accepting a decimal comma; anything else is "nothing entered", never zero.
    public static func parseNumber(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let v = Double(t), v.isFinite, v >= 0 else { return nil }
        return v
    }

    /// The CGM reading the suggestion corrects from, when nothing is typed, it's current and the pump
    /// doesn't caution against it.
    public var currentReading: Int? {
        guard let g = model.display.glucoseForCorrection(thresholds: model.freshness, now: model.now) else {
            return nil
        }
        return g.mgdl
    }

    public var glucoseForCalculation: Int? { typedGlucose ?? currentReading }

    /// The suggestion for what's entered, from what's shown now.
    public var recommendation: DoseRecommendation {
        model.recommendation(carbsGrams: carbs ?? 0, glucoseMgdl: glucoseForCalculation)
    }

    /// Call when what the suggestion comes from changes (carbs, glucose, a new reading, IOB): the units
    /// follow the suggestion, or the card chosen, until edited by hand. With a question and no card chosen
    /// there's no dose yet.
    public func entryChanged() {
        guard mode == .carbs, !unitsEdited else { return }
        if correctionQuestion != nil {
            unitsText = correction.map { Self.unitsField($0.units) } ?? ""
            return
        }
        let r = recommendation
        unitsText = r.displaysNumericDose ? Self.unitsField(r.units) : ""
    }

    public func unitsTyped(_ text: String) {
        unitsText = text
        unitsEdited = true
    }

    /// Back to the calculator's dose (or the cards) after editing it by hand.
    public func useCalculatorDose() {
        unitsEdited = false
        entryChanged()
    }

    static func unitsField(_ units: Double) -> String { String(format: "%.2f", units) }

    /// What the screen follows: when it changes, `entryChanged` sets the units again.
    public struct Basis: Equatable {
        let units: Double
        let shows: Bool
        let question: CorrectionQuestion?
        let correction: CorrectionChoice?
    }

    public var basis: Basis {
        let r = recommendation
        return Basis(
            units: r.units, shows: r.displaysNumericDose, question: correctionQuestion, correction: correction)
    }

    // MARK: The correction question

    /// Whether to correct from the glucose, asked on the screen before Confirm, as Tandem's app asks at
    /// glucose entry: from 70 mg/dL up, when correcting changes the dose to another dose. Each answer is
    /// the whole dose it gives. The composer asks the same at Confirm from the pump's fresh read; an answer
    /// that no longer matches it is asked again here.
    public struct CorrectionQuestion: Sendable, Equatable {
        public let mgdl: Int
        public let targetMgdl: Int
        public let applyUnits: Double
        public let declineUnits: Double
        /// Above the target the question is whether to add a correction; below it, whether to reduce.
        public var above: Bool { mgdl > targetMgdl }
    }

    public struct CorrectionChoice: Sendable, Equatable {
        public let question: CorrectionQuestion
        public let apply: Bool
        public var units: Double { apply ? question.applyUnits : question.declineUnits }
    }

    /// The composer's question (or that there is none: `asked` nil), and the glucose it read, ahead of
    /// what the screen shows.
    struct ComposerQuestion: Equatable {
        let asked: CorrectionQuestion?
        let mgdl: Int?
        let screen: CorrectionQuestion?
    }

    /// The question from what the screen shows.
    var screenQuestion: CorrectionQuestion? {
        guard mode == .carbs, let mgdl = glucoseForCalculation, mgdl >= CalculatorMessage.lowGlucoseMgdl,
            CalculatorGlucose.isValid(mgdl: mgdl)
        else { return nil }
        let with = recommendation
        let without = model.recommendation(carbsGrams: carbs ?? 0, glucoseMgdl: nil)
        guard with.displaysNumericDose, without.displaysNumericDose,
            let target = with.inputs.settings?.value.targetMgdl,
            with.units > 0, without.units > 0, abs(with.units - without.units) > 1e-9
        else { return nil }
        return CorrectionQuestion(
            mgdl: mgdl, targetMgdl: target, applyUnits: with.units, declineUnits: without.units)
    }

    /// The question showing, or nil.
    public var correctionQuestion: CorrectionQuestion? {
        let screen = screenQuestion
        if let c = composerQuestion, c.screen == screen { return c.asked }
        return screen
    }

    /// The card chosen, while it answers the question showing and the dose wasn't edited since.
    public var correction: CorrectionChoice? {
        guard !unitsEdited, let a = correctionAnswer, a.question == correctionQuestion else { return nil }
        return a
    }

    /// What changed the doses after the user chose, other than their own typing (which just clears the
    /// choice): a new reading, or the IOB or the pump's settings. The choice is cleared until they choose
    /// again. Or the question no longer applies at all: a BG under 70 or none current, or a correction
    /// that no longer changes the dose.
    public enum CorrectionChange: Equatable {
        case glucose(fromMgdl: Int, toMgdl: Int)
        case doses
        case noQuestion(fromMgdl: Int, toMgdl: Int?)
    }

    public var correctionChange: CorrectionChange? {
        guard !unitsEdited, let a = correctionAnswer else { return nil }
        guard let q = correctionQuestion else {
            let now = composerQuestion.flatMap { $0.screen == screenQuestion ? $0.mgdl : nil } ?? glucoseForCalculation
            return .noQuestion(fromMgdl: a.question.mgdl, toMgdl: now)
        }
        guard a.question != q else { return nil }
        if q.mgdl != a.question.mgdl { return .glucose(fromMgdl: a.question.mgdl, toMgdl: q.mgdl) }
        return .doses
    }

    /// The change, until the user has seen it: shown as an alert, so a dose that changed under them never
    /// looks like the screen glitched. Once seen, a reminder stays by the cards.
    public var changeAlert: CorrectionChange? {
        guard let change = correctionChange, let a = correctionAnswer else { return nil }
        return acknowledgedChange == AcknowledgedChange(answer: a, question: correctionQuestion) ? nil : change
    }

    struct AcknowledgedChange: Equatable {
        let answer: CorrectionChoice
        let question: CorrectionQuestion?
    }

    private var acknowledgedChange: AcknowledgedChange?

    /// The alert closed. With no question left, the old choice is dropped and the dose is the calculator's.
    public func acknowledgeChange() {
        guard let a = correctionAnswer else { return }
        if correctionQuestion == nil {
            correctionAnswer = nil
            acknowledgedChange = nil
            entryChanged()
            return
        }
        acknowledgedChange = AcknowledgedChange(answer: a, question: correctionQuestion)
    }

    /// The user changed the carbs, the glucose or the mode themselves: the choice is cleared without an
    /// alert, as they made the change.
    public func entryEdited() {
        correctionAnswer = nil
        acknowledgedChange = nil
        composerQuestion = nil
        entryChanged()
    }

    /// The alert, as short as the watch's screen: what changed as its title, what it means in a line (none
    /// when the button says it), and what to do on its button.
    public func text(for change: CorrectionChange) -> (title: String, message: String, warning: String?, button: String)
    {
        let unit = model.settings.glucoseUnit
        func went(_ from: Int, _ to: Int) -> String {
            // On one line, the unit on both values.
            "BG \(unit.format(mgdl: from))\u{00A0}\(Self.mgdl) → \(unit.format(mgdl: to))\u{00A0}\(Self.mgdl)"
        }
        switch change {
        case .glucose(let from, let to):
            // The title says what changed and the button what to do: nothing to add between them.
            return (went(from, to), "", nil, "Choose again")
        case .doses:
            return ("Insulin or settings changed", "", nil, "Choose again")
        case .noQuestion(let from, let to):
            // No choice now: a low reduces the dose (or takes it all), IOB (or a BG now on target) leaves no
            // correction to add, or there's no current reading.
            let r = recommendation
            let units = r.displaysNumericDose ? r.units : nil
            let dose = units.map { ": \(formatUnits($0))" } ?? ""
            guard let to else { return ("No current BG", "Carbs only\(dose).", nil, "See the dose") }
            // Outside 20–600 the calculator can't correct from it, as the watch says it; under 20, still eat.
            guard CalculatorGlucose.isValid(mgdl: to) else {
                let low = to < CalculatorMessage.lowGlucoseMgdl
                return (
                    went(from, to), low ? "Too low for a carb dose." : "Too high for a carb dose.",
                    low ? "Eat carbs." : nil,
                    "OK"
                )
            }
            // Nothing to see when the glucose took the whole dose.
            let none = units == 0
            let button = none ? "OK" : "See the dose"
            if to < CalculatorMessage.lowGlucoseMgdl {
                // What to do, apart, so the screen can mark it as the watch does.
                let what = none ? "No bolus." : "Dose reduced to \(formatUnits(units ?? 0))."
                return (went(from, to), what, "Eat carbs.", button)
            }
            // From 70 up, below the target: the reduction took the whole dose.
            if none { return (went(from, to), "No bolus.", nil, button) }
            return (went(from, to), "No correction needed\(dose).", nil, button)
        }
    }

    /// A card tapped: its dose is the dose.
    public func chooseCorrection(apply: Bool) {
        guard let q = correctionQuestion else { return }
        correctionAnswer = CorrectionChoice(question: q, apply: apply)
        unitsEdited = false
        entryChanged()
    }

    /// What stops a bolus whatever is entered (the same checks the composer makes first), or a glucose
    /// that needs fixing; shown on the screen as it is.
    public var blockingReason: String? {
        if let refusal = model.phoneBolusAvailability { return refusal.userMessage }
        if glucoseTextInvalid { return Self.invalidGlucoseText }
        return nil
    }

    /// Why the Confirm button can't be used now.
    public var unavailableReason: String? {
        if let blockingReason { return blockingReason }
        // A typed glucose the calculator can't correct from is refused at Confirm: the button waits instead.
        if mode == .carbs, let g = typedGlucose, !CalculatorGlucose.isValid(mgdl: g) { return Self.outOfRangeText }
        if needsChoice { return Self.chooseText }
        guard let u = units, u > 0 else { return "Enter a dose." }
        return nil
    }

    /// A question shows and no card answers it (or its answer went stale): nothing to send until one is
    /// chosen, whatever the units field still holds.
    var needsChoice: Bool { mode == .carbs && !unitsEdited && correctionQuestion != nil && correction == nil }

    public static let chooseText = "Choose a dose above."

    /// "mg/dL" that a line never breaks inside, nor before.
    static let mgdl = "mg\u{2060}/\u{2060}dL"

    static let outOfRangeText = "Enter a glucose from 20 to 600 mg/dL, or clear it to use the CGM reading."

    static let invalidGlucoseText = "Enter glucose as a whole number in mg/dL, or clear it to use the CGM reading."

    // MARK: Steps

    /// Confirm pressed: a fresh attempt.
    public func confirm() async {
        guard !glucoseTextInvalid else {
            phase = .refused(Self.invalidGlucoseText)
            return
        }
        // A card still to choose, or a change still to be seen.
        if changeAlert != nil || needsChoice {
            entryChanged()
            return
        }
        guard let entry = makeEntry() else {
            phase = .refused("Enter a dose.")
            return
        }
        attempt = entry
        await compose()
    }

    private func makeEntry() -> PhoneDoseEntry? {
        guard let units, units > 0 else { return nil }
        let id = UUID().uuidString
        switch mode {
        case .units:
            return PhoneDoseEntry(id: id, amount: .units(units))
        case .carbs:
            let glucose: PhoneDoseEntry.Glucose =
                typedGlucose.map { .typed(mgdl: $0) } ?? .currentReading(shownMgdl: currentReading)
            // A card's dose goes with the answer it gave, so the composer delivers exactly that dose, or asks
            // again (here, on the screen) if the pump's fresh read changes it. Entered as the card's own dose,
            // so nothing can send the other card's.
            if let c = correction {
                let q = c.question
                return PhoneDoseEntry(
                    id: id,
                    amount: .calculator(
                        carbsGrams: carbs ?? 0, glucose: glucose, recommendedUnits: c.units,
                        enteredUnits: c.units),
                    answers: PhoneDoseAnswers(correction: .init(mgdl: q.mgdl, apply: c.apply, units: c.units)))
            }
            return PhoneDoseEntry(
                id: id,
                amount: .calculator(
                    carbsGrams: carbs ?? 0, glucose: glucose, recommendedUnits: recommendation.units,
                    enteredUnits: units))
        }
    }

    private func compose() async {
        guard let attempt else { return }
        phase = .composing
        show(await model.composePhoneDose(attempt))
    }

    /// The composer's answer, shown. Its correction question is asked on the screen, not in a dialog: the
    /// cards take the doses from the pump's fresh read, and the user chooses again.
    private func show(_ decision: PhoneDoseDecision) {
        switch decision {
        case .deliver(let dose): phase = .review(dose)
        case .confirm(.correction(let mgdl, let target, let apply, let decline)):
            composerQuestion = ComposerQuestion(
                asked: CorrectionQuestion(mgdl: mgdl, targetMgdl: target, applyUnits: apply, declineUnits: decline),
                mgdl: mgdl, screen: screenQuestion)
            unitsEdited = false
            attempt = nil
            phase = .editing
            entryChanged()
        // A card's dose that the composer no longer asks about (the fresh read is under 70, or the
        // correction no longer changes the dose): never "keep" it, as its correction came from the old
        // reading. Back to the screen, which says the question went and shows the dose for now.
        case .confirm(.doseChanged(let mgdl, _, _)) where attempt?.answers.correction != nil:
            composerQuestion = ComposerQuestion(asked: nil, mgdl: mgdl, screen: screenQuestion)
            unitsEdited = false
            attempt = nil
            phase = .editing
            entryChanged()
        case .confirm(let prompt): phase = .prompt(prompt)
        case .refused(let refusal): phase = .refused(refusal.userMessage)
        }
    }

    /// The user's answer to the prompt showing; composed again with it.
    public func answer(_ answer: Answer) async {
        guard take(answer) else { return }
        await compose()
    }

    /// The answer from a dialog's button: taken at once, so the dialog closing after the tap isn't read as
    /// a cancel, then composed.
    public func choose(_ answer: Answer) {
        guard take(answer) else { return }
        Task { await compose() }
    }

    /// Records the answer for the prompt showing and leaves the prompt; false when it doesn't fit.
    private func take(_ answer: Answer) -> Bool {
        guard case .prompt(let prompt) = phase, var entry = attempt else { return false }
        switch (prompt, answer) {
        case (.calculatorInputs(let kind, let units, _), .useLastKnownInputs):
            entry.answers.calculatorOverride = .init(kind: kind, units: units)
        case (.staleGlucose(let reading, let include?, _), .includeStaleReading):
            guard let reading else { return false }
            entry.answers.staleGlucose = .include(
                mgdl: reading.value.mgdl, measuredAt: reading.measuredAt, units: include)
        case (.staleGlucose(_, _, let carbsOnly), .carbsOnly), (.pumpGlucoseCaution(_, let carbsOnly), .carbsOnly):
            entry.answers.staleGlucose = .carbsOnly(units: carbsOnly)
        case (.doseChanged(let mgdl, let new, _), .useNewDose):
            entry.answers.doseChanged = .useNew(mgdl: mgdl, units: new)
        case (.doseChanged(let mgdl, let new, let entered), .keepEnteredDose):
            entry.answers.doseChanged = .keepEntered(mgdl: mgdl, enteredUnits: entered, newUnits: new)
        case (.confirmation(let confirmation, let units), .goOn):
            entry.answers.confirmed[confirmation.kind] = .init(confirmation, units: units)
        default:
            return false
        }
        attempt = entry
        phase = .composing
        return true
    }

    public enum Answer: Sendable, Equatable {
        case useLastKnownInputs, includeStaleReading, carbsOnly, useNewDose, keepEnteredDose, goOn
    }

    /// The reviewed dose, sent. The inputs are read from the pump again first, as the review may have
    /// sat open (a bolus from the watch meanwhile, a new glucose): the dose sent is the one reviewed only
    /// while that reading still gives the same dose for the same reasons; otherwise the new one is shown
    /// for review, or the composer's question asked. The phase leaves the review before the first
    /// suspension, so the review sheet can't be read as cancelled meanwhile.
    public func deliver() async {
        guard case .review(let reviewed) = phase, let attempt else { return }
        phase = .delivering
        switch await model.composePhoneDose(attempt) {
        case .deliver(let fresh) where Self.sameDose(fresh, reviewed):
            let result = await model.deliver(fresh)
            phase = .done(result)
            if case .started = result { reset() }
        case let other: show(other)
        }
    }

    /// The same units, correcting from the same glucose, with the same kinds of notice.
    static func sameDose(_ a: ComposedDose, _ b: ComposedDose) -> Bool {
        func kinds(_ d: ComposedDose) -> [Int] { d.notices.map(rank).sorted() }
        return a.units == b.units && a.correctionGlucoseMgdl == b.correctionGlucoseMgdl && kinds(a) == kinds(b)
    }

    /// Any prompt or the review cancelled: nothing is sent.
    public func cancel() {
        attempt = nil
        phase = .editing
    }

    public func dismissResult() { phase = .editing }

    private func reset() {
        attempt = nil
        carbsText = ""
        glucoseText = ""
        unitsText = ""
        unitsEdited = false
        correctionAnswer = nil
        composerQuestion = nil
        acknowledgedChange = nil
    }

    // MARK: Copy

    /// A prompt's question and its choices, the first the default.
    public func text(for prompt: PhoneDosePrompt) -> (title: String, message: String, choices: [(Answer, String)]) {
        let now = model.now
        switch prompt {
        case .calculatorInputs(let kind, let units, let inputs):
            var parts: [String] = []
            if kind.allowStaleIob {
                parts.append(
                    StaleIobPrompt.warningMessage(
                        iobUnits: inputs.calculatorInsulinOnBoardUnits ?? 0, iobDate: inputs.insulinOnBoard?.measuredAt,
                        now: now))
            }
            if kind.allowStaleTherapy {
                let profile = inputs.settings.map {
                    BolusMath.Profile(
                        carbRatioGramsPerUnit: $0.value.carbRatio, isfMgdlPerUnit: $0.value.correctionFactor,
                        targetBgMgdl: $0.value.targetMgdl, iobUnits: inputs.calculatorInsulinOnBoardUnits ?? 0)
                }
                parts.append(
                    StaleTherapyPrompt.warningMessage(
                        profile: profile, therapyDate: inputs.settings?.measuredAt, now: now))
            }
            return (
                "Pump settings not confirmed", parts.joined(separator: "\n\n"),
                [(.useLastKnownInputs, "Use them for \(formatUnits(units))")]
            )
        case .staleGlucose(let reading, let include, let carbsOnly):
            let message =
                reading.map {
                    StaleBolusPrompt.warningMessage(glucoseMgdl: $0.value.mgdl, glucoseDate: $0.measuredAt, now: now)
                } ?? "There's no CGM reading, so this dose has no correction. Bolus for carbs only, or cancel?"
            var choices: [(Answer, String)] = []
            if let include { choices.append((.includeStaleReading, "Include it (\(formatUnits(include)))")) }
            choices.append((.carbsOnly, "Carbs only (\(formatUnits(carbsOnly)))"))
            return (reading == nil ? "No CGM reading" : "CGM reading is old", message, choices)
        case .pumpGlucoseCaution(let caution, let carbsOnly):
            return (
                "CGM reading can't be used",
                Self.cautionMessage(caution) + " Bolus for carbs only, or cancel and enter a BG?",
                [(.carbsOnly, "Carbs only (\(formatUnits(carbsOnly)))")]
            )
        case .doseChanged(let mgdl, let new, let entered):
            let reading = mgdl.map { " for \(model.settings.glucoseUnit.format(mgdl: $0)) mg/dL" } ?? ""
            return (
                "Dose changed",
                "The pump's latest readings make the calculator's dose \(formatUnits(new))\(reading). You entered \(formatUnits(entered)).",
                [(.useNewDose, "Use \(formatUnits(new))"), (.keepEnteredDose, "Keep \(formatUnits(entered))")]
            )
        case .confirmation(let confirmation, let units):
            return (confirmation.title, confirmation.message, [(.goOn, "Deliver \(formatUnits(units))")])
        case .correction:
            // Asked on the bolus screen, with its cards (`correctionQuestion`); `show` never makes it a dialog.
            // Should one show, it says where to choose, and its Cancel goes back there.
            return ("Choose a dose", "Choose a dose on the bolus screen.", [])
        }
    }

    /// Why the pump's CGM reading can't correct the dose, as the pump says it.
    static func cautionMessage(_ caution: PumpGlucoseCaution) -> String {
        switch caution {
        case .outOfRange(.low): return "The CGM reads LOW, below the range it can measure."
        case .outOfRange(.high): return "The CGM reads HIGH, above the range it can measure."
        case .checkBG: return "The CGM says to check your BG: its reading may not be accurate."
        case .autoFillOff: return "The pump doesn't allow its CGM reading in the bolus calculator right now."
        case .cgmStateNotRead: return "The pump's CGM state couldn't be read for this dose."
        case .sensorState(let state): return "The pump shows \(cgmStateName(state)) instead of a CGM reading."
        }
    }

    /// The bolus screen's line for a reading the pump flags: why, and that the dose is carbs only. `nil` for
    /// a CGM state not read yet, which isn't a reason by itself.
    public static func cautionLine(_ caution: PumpGlucoseCaution) -> String? {
        switch caution {
        case .outOfRange(.low): return "CGM below its range: carbs only. Check your BG."
        case .outOfRange(.high): return "CGM above its range: carbs only. Check your BG."
        case .checkBG: return "CGM says check BG: carbs only"
        case .autoFillOff: return "Pump won't use its CGM in the calculator: carbs only"
        case .sensorState(let state): return "Pump shows \(cgmStateName(state)): carbs only"
        case .cgmStateNotRead: return nil
        }
    }

    /// The pump's CGM state in words.
    static func cgmStateName(_ state: PumpCGMState) -> String {
        switch state {
        case .noError: return "a CGM reading"
        case .warmingUp: return "the sensor warming up"
        case .calibrate: return "Calibrate CGM"
        case .calibrationError: return "a calibration error"
        case .replaceSensor: return "Replace Sensor"
        case .sensorFailed: return "Sensor Failed"
        case .replaceTransmitter: return "Replace Transmitter"
        case .restartSensor: return "Restart Sensor"
        case .outOfRange: return "CGM out of range of the pump"
        case .noReading: return "no reading (---)"
        case .low: return "LOW"
        case .high: return "HIGH"
        case .unknown(let id): return "a CGM state faBolus doesn't know (\(id))"
        }
    }

    /// The notices for a dose, most important first. They never change the dose.
    public static func notices(_ dose: ComposedDose) -> [String] {
        dose.notices.sorted { rank($0) < rank($1) }.compactMap(text(for:))
    }

    /// A notice's kind, most important first.
    static func rank(_ n: DoseNotice) -> Int {
        switch n {
        case .calculator: return 0
        case .stacking: return 1
        case .atPumpMax: return 2
        case .differsFromCalculator: return 3
        case .cartridgeStateUnknown: return 4
        }
    }

    static func text(for notice: DoseNotice) -> String? {
        switch notice {
        case .cartridgeStateUnknown:
            return "The cartridge state wasn't read. If no cartridge is loaded, the pump refuses the bolus."
        case .stacking(let d), .atPumpMax(let d):
            return [d.message, d.detail].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        case .differsFromCalculator(let delivered, let suggested):
            return "This is \(formatUnits(delivered)); the calculator suggests \(formatUnits(suggested))."
        case .calculator(let message):
            return message.text
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
