import Foundation

/// A dose the user confirmed on the phone's bolus screen, with their answers to any prompts so far.
public struct PhoneDoseEntry: Sendable, Equatable {
    /// The glucose a calculator dose corrects from.
    public enum Glucose: Sendable, Equatable {
        /// No correction.
        case none
        /// A value the user typed.
        case typed(mgdl: Int)
        /// The current CGM reading. `shownMgdl` is the reading the screen computed from, or `nil` when
        /// it had none.
        case currentReading(shownMgdl: Int?)
    }

    public enum Amount: Sendable, Equatable {
        /// Units the user dialed. Delivered as entered.
        case units(Double)
        /// The food entry (zero for a correction only) through the calculator: carbs, or insulin units
        /// with carbs off on the pump. `recommendedUnits` is what the screen suggested; `enteredUnits` is
        /// what the user confirmed, which they may have changed.
        case calculator(food: CalculatorFood, glucose: Glucose, recommendedUnits: Double, enteredUnits: Double)

        public static func calculator(
            carbsGrams: Double, glucose: Glucose, recommendedUnits: Double, enteredUnits: Double
        ) -> Amount {
            .calculator(
                food: .carbs(grams: carbsGrams), glucose: glucose, recommendedUnits: recommendedUnits,
                enteredUnits: enteredUnits)
        }
    }

    /// A fresh ID for this attempt.
    public var id: String
    public var amount: Amount
    public var answers: PhoneDoseAnswers

    public init(id: String, amount: Amount, answers: PhoneDoseAnswers = .init()) {
        self.id = id
        self.amount = amount
        self.answers = answers
    }
}

/// The user's answers to the prompts of one attempt. Each names the dose it showed and what it was about,
/// so an answer to a situation that has since changed is asked again rather than applied. A dose delivered
/// from an answer is always exactly the dose the user saw.
public struct PhoneDoseAnswers: Sendable, Equatable {
    /// Use the last-known calculator inputs for the entered dose: `kind` covers which were unverified, and
    /// `units` is the dose the prompt showed.
    public struct CalculatorOverride: Sendable, Equatable {
        public var kind: CalcInputGate.Kind
        public var units: Double
        public init(kind: CalcInputGate.Kind, units: Double) {
            self.kind = kind
            self.units = units
        }

        func covers(_ needed: CalcInputGate.Kind) -> Bool { kind == needed || kind == .both }
    }

    public enum StaleGlucose: Sendable, Equatable {
        /// Correct from this stale reading, at the prompt's `includeUnits`.
        case include(mgdl: Int, measuredAt: Date, units: Double)
        /// No correction, at the prompt's `carbsOnlyUnits`.
        case carbsOnly(units: Double)
    }

    public enum DoseChanged: Sendable, Equatable {
        /// Deliver the calculator's new dose.
        case useNew(mgdl: Int?, units: Double)
        /// Deliver what was entered anyway.
        case keepEntered(mgdl: Int?, enteredUnits: Double, newUnits: Double)
    }

    public var calculatorOverride: CalculatorOverride?
    public var staleGlucose: StaleGlucose?
    public var doseChanged: DoseChanged?
    /// A confirmation the user went on from: what it said and the dose it showed. One whose figures have
    /// moved since (less insulin left, a larger last-hour total) is asked again.
    public struct Confirmed: Sendable, Equatable {
        public var confirmation: DoseConfirmation
        public var units: Double
        public init(_ confirmation: DoseConfirmation, units: Double) {
            self.confirmation = confirmation
            self.units = units
        }
    }

    /// The confirmations the user went on from, by kind.
    public var confirmed: [DoseConfirmation.Kind: Confirmed]

    /// Whether to correct from `mgdl`, at the dose the prompt showed for that choice.
    public struct Correction: Sendable, Equatable {
        public var mgdl: Int
        public var apply: Bool
        public var units: Double
        public init(mgdl: Int, apply: Bool, units: Double) {
            self.mgdl = mgdl
            self.apply = apply
            self.units = units
        }
    }

    public var correction: Correction?

    public init(
        calculatorOverride: CalculatorOverride? = nil, staleGlucose: StaleGlucose? = nil,
        doseChanged: DoseChanged? = nil, confirmed: [DoseConfirmation.Kind: Confirmed] = [:],
        correction: Correction? = nil
    ) {
        self.calculatorOverride = calculatorOverride
        self.staleGlucose = staleGlucose
        self.doseChanged = doseChanged
        self.confirmed = confirmed
        self.correction = correction
    }
}

/// A question the phone asks before it delivers. Cancelling any of them sends nothing.
public enum PhoneDosePrompt: Sendable, Equatable {
    /// The calculator inputs weren't read fresh for this attempt. Deliver `units`, the entered dose, from
    /// the last-known inputs, or cancel. The answer is `CalculatorOverride(kind:units:)`; the warning copy
    /// is `StaleIobPrompt` / `StaleTherapyPrompt`.
    case calculatorInputs(kind: CalcInputGate.Kind, units: Double, inputs: CalculatorInputs)
    /// There's no fresh CGM reading. Offer to include `reading` when `includeUnits` isn't `nil` (it's stale
    /// but no older than the includable limit), carbs only, or cancel.
    case staleGlucose(reading: Observed<PumpGlucose>?, includeUnits: Double?, carbsOnlyUnits: Double)
    /// The pump says its CGM reading can't correct this dose by itself. Offer carbs only, or cancel (to
    /// type a BG).
    case pumpGlucoseCaution(PumpGlucoseCaution, carbsOnlyUnits: Double)
    /// The calculator's dose for `mgdl` now differs from the one the screen showed: the reading moved, or
    /// the pump's inputs did. Offer the new dose, the entered one, or cancel.
    case doseChanged(mgdl: Int?, newUnits: Double, enteredUnits: Double)
    /// Something about the pump to confirm before `units` goes. Go on, or cancel.
    case confirmation(DoseConfirmation, units: Double)
    /// Correct from `mgdl`, above `targetMgdl` (add) or below it (reduce), for `applyUnits`, or bolus for the
    /// carbs only, `declineUnits`. Asked from 70 mg/dL up when the correction changes the dose.
    case correction(mgdl: Int, targetMgdl: Int, applyUnits: Double, declineUnits: Double)
}

public enum PhoneDoseDecision: Sendable, Equatable {
    case deliver(ComposedDose)
    /// Ask the user, then compose again with their answer added.
    case confirm(PhoneDosePrompt)
    case refused(DoseRefusal)
}

extension DoseComposer {
    /// Compose the phone's dose: the calculator-input gate, a fresh CGM reading for a CGM correction,
    /// the stale-glucose prompt, the pump's bounds, and the notices (stacking among them), which never
    /// change the dose.
    public static func composePhone(_ entry: PhoneDoseEntry, context: DoseContext) -> PhoneDoseDecision {
        if let refusal = availability(surface: .phoneUI, context: context) { return .refused(refusal) }
        switch entry.amount {
        case .units(let units):
            guard units.isFinite, units >= 0 else { return .refused(.invalidAmount) }
            return finishPhone(entry, units: units, calculator: nil, context: context)
        case .calculator(let food, let glucose, let recommended, let entered):
            guard food.amount.isFinite, food.amount >= 0, recommended.isFinite, entered.isFinite, entered >= 0
            else {
                return .refused(.invalidAmount)
            }
            // Nothing confirmed means nothing to ask about: no prompt may turn it into a dose.
            guard entered > 0 else { return .refused(.nothingToDeliver) }
            return composeCalculator(
                entry, food: food, glucose: glucose, recommended: recommended, entered: entered, context: context)
        }
    }

    /// What a calculator dose was built from, for the ledger and the notices.
    private struct CalculatorBasis {
        let food: CalculatorFood
        /// The calculator's number for the basis delivered: the screen's recommendation for the entered
        /// dose, or the recompute an answered prompt chose.
        let suggested: Double
        let inputs: CalculatorInputs
        let correction: Int?
        let usedStale: Bool
    }

    private static func composeCalculator(
        _ entry: PhoneDoseEntry, food: CalculatorFood, glucose: PhoneDoseEntry.Glucose, recommended: Double,
        entered: Double, context: DoseContext
    ) -> PhoneDoseDecision {
        // A typed glucose outside 20–600 is refused: the calculator drops it, so a typed 15 would size a
        // dose with no low correction at all.
        if case .typed(let mgdl) = glucose, !CalculatorGlucose.isValid(mgdl: mgdl) {
            return .refused(.invalidGlucose(mgdl: mgdl))
        }
        let inputs = CalculatorInputs(context: context)
        guard inputs.isAvailable else { return .refused(.pumpSettingsNotRead) }
        // Carbs turned on or off on the pump since the screen sized the dose: its entry means something else
        // now (grams or units), so it's entered again, never converted.
        if inputs.takes(food) == false {
            return .refused(.carbEntryChanged(carbsOff: inputs.settings?.value.carbsOff == true))
        }

        func units(_ mgdl: Int?) -> Double? { inputs.units(food, glucoseMgdl: mgdl) }
        // The glucose the screen computed the entered dose from.
        let screenGlucose: Int? =
            switch glucose {
            case .none: nil
            case .typed(let mgdl): mgdl
            case .currentReading(let shown): shown
            }
        func finish(_ delivered: Double, suggested: Double, correction: Int?, usedStale: Bool = false)
            -> PhoneDoseDecision
        {
            let basis = CalculatorBasis(
                food: food, suggested: suggested, inputs: inputs, correction: correction, usedStale: usedStale)
            return finishPhone(entry, units: delivered, calculator: basis, context: context)
        }

        // Inputs not read fresh for this attempt need the user's say-so for the dose they entered. The
        // answer names that dose, so changing it asks again. It authorizes the inputs only: the checks
        // below still run.
        if !inputs.isVerified {
            switch CalcInputGate.decide(
                isCarbsMode: true, inputsVerified: false, iobStale: !inputs.insulinOnBoardVerified,
                therapyStale: !inputs.settingsVerified, therapyAvailable: true, overrideAccepted: false)
            {
            case .proceed: break
            case .blockNoTherapy: return .refused(.pumpSettingsNotRead)
            case .prompt(let kind):
                let accepted = entry.answers.calculatorOverride
                if accepted?.covers(kind) != true || accepted?.units != entered {
                    guard units(screenGlucose) != nil else { return .refused(.pumpSettingsUnusable) }
                    return .confirm(.calculatorInputs(kind: kind, units: entered, inputs: inputs))
                }
            }
        }

        /// Whether to correct from `mgdl`, as Tandem's apps ask: from 70 mg/dL up, when correcting changes the
        /// dose to another dose and the user hasn't entered one of their own. Under 70 the reduction always applies. `nil`
        /// when there's nothing to ask; otherwise the question, or the dose the user chose. The question shows
        /// both doses from the reading and inputs now, so the answer is the dose that goes: there's no second
        /// question about a dose that moved since the screen. To send the old one, the user cancels and enters
        /// it as their own.
        func correctionChoice(_ mgdl: Int) -> PhoneDoseDecision? {
            guard mgdl >= CalculatorMessage.lowGlucoseMgdl, !differs(entered, recommended),
                let target = inputs.settings?.value.targetMgdl, let with = units(mgdl), let without = units(nil),
                abs(with - without) > mismatchSlack,
                // Both answers must be a dose: with no carbs, or a reduction to nothing, there's no choice.
                with > 0, without > 0
            else { return nil }
            switch entry.answers.correction {
            case let answer? where answer.mgdl == mgdl && answer.apply && answer.units == with:
                return finish(with, suggested: with, correction: mgdl)
            case let answer? where answer.mgdl == mgdl && !answer.apply && answer.units == without:
                return finish(without, suggested: without, correction: nil)
            default:
                return .confirm(.correction(mgdl: mgdl, targetMgdl: target, applyUnits: with, declineUnits: without))
            }
        }

        /// The entered dose, unless the calculator's dose for `mgdl` has moved from what the screen showed:
        /// then the user chooses. `mustAsk` asks even when it hasn't moved past the limit.
        func checkRecompute(mgdl: Int?, recorded: Int?, mustAsk: Bool) -> PhoneDoseDecision {
            guard let new = units(mgdl) else { return .refused(.pumpSettingsUnusable) }
            switch entry.answers.doseChanged {
            case .useNew(let answered, let shown) where answered == mgdl && shown == new:
                return finish(new, suggested: new, correction: mgdl)
            case .keepEntered(let answered, let shownEntered, let shownNew)
            where answered == mgdl && shownEntered == entered && shownNew == new:
                return finish(entered, suggested: recommended, correction: recorded)
            default:
                break
            }
            if mustAsk || differs(new, recommended) {
                return .confirm(.doseChanged(mgdl: mgdl, newUnits: new, enteredUnits: entered))
            }
            return finish(entered, suggested: recommended, correction: recorded)
        }

        switch glucose {
        case .none, .typed:
            if case .typed(let mgdl) = glucose, let choice = correctionChoice(mgdl) { return choice }
            // A card chosen for a question that's gone is asked about, never sent as entered.
            return checkRecompute(
                mgdl: screenGlucose, recorded: screenGlucose, mustAsk: entry.answers.correction != nil)

        case .currentReading(let shownMgdl):
            if let reading = glucoseForCorrection(context) {
                // A reading outside the calculator's range gives no dose, as a typed one doesn't.
                guard CalculatorGlucose.isValid(mgdl: reading.mgdl) else {
                    return .refused(.invalidGlucose(mgdl: reading.mgdl))
                }
                if let choice = correctionChoice(reading.mgdl) { return choice }
                // Also ask when the reading itself changed and moved the dose at all, or when the user last
                // answered a stale-glucose prompt that no longer holds.
                let moved = units(reading.mgdl).map { abs($0 - recommended) > mismatchSlack } ?? false
                // And when a card was chosen for a question that's gone: its dose answered that question.
                let mustAsk =
                    (shownMgdl != reading.mgdl && moved) || entry.answers.staleGlucose != nil
                    || entry.answers.correction != nil
                // The entered dose is recorded with the reading it came from, if that one was usable.
                let shown = shownMgdl.flatMap { CalculatorGlucose.isValid(mgdl: $0) ? $0 : nil }
                return checkRecompute(mgdl: reading.mgdl, recorded: shown, mustAsk: mustAsk)
            }

            guard let carbsOnly = units(nil) else { return .refused(.pumpSettingsUnusable) }
            // The pump says its reading can't correct the dose: carbs only, or cancel and type a BG.
            if let caution = glucoseCaution(context) {
                if case .carbsOnly(let shown) = entry.answers.staleGlucose, shown == carbsOnly {
                    return finish(shown, suggested: shown, correction: nil)
                }
                // The screen showed no reading (it said why, and carbs only): nothing to ask, as for a stale
                // one. A reading the screen corrected from that the pump now flags is still asked about.
                if shownMgdl == nil {
                    return checkRecompute(mgdl: nil, recorded: nil, mustAsk: entry.answers.correction != nil)
                }
                return .confirm(.pumpGlucoseCaution(caution, carbsOnlyUnits: carbsOnly))
            }
            let includable = includableStaleReading(context)
            let includeUnits = includable.flatMap { units($0.value.mgdl) }
            switch entry.answers.staleGlucose {
            case .include(let mgdl, let measuredAt, let shown)
            where mgdl == includable?.value.mgdl && measuredAt == includable?.measuredAt && shown == includeUnits:
                return finish(shown, suggested: shown, correction: mgdl, usedStale: true)
            case .carbsOnly(let shown) where shown == carbsOnly:
                return finish(shown, suggested: shown, correction: nil)
            default:
                break
            }
            // Nothing to include (no reading, or one too old or outside 20–600) and the screen showed none:
            // carbs only is all the dose can be, and the screen said so, so there's nothing to ask. The dose
            // goes as entered, asked about only if the calculator's moved. A reading the screen corrected
            // from that went stale since is still asked about: the dose changed under the user.
            if includeUnits == nil, shownMgdl == nil {
                return checkRecompute(mgdl: nil, recorded: nil, mustAsk: entry.answers.correction != nil)
            }
            return .confirm(
                .staleGlucose(reading: context.pump.glucose, includeUnits: includeUnits, carbsOnlyUnits: carbsOnly))
        }
    }

    private static func finishPhone(
        _ entry: PhoneDoseEntry, units: Double, calculator: CalculatorBasis?, context: DoseContext
    ) -> PhoneDoseDecision {
        if let refusal = bounds(units, context: context) { return .refused(refusal) }
        // Asked once the dose is final, so an answer names the dose that goes.
        if let unconfirmed = confirmations(units: units, context: context).first(where: {
            entry.answers.confirmed[$0.kind] != .init($0, units: units)
        }) {
            return .confirm(.confirmation(unconfirmed, units: units))
        }
        var notices = pumpNotices(units: units, context: context)
        let correction = calculator?.correction
        if let calculator, let settings = calculator.inputs.settings?.value {
            let stacking = StackingGuard.escalation(
                enteredUnits: units, recommendedUnits: calculator.suggested, displaysNumericDose: true,
                pumpIOBUnits: calculator.inputs.calculatorInsulinOnBoardUnits ?? 0,
                glucoseMgdl: correction
                    ?? context.pump.glucoseIfFresh(thresholds: context.freshness, now: context.now)?.mgdl,
                targetMgdl: settings.targetMgdl, maxBolusUnits: context.pumpMaxBolusUnits ?? 0)
            if stacking.friction != .none { notices.append(.stacking(stacking)) }
            if calculator.food.amount > 0, calculator.suggested > 0, differs(units, calculator.suggested) {
                notices.append(.differsFromCalculator(deliveredUnits: units, suggestedUnits: calculator.suggested))
            }
            // Why the calculator's dose is what it is. Of a dose the user entered or kept instead, only that the
            // glucose is low: eat carbs and re-test holds whatever the dose, "reduced" doesn't.
            if let result = calculator.inputs.calculate(calculator.food, glucoseMgdl: correction),
                let message = CalculatorMessage.of(
                    result, food: calculator.food, glucoseMgdl: correction, targetMgdl: settings.targetMgdl,
                    isfMgdlPerUnit: settings.correctionFactor,
                    iobUnits: calculator.inputs.calculatorInsulinOnBoardUnits ?? 0)
            {
                if !differs(units, calculator.suggested) {
                    notices.append(.calculator(message))
                } else if case .lowGlucose = message {
                    notices.append(.calculator(.lowGlucose(.noCarbs)))
                }
            }
        }
        let request = DoseRequest(
            id: entry.id, origin: .phone, shape: .now(units: units),
            // With carbs off no carb amount goes with the bolus, as in Tandem's apps.
            carbsGrams: calculator.flatMap { $0.food.isInsulin ? nil : $0.food.carbsGrams }, bgMgdl: correction,
            foodInsulinUnits: calculator.flatMap { $0.food.isInsulin ? $0.food.amount : nil })
        let carbUnits = calculator.flatMap {
            $0.inputs.carbPart(of: units, food: $0.food, glucoseMgdl: correction)
        }
        // The carbs' share, for the review's split, only when the dose is the calculator's own: the dose less
        // the calculator's correction, so the shares add up to the dose with the rounding down in the food's.
        let foodUnits = calculator.flatMap { c in
            carbUnits.flatMap { _ in
                c.inputs.calculate(c.food, glucoseMgdl: correction).map { r in
                    max(0, units - (r.totalUnits - r.fromCarbs))
                }
            }
        }
        return .deliver(
            ComposedDose(
                request: request, calculatorIOBUnits: calculator?.inputs.calculatorInsulinOnBoardUnits,
                correctionGlucoseMgdl: correction,
                calculatorCarbUnits: carbUnits,
                usedIncludedStaleGlucose: calculator?.usedStale ?? false,
                notices: notices, calculatorFoodUnits: foodUnits))
    }
}
