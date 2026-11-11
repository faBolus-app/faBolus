import Foundation

/// Why the calculator's dose is what it is when the glucose lowered it or IOB took the correction away, as
/// Tandem's apps explain it. Text only: the dose doesn't change.
public enum CalculatorMessage: Sendable, Equatable {
    /// Under 70 mg/dL: eat carbs and re-test. `dose` says what the low did to the dose.
    case lowGlucose(LowDose)
    /// From 70 mg/dL up to the target, the correction took the dose to zero; `iob` when the IOB may also
    /// take the glucose low. A reduction that leaves a dose isn't explained, as in Tandem's app.
    case reducedToZero(iob: Bool)
    /// On target with IOB on board, or above it with IOB that may take the glucose under 70: it may drop low.
    case iobMayDropLow
    /// Above target, but IOB is more than the correction, so none was added.
    case iobCoversCorrection

    public enum LowDose: Sendable, Equatable {
        /// No carbs entered: there's nothing to bolus for. Also the plain warning for a dose the user entered,
        /// which says nothing about the dose.
        case noCarbs
        /// The low took the whole dose away.
        case noBolus
        /// The low reduced the dose.
        case reduced
    }

    /// Under this the reduction always applies and the screen says to eat carbs.
    public static let lowGlucoseMgdl = 70

    /// The message for a calculation, as Tandem's app chooses it, or `nil` when there's nothing to say: no
    /// glucose, a correction that only adds, or a reduction that leaves a dose.
    public static func of(
        _ result: BolusMath.Result, carbsGrams: Double, glucoseMgdl: Int?, targetMgdl: Int, isfMgdlPerUnit: Int,
        iobUnits: Double
    ) -> CalculatorMessage? {
        guard let bg = glucoseMgdl, !result.sanityFailed else { return nil }
        let hasIOB = iobUnits > 0
        // The IOB would take the glucose under 70 once it acts.
        let iobMayDropLow = hasIOB && Double(bg) - iobUnits * Double(isfMgdlPerUnit) < Double(lowGlucoseMgdl)
        if bg < lowGlucoseMgdl {
            if carbsGrams <= 0 { return .lowGlucose(.noCarbs) }
            return .lowGlucose(result.totalUnits <= 0 ? .noBolus : .reduced)
        }
        if bg < targetMgdl { return result.totalUnits <= 0 ? .reducedToZero(iob: iobMayDropLow) : nil }
        if bg == targetMgdl { return hasIOB ? .iobMayDropLow : nil }
        guard hasIOB, result.fromBG + result.fromIOB <= 0 else { return nil }
        return iobMayDropLow ? .iobMayDropLow : .iobCoversCorrection
    }

    public var text: String {
        switch self {
        case .lowGlucose(.noCarbs): return "Your glucose is low. Eat carbs and re-test."
        case .lowGlucose(.noBolus): return "Your glucose is low, so no bolus was calculated. Eat carbs and re-test."
        case .lowGlucose(.reduced): return "Your glucose is low, so the bolus was reduced. Eat carbs and re-test."
        case .reducedToZero(let iob):
            let reduced = "Your glucose is below target, so the bolus was reduced to 0 U."
            return iob ? reduced + " With your IOB, your glucose may drop low." : reduced
        case .iobMayDropLow: return "With your IOB, your glucose may drop low. Re-test as needed."
        case .iobCoversCorrection: return "Your IOB covers the correction, so none was added."
        }
    }
}

extension DoseRecommendation {
    /// Why the suggestion is what it is, for the screen. A reduction from 70 mg/dL up that leaves a dose
    /// isn't explained here: the question after Deliver names both doses.
    public var message: CalculatorMessage? {
        guard let calculation, let settings = inputs.settings?.value else { return nil }
        return CalculatorMessage.of(
            calculation, carbsGrams: carbsGrams, glucoseMgdl: glucoseMgdl, targetMgdl: settings.targetMgdl,
            isfMgdlPerUnit: settings.correctionFactor, iobUnits: inputs.calculatorInsulinOnBoardUnits ?? 0)
    }
}
