import Foundation

@testable import faBolusCore

/// A connected t:slim with every input read fresh for the attempt: carb ratio 10 g/U, correction factor
/// 40 mg/dL/U, target 110, max 25 U, IOB 0.5 U, CGM 180 mg/dL. 60 g at 180 mg/dL comes to
/// 6.00 + (70 / 40 = 1.75) − 0.50 = 7.25 U.
enum DoseFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// When the attempt asked the pump for fresh inputs.
    static let requestedAt = now.addingTimeInterval(-5)

    static func observed<T>(_ value: T, age: TimeInterval) -> Observed<T> {
        let at = now.addingTimeInterval(-age)
        return Observed(value, measuredAt: at, receivedAt: at)
    }

    static let settings = settings()

    /// The calculator settings, with the IOB the same reply reports (0.5 U, agreeing with the IOB reading).
    static func settings(target: Int = 110, reportedIOB: Double? = 0.5) -> BolusCalculatorSettings {
        BolusCalculatorSettings(
            carbRatio: 10, correctionFactor: 40, targetMgdl: target, maxBolusUnits: 25, insulinOnBoardUnits: reportedIOB
        )
    }

    static func pump(glucose: Int? = 180, glucoseAge: TimeInterval = 60) -> PumpState {
        var pump = PumpState()
        pump.link = .connected
        pump.model = .tslimX2
        pump.bolusCalculator = observed(settings, age: 2)
        pump.insulinOnBoard = observed(0.5, age: 2)
        pump.glucose = glucose.map { observed(PumpGlucose(mgdl: $0, trend: nil), age: glucoseAge) }
        // The pump's CGM state, read for the attempt: no error, so the reading may correct a dose.
        pump.cgmDisplay = observed(PumpCGMDisplay(state: .noError, checkBG: false), age: 2)
        pump.cartridge = observed(CartridgeLoadState(rawValue: 5), age: 2)
        pump.reservoirUnits = observed(150, age: 2)
        return pump
    }

    static let openAccess = AccessPolicy.AccessContext(
        phoneReadOnly: false, remotesReadOnly: false, capabilities: .tslimX2, garminBolusEnabled: true)

    static func context(
        pump: PumpState = pump(), access: AccessPolicy.AccessContext = openAccess, bolusBlock: BolusBlock? = nil,
        lastDeliveryAt: Date? = nil, lastDeliveryPeerId: String? = DoseRequest.Origin.phonePeerId,
        remoteSizeLimitUnits: Double? = nil, freshness: FreshnessThresholds = .standard, now: Date = now
    ) -> DoseContext {
        DoseContext(
            pump: pump, access: access, bolusBlock: bolusBlock, inputsRequestedAt: requestedAt,
            lastDeliveryAt: lastDeliveryAt, lastDeliveryPeerId: lastDeliveryPeerId,
            remoteSizeLimitUnits: remoteSizeLimitUnits, freshness: freshness,
            now: now)
    }

    static func remote(
        _ amount: RemoteDoseRequest.Amount?, glucose: Int? = 180, includeStale: Bool = false,
        sentAt: Date? = now.addingTimeInterval(-3), id: String = "watch-1"
    ) -> RemoteDoseRequest {
        RemoteDoseRequest(
            id: id, peerId: "garmin", surface: .garmin, sentAt: sentAt, amount: amount, glucoseMgdl: glucose,
            includeStaleGlucose: includeStale)
    }

    static func carbs(_ grams: Double, estimate: Double?) -> RemoteDoseRequest.Amount {
        .calculator(carbsGrams: grams, estimateUnits: estimate)
    }

    static func phone(_ amount: PhoneDoseEntry.Amount, answers: PhoneDoseAnswers = .init()) -> PhoneDoseEntry {
        PhoneDoseEntry(id: "phone-1", amount: amount, answers: answers)
    }

    /// A calculator dose through the current CGM reading, which the screen showed as `shown`.
    static func cgmDose(
        carbs: Double = 60, shown: Int? = 180, recommended: Double = 7.25, entered: Double = 7.25
    ) -> PhoneDoseEntry.Amount {
        .calculator(
            carbsGrams: carbs, glucose: .currentReading(shownMgdl: shown), recommendedUnits: recommended,
            enteredUnits: entered)
    }
}

extension RemoteDoseDecision {
    var dose: ComposedDose? {
        if case .deliver(let dose) = self { return dose }
        return nil
    }
    var refusal: DoseRefusal? {
        if case .refused(let refusal) = self { return refusal }
        return nil
    }
}

extension PhoneDoseDecision {
    var dose: ComposedDose? {
        if case .deliver(let dose) = self { return dose }
        return nil
    }
    var refusal: DoseRefusal? {
        if case .refused(let refusal) = self { return refusal }
        return nil
    }
    var prompt: PhoneDosePrompt? {
        if case .confirm(let prompt) = self { return prompt }
        return nil
    }
}

extension DoseComposer {
    /// The phone's dose as a user who answers "add it" to the correction question: for the tests about
    /// everything else a CGM dose above target meets. `CorrectionPromptTests` asks the question itself.
    static func composePhoneCorrecting(_ entry: PhoneDoseEntry, context: DoseContext) -> PhoneDoseDecision {
        var entry = entry
        let decision = composePhone(entry, context: context)
        guard case .confirm(.correction(let mgdl, _, let apply, _)) = decision else { return decision }
        entry.answers.correction = .init(mgdl: mgdl, apply: true, units: apply)
        return composePhone(entry, context: context)
    }
}
