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
        /// Carbs (zero for a correction only) through the calculator. `recommendedUnits` is what the
        /// screen suggested; `enteredUnits` is what the user confirmed, which they may have changed.
        case calculator(carbsGrams: Double, glucose: Glucose, recommendedUnits: Double, enteredUnits: Double)
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

/// The user's answers to the prompts of one attempt. Each names the dose it showed and the reading it was
/// about, so an answer to a situation that has since changed is asked again instead of applied, and an
/// answered dose is never more than the dose the user saw.
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
        /// Correct from this stale reading.
        case include(mgdl: Int, measuredAt: Date, units: Double)
        /// No correction.
        case carbsOnly(units: Double)
    }

    public enum GlucoseChanged: Sendable, Equatable {
        /// Use the new reading's dose.
        case useNew(mgdl: Int, units: Double)
        /// Deliver what was entered anyway.
        case keepEntered(mgdl: Int)
    }

    public var calculatorOverride: CalculatorOverride?
    public var staleGlucose: StaleGlucose?
    public var glucoseChanged: GlucoseChanged?

    public init(
        calculatorOverride: CalculatorOverride? = nil, staleGlucose: StaleGlucose? = nil,
        glucoseChanged: GlucoseChanged? = nil
    ) {
        self.calculatorOverride = calculatorOverride
        self.staleGlucose = staleGlucose
        self.glucoseChanged = glucoseChanged
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
    /// The reading moved since the screen computed the dose, and the dose moved with it.
    case glucoseChanged(mgdl: Int, newUnits: Double, enteredUnits: Double)
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
        case .calculator(let carbs, let glucose, let recommended, let entered):
            guard carbs.isFinite, carbs >= 0, recommended.isFinite, entered.isFinite, entered >= 0 else {
                return .refused(.invalidAmount)
            }
            return composeCalculator(
                entry, carbs: carbs, glucose: glucose, recommended: recommended, entered: entered, context: context)
        }
    }

    /// What a calculator dose was built from, for the ledger and the notices.
    private struct CalculatorBasis {
        let carbs: Double
        /// The calculator's number for the basis delivered: the screen's recommendation for the entered
        /// dose, or the recompute an answered prompt chose.
        let suggested: Double
        let inputs: CalculatorInputs
        let correction: Int?
        let usedStale: Bool
    }

    private static func composeCalculator(
        _ entry: PhoneDoseEntry, carbs: Double, glucose: PhoneDoseEntry.Glucose, recommended: Double,
        entered: Double, context: DoseContext
    ) -> PhoneDoseDecision {
        // A typed low is refused: the calculator drops an implausible reading, so a typed 30 would size a
        // dose with no low correction at all. A CGM reading is the source's to gate.
        if case .typed(let mgdl) = glucose, !GlucosePlausibility.isPlausible(mgdl: mgdl) {
            return .refused(.implausibleGlucose(mgdl: mgdl))
        }
        let inputs = CalculatorInputs(context: context)
        guard inputs.isAvailable else { return .refused(.pumpSettingsNotRead) }

        func units(_ mgdl: Int?) -> Double? { inputs.units(carbsGrams: carbs, glucoseMgdl: mgdl) }
        func finish(_ delivered: Double, suggested: Double, correction: Int?, usedStale: Bool = false)
            -> PhoneDoseDecision
        {
            let basis = CalculatorBasis(
                carbs: carbs, suggested: suggested, inputs: inputs, correction: correction, usedStale: usedStale)
            return finishPhone(entry, units: delivered, calculator: basis, context: context)
        }

        // Inputs not read fresh for this attempt need the user's say-so for the dose they entered. The
        // answer names that dose, so changing it asks again. It authorizes the inputs only: the glucose
        // checks below still run.
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
                    let screen: Int? =
                        switch glucose {
                        case .none: nil
                        case .typed(let mgdl): mgdl
                        case .currentReading(let shown): shown
                        }
                    guard units(screen) != nil else { return .refused(.pumpSettingsUnusable) }
                    return .confirm(.calculatorInputs(kind: kind, units: entered, inputs: inputs))
                }
            }
        }

        switch glucose {
        case .none, .typed:
            var mgdl: Int?
            if case .typed(let typed) = glucose { mgdl = typed }
            guard units(mgdl) != nil else { return .refused(.pumpSettingsUnusable) }
            return finish(entered, suggested: recommended, correction: mgdl)

        case .currentReading(let shownMgdl):
            if let reading = context.pump.glucoseIfFresh(now: context.now) {
                guard let new = units(reading.mgdl) else { return .refused(.pumpSettingsUnusable) }
                switch entry.answers.glucoseChanged {
                case .useNew(let mgdl, let shown) where mgdl == reading.mgdl:
                    return finish(min(shown, new), suggested: new, correction: reading.mgdl)
                case .keepEntered(let mgdl) where mgdl == reading.mgdl:
                    return finish(entered, suggested: recommended, correction: shownMgdl)
                default:
                    break
                }
                // Ask when the dose moved by more than the limit, when the reading itself changed and moved
                // the dose at all, or when the user last answered a stale-glucose prompt that no longer holds.
                let moved = differs(new, recommended)
                let readingChanged = shownMgdl != reading.mgdl && abs(new - recommended) > mismatchSlack
                if moved || readingChanged || entry.answers.staleGlucose != nil {
                    return .confirm(.glucoseChanged(mgdl: reading.mgdl, newUnits: new, enteredUnits: entered))
                }
                return finish(entered, suggested: recommended, correction: shownMgdl)
            }

            guard let carbsOnly = units(nil) else { return .refused(.pumpSettingsUnusable) }
            let includable = includableStaleReading(context)
            let includeUnits = includable.flatMap { units($0.value.mgdl) }
            switch entry.answers.staleGlucose {
            case .include(let mgdl, let measuredAt, let shown)
            where mgdl == includable?.value.mgdl && measuredAt == includable?.measuredAt:
                if let includeUnits {
                    return finish(min(shown, includeUnits), suggested: includeUnits, correction: mgdl, usedStale: true)
                }
            case .carbsOnly(let shown):
                return finish(min(shown, carbsOnly), suggested: carbsOnly, correction: nil)
            default:
                break
            }
            return .confirm(
                .staleGlucose(reading: context.pump.glucose, includeUnits: includeUnits, carbsOnlyUnits: carbsOnly))
        }
    }

    private static func finishPhone(
        _ entry: PhoneDoseEntry, units: Double, calculator: CalculatorBasis?, context: DoseContext
    ) -> PhoneDoseDecision {
        if let refusal = bounds(units, context: context) { return .refused(refusal) }
        var notices = pumpNotices(units: units, context: context)
        if let calculator, let settings = calculator.inputs.settings?.value {
            let stacking = StackingGuard.escalation(
                enteredUnits: units, recommendedUnits: calculator.suggested, displaysNumericDose: true,
                pumpIOBUnits: calculator.inputs.insulinOnBoard?.value ?? 0,
                glucoseMgdl: calculator.correction ?? context.pump.glucoseIfFresh(now: context.now)?.mgdl,
                targetMgdl: settings.targetMgdl, maxBolusUnits: context.pumpMaxBolusUnits ?? 0)
            if stacking.friction != .none { notices.append(.stacking(stacking)) }
            if calculator.carbs > 0, calculator.suggested > 0, differs(units, calculator.suggested) {
                notices.append(.differsFromCalculator(deliveredUnits: units, suggestedUnits: calculator.suggested))
            }
        }
        let request = DoseRequest(
            id: entry.id, origin: .phone, shape: .now(units: units), carbsGrams: calculator?.carbs,
            bgMgdl: calculator?.correction)
        return .deliver(
            ComposedDose(
                request: request, calculatorIOBUnits: calculator?.inputs.insulinOnBoard?.value,
                correctionGlucoseMgdl: calculator?.correction, usedIncludedStaleGlucose: calculator?.usedStale ?? false,
                notices: notices))
    }
}
