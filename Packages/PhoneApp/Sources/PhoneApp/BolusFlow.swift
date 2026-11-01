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

    /// The CGM reading the suggestion corrects from, when nothing is typed and it's current.
    public var currentReading: Int? {
        guard let g = model.display.glucoseIfFresh(thresholds: model.freshness, now: model.now) else { return nil }
        return g.mgdl
    }

    public var glucoseForCalculation: Int? { typedGlucose ?? currentReading }

    /// The suggestion for what's entered, from what's shown now.
    public var recommendation: DoseRecommendation {
        model.recommendation(carbsGrams: carbs ?? 0, glucoseMgdl: glucoseForCalculation)
    }

    /// Call when carbs or glucose change: the units follow the suggestion until edited by hand.
    public func entryChanged() {
        guard mode == .carbs, !unitsEdited else { return }
        let r = recommendation
        unitsText = r.displaysNumericDose ? String(format: "%.2f", r.units) : ""
    }

    public func unitsTyped(_ text: String) {
        unitsText = text
        unitsEdited = true
    }

    /// Why the Confirm button can't be used now, the same checks the composer makes first.
    public var unavailableReason: String? {
        if let refusal = model.phoneBolusAvailability { return refusal.userMessage }
        if glucoseTextInvalid { return Self.invalidGlucoseText }
        guard let u = units, u > 0 else { return "Enter a dose." }
        return nil
    }

    static let invalidGlucoseText = "Enter glucose as a whole number in mg/dL, or clear it to use the CGM reading."

    // MARK: Steps

    /// Confirm pressed: a fresh attempt.
    public func confirm() async {
        guard !glucoseTextInvalid else {
            phase = .refused(Self.invalidGlucoseText)
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
        switch await model.composePhoneDose(attempt) {
        case .deliver(let dose): phase = .review(dose)
        case .confirm(let prompt): phase = .prompt(prompt)
        case .refused(let refusal): phase = .refused(refusal.userMessage)
        }
    }

    /// The user's answer to the prompt showing; composed again with it.
    public func answer(_ answer: Answer) async {
        guard case .prompt(let prompt) = phase, var entry = attempt else { return }
        switch (prompt, answer) {
        case (.calculatorInputs(let kind, let units, _), .useLastKnownInputs):
            entry.answers.calculatorOverride = .init(kind: kind, units: units)
        case (.staleGlucose(let reading, let include?, _), .includeStaleReading):
            guard let reading else { return }
            entry.answers.staleGlucose = .include(
                mgdl: reading.value.mgdl, measuredAt: reading.measuredAt, units: include)
        case (.staleGlucose(_, _, let carbsOnly), .carbsOnly):
            entry.answers.staleGlucose = .carbsOnly(units: carbsOnly)
        case (.doseChanged(let mgdl, let new, _), .useNewDose):
            entry.answers.doseChanged = .useNew(mgdl: mgdl, units: new)
        case (.doseChanged(let mgdl, let new, let entered), .keepEnteredDose):
            entry.answers.doseChanged = .keepEntered(mgdl: mgdl, enteredUnits: entered, newUnits: new)
        default:
            return
        }
        attempt = entry
        await compose()
    }

    public enum Answer: Sendable, Equatable {
        case useLastKnownInputs, includeStaleReading, carbsOnly, useNewDose, keepEnteredDose
    }

    /// The reviewed dose, sent. The dose sent is exactly the one reviewed. The phase leaves the review
    /// before the first suspension, so the review sheet can't be read as cancelled meanwhile.
    public func deliver() async {
        guard case .review(let dose) = phase else { return }
        phase = .delivering
        let result = await model.deliver(dose)
        phase = .done(result)
        if case .started = result { reset() }
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
        case .doseChanged(let mgdl, let new, let entered):
            let reading = mgdl.map { " for \(model.settings.glucoseUnit.format(mgdl: $0)) mg/dL" } ?? ""
            return (
                "Dose changed",
                "The pump's latest readings make the calculator's dose \(formatUnits(new))\(reading). You entered \(formatUnits(entered)).",
                [(.useNewDose, "Use \(formatUnits(new))"), (.keepEnteredDose, "Keep \(formatUnits(entered))")]
            )
        }
    }

    /// The notices for a dose, most important first. They never change the dose.
    public static func notices(_ dose: ComposedDose) -> [String] {
        func rank(_ n: DoseNotice) -> Int {
            switch n {
            case .moreThanReservoir: return 0
            case .stacking: return 1
            case .atPumpMax: return 2
            case .differsFromCalculator: return 3
            case .cartridgeStateUnknown: return 4
            }
        }
        return dose.notices.sorted { rank($0) < rank($1) }.compactMap(text(for:))
    }

    static func text(for notice: DoseNotice) -> String? {
        switch notice {
        case .cartridgeStateUnknown:
            return "The cartridge state wasn't read. If no cartridge is loaded, the pump refuses the bolus."
        case .stacking(let d), .atPumpMax(let d), .moreThanReservoir(let d):
            return [d.message, d.detail].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        case .differsFromCalculator(let delivered, let suggested):
            return "This is \(formatUnits(delivered)); the calculator suggests \(formatUnits(suggested))."
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
