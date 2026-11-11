import Foundation

/// The one dose path. The phone's bolus screen and every remote reach the pump through it, so each dose
/// check lives here once: the access policy, the pump's link, cartridge and bounds, the optional remote
/// size limit, the calculator inputs, glucose freshness, and the remote-request checks.
///
/// Pure over its inputs: it never reads the pump, a clock or a setting itself. The caller refreshes the
/// calculator inputs and glucose before composing, merges glucose with `GlucoseArbiter`, and passes the
/// result in a `DoseContext`. The composed `DoseRequest` then goes to the ledger, which owns one bolus at a
/// time and the unknown-outcome block, and on to TandemKit's write policy and signed messages.
public enum DoseComposer {
    /// The most a remote's estimate and the phone's recompute may differ, and the most the phone's own
    /// dose may move after the screen computed it, before the user is asked again. Two pump steps: it
    /// catches real drift and ignores rounding.
    public static let mismatchLimitUnits = 0.10

    /// Floating-point slack on `mismatchLimitUnits`, so two doses exactly 0.10 U apart compare equal to
    /// the limit.
    static let mismatchSlack = 1e-9

    static func differs(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) > mismatchLimitUnits + mismatchSlack
    }
}

/// Everything a dose decision is made from, captured by the caller at one moment.
public struct DoseContext: Sendable {
    /// The pump's state, with glucose already merged from any backup source (`GlucoseArbiter.merge`).
    public var pump: PumpState
    public var access: AccessPolicy.AccessContext
    /// Why the ledger won't start a new bolus, if it won't (`DurableBolusLedger`). The ledger refuses
    /// again when the request is recorded; this lets the composer say so before asking the user anything.
    public var bolusBlock: BolusBlock?
    /// When the caller asked the pump for fresh calculator inputs for this attempt. A reading received
    /// before it wasn't read for this attempt, so it doesn't count as verified, even inside its window.
    public var inputsRequestedAt: Date
    /// When the most recent bolus from any surface was sent to the pump, by this phone's clock. A remote
    /// request composed before it was built on the state before that bolus.
    public var lastDeliveryAt: Date?
    /// The user's optional remote bolus size limit, units. Off when `nil`; a value that isn't a positive
    /// number refuses every remote dose. Never applied to the phone.
    public var remoteSizeLimitUnits: Double?
    /// The windows glucose and the calculator inputs are judged on: the same ones the pump session uses
    /// to decide what it shows, so the screen and the dose can't disagree.
    public var freshness: FreshnessThresholds
    public var now: Date

    public init(
        pump: PumpState, access: AccessPolicy.AccessContext, bolusBlock: BolusBlock?,
        inputsRequestedAt: Date, lastDeliveryAt: Date?, remoteSizeLimitUnits: Double?,
        freshness: FreshnessThresholds, now: Date
    ) {
        self.pump = pump
        self.access = access
        self.bolusBlock = bolusBlock
        self.inputsRequestedAt = inputsRequestedAt
        self.lastDeliveryAt = lastDeliveryAt
        self.remoteSizeLimitUnits = remoteSizeLimitUnits
        self.freshness = freshness
        self.now = now
    }

    /// The pump's max bolus when it has been read, else `nil`, and the pump enforces it. The last
    /// reading is used whatever its age: the max changes only when the user edits it on the pump.
    public var pumpMaxBolusUnits: Double? {
        guard let max = pump.bolusCalculator?.value.maxBolusUnits, max.isFinite, max > 0 else { return nil }
        return max
    }
}

/// The pump's calculator inputs as the dose path sees them: the last usable readings, and whether each
/// was read fresh for this attempt.
public struct CalculatorInputs: Sendable, Equatable {
    /// The last usable calculator settings, or `nil` when the pump hasn't reported any.
    public var settings: Observed<BolusCalculatorSettings>?
    /// The last IOB reading, or `nil` when there is none.
    public var insulinOnBoard: Observed<Double>?
    /// The settings were received for this attempt and are inside their window.
    public var settingsVerified: Bool
    /// The IOB was received for this attempt, is inside its window, and agrees with the calculator
    /// reply's own IOB. Without that IOB to compare against, it isn't verified.
    public var insulinOnBoardVerified: Bool
    /// The IOB reading and the calculator reply's own IOB differ by more than one pump step. Right after
    /// a bolus the IOB reading can still be low, so neither is trusted: IOB isn't verified, and a dose is
    /// sized from the larger of the two, which never subtracts less insulin than either implies.
    public var insulinOnBoardReadingsDisagree: Bool

    /// One pump step: two IOB readings closer than this agree.
    static let insulinOnBoardAgreementUnits = BolusVolume.stepUnits

    /// The IOB the calculator subtracts, and the one a dose carries to the pump: the reading, or the
    /// larger of the two when they disagree. `nil` when there is no IOB reading.
    public var calculatorInsulinOnBoardUnits: Double? {
        guard let reading = insulinOnBoard?.value else { return nil }
        guard insulinOnBoardReadingsDisagree, let reported = settings?.value.insulinOnBoardUnits else {
            return reading
        }
        return max(reading, reported)
    }

    public var isVerified: Bool { settingsVerified && insulinOnBoardVerified }
    /// Both inputs have been read at some point, so a dose can be sized from real pump values.
    public var isAvailable: Bool { settings != nil && insulinOnBoard != nil }

    public init(context: DoseContext) {
        let pump = context.pump
        settings = pump.bolusCalculator.flatMap { $0.value.isUsable ? $0 : nil }
        insulinOnBoard = pump.insulinOnBoard.flatMap { $0.value.isFinite ? $0 : nil }
        if let reading = insulinOnBoard?.value, let reported = settings?.value.insulinOnBoardUnits,
            reported.isFinite
        {
            insulinOnBoardReadingsDisagree =
                abs(reading - reported) > Self.insulinOnBoardAgreementUnits + DoseComposer.mismatchSlack
        } else {
            insulinOnBoardReadingsDisagree = false
        }
        settingsVerified =
            settings.map {
                Self.readForAttempt($0, window: context.freshness.therapyStaleAfter, context: context)
            } ?? false
        let crossChecked = settings?.value.insulinOnBoardUnits?.isFinite == true
        insulinOnBoardVerified =
            crossChecked && !insulinOnBoardReadingsDisagree
            && (insulinOnBoard.map {
                Self.readForAttempt($0, window: context.freshness.insulinOnBoardStaleAfter, context: context)
            } ?? false)
    }

    private static func readForAttempt<T>(_ reading: Observed<T>, window: TimeInterval, context: DoseContext)
        -> Bool
    {
        reading.receivedAt >= context.inputsRequestedAt && !reading.isStale(after: window, now: context.now)
    }

    /// The pump calculator's result for these inputs, or `nil` when either input has never been read.
    func calculate(carbsGrams: Double, glucoseMgdl: Int?) -> BolusMath.Result? {
        guard let settings = settings?.value, let iob = calculatorInsulinOnBoardUnits else { return nil }
        let profile = BolusMath.Profile(
            carbRatioGramsPerUnit: settings.carbRatio, isfMgdlPerUnit: settings.correctionFactor,
            targetBgMgdl: settings.targetMgdl, iobUnits: iob)
        return BolusMath.estimate(
            carbsGrams: carbsGrams > 0 ? carbsGrams : nil, bgMgdl: glucoseMgdl, profile: profile)
    }

    /// The carb part of the calculation for these inputs, capped at `units`, when that calculation rounded
    /// down to the pump's step is exactly `units`. Otherwise the dose isn't the calculator's, and there's
    /// no part.
    func carbPart(of units: Double, carbsGrams: Double, glucoseMgdl: Int?) -> Double? {
        guard carbsGrams > 0, let result = calculate(carbsGrams: carbsGrams, glucoseMgdl: glucoseMgdl),
            !result.sanityFailed,
            abs(BolusVolume.roundedDown(result.totalUnits) - units) <= DoseComposer.mismatchSlack
        else { return nil }
        return min(result.fromCarbs, units)
    }

    /// The calculated dose rounded down to the pump's step, or `nil` when it can't be sized.
    func units(carbsGrams: Double, glucoseMgdl: Int?) -> Double? {
        guard let result = calculate(carbsGrams: carbsGrams, glucoseMgdl: glucoseMgdl), !result.sanityFailed
        else { return nil }
        return BolusVolume.roundedDown(result.totalUnits)
    }
}

/// What the bolus screen shows while the user enters carbs and glucose.
public struct DoseRecommendation: Sendable, Equatable {
    /// Rounded down to the pump's step. Zero when no dose can be sized.
    public var units: Double
    /// The pump calculator's breakdown, or `nil` when the calculator inputs have never been read.
    public var calculation: BolusMath.Result?
    public var inputs: CalculatorInputs
    /// The glucose the recommendation was asked for.
    public var glucoseMgdl: Int?

    /// A number may be shown only when it comes from real pump readings. Before the pump has reported its
    /// settings and IOB there is nothing to size a dose from, so the screen waits instead.
    public var displaysNumericDose: Bool { calculation.map { !$0.sanityFailed } ?? false }

    /// The calculator ignores a glucose outside 40–400 mg/dL, so the number above has no correction for
    /// it. A typed one is refused at delivery (`DoseRefusal.implausibleGlucose`); the screen says so rather
    /// than present the number as a correction.
    public var glucoseIsPlausible: Bool { glucoseMgdl.map { GlucosePlausibility.isPlausible(mgdl: $0) } ?? true }
}

extension DoseComposer {
    /// The recommendation for the bolus screen, from the last-known inputs whether or not they are
    /// verified. `inputs` says which are verified; delivery asks again when they aren't.
    public static func recommend(carbsGrams: Double, glucoseMgdl: Int?, context: DoseContext) -> DoseRecommendation {
        let inputs = CalculatorInputs(context: context)
        let carbs = carbsGrams.isFinite ? max(0, carbsGrams) : 0
        let calculation = inputs.calculate(carbsGrams: carbs, glucoseMgdl: glucoseMgdl)
        let units = calculation.map { $0.sanityFailed ? 0 : BolusVolume.roundedDown($0.totalUnits) } ?? 0
        return DoseRecommendation(units: units, calculation: calculation, inputs: inputs, glucoseMgdl: glucoseMgdl)
    }
}

/// A dose ready for the ledger. Its amount and inputs are fixed: the number checked is the number sent.
public struct ComposedDose: Sendable, Equatable {
    /// For the ledger. A remote request keeps the carbs and glucose the remote sent, so a resent message
    /// is recognized as the same request even after the phone's own inputs have moved.
    public let request: DoseRequest
    /// The IOB the calculator subtracted, which a carb bolus carries to the pump with its carbs. `nil` for a
    /// dose entered in units.
    public let calculatorIOBUnits: Double?
    /// The glucose the phone's calculation corrected from, recorded with the bolus. `nil` when the dose
    /// has no correction.
    public let correctionGlucoseMgdl: Int?
    /// The part of the dose that covers the carbs, when the dose is exactly the calculator's own; never
    /// more than the dose, because below target a negative correction takes the dose under the carbs'
    /// share. The pump is told how much was for food and how much was a correction, as Tandem's app tells
    /// it. `nil` for a dose entered in units or changed from the calculator's, which is sent as all food.
    public let calculatorCarbUnits: Double?
    /// The correction used a stale reading the user chose to include.
    public let usedIncludedStaleGlucose: Bool
    public let notices: [DoseNotice]

    public var units: Double { request.totalUnits }
}

/// Something the user should see before delivering. A notice never changes or blocks the dose.
public enum DoseNotice: Sendable, Equatable {
    /// The cartridge state wasn't read. The bolus is allowed; the pump refuses without a cartridge.
    case cartridgeStateUnknown
    /// More than the pump's calculator suggested while glucose is above target (`StackingGuard`).
    case stacking(StackingGuard.Disclosure)
    /// At the pump's own max bolus.
    case atPumpMax(StackingGuard.Disclosure)
    /// A carb dose more than 0.10 U from the calculator's suggestion. The carbs are still recorded.
    case differsFromCalculator(deliveredUnits: Double, suggestedUnits: Double)
}

/// Why a dose was refused. Nothing was recorded or sent.
public enum DoseRefusal: Sendable, Equatable {
    /// Access, the pump link, a bolus in flight, the cartridge, or the pump's own bounds.
    case unavailable(BolusBlockReason)
    /// The ledger won't start a new bolus: an unknown outcome or a storage problem.
    case blocked(BolusBlock)
    /// A remote request without a send time, or older than the freshness limit.
    case requestTooOld
    /// A remote request composed before the last bolus was sent.
    case supersededByDelivery
    /// The same remote's same dose was delivered moments ago under another request ID: most likely a
    /// resend after the remote missed the outcome.
    case recentlyDelivered
    /// A remote request that names the phone's own surface or peer.
    case notARemote
    /// A remote request named neither units nor carbs, or asked for an extended bolus, which no model
    /// offers.
    case noDoseSpecified
    /// An amount, carb count or estimate that isn't a usable number.
    case invalidAmount
    /// A remote request ID already recorded for a different dose.
    case requestIdReused
    /// A remote carb request without the remote's own estimate, so the mismatch check can't run.
    case missingEstimate
    /// The pump hasn't reported its calculator settings or IOB, so no dose can be sized.
    case pumpSettingsNotRead
    /// A remote carb request whose calculator inputs weren't read fresh for this attempt.
    case pumpSettingsNotVerified
    /// The pump's calculator rejects its own settings (a target outside 40–400 mg/dL).
    case pumpSettingsUnusable
    /// The phone's recompute differs from the remote's estimate by more than 0.10 U.
    case doseChanged(estimateUnits: Double, doseUnits: Double)
    /// A glucose outside 40–400 mg/dL, typed or from the CGM (its LOW and HIGH). The pump's own calculator
    /// gives no dose for one, so a calculated dose is refused rather than sized without it.
    case implausibleGlucose(mgdl: Int)
    /// The dose comes to zero.
    case nothingToDeliver
    /// Above the user's remote bolus size limit.
    case aboveRemoteLimit(Double)
    /// This remote request was refused before (the ledger's `RemoteRefusal`); the same answer again.
    case refusedBefore(String)
    /// A remote dose of `units` that needs these confirmations, not all of which the request carried. The
    /// remote asks the user and sends a new request with them.
    case needsConfirmation([DoseConfirmation], units: Double)

    /// What a remote may confirm to send the dose again: none but for `needsConfirmation`.
    public var confirmationKinds: [DoseConfirmation.Kind] {
        guard case .needsConfirmation(let needed, _) = self else { return [] }
        return needed.map(\.kind)
    }

    public var userMessage: String {
        switch self {
        case .unavailable(let reason): return reason.userMessage
        case .blocked(let block): return block.userMessage
        case .requestTooOld: return RemoteRequestFreshness.rejectionMessage
        case .supersededByDelivery:
            return "A bolus was delivered after this request was created — reopen the remote and try again."
        case .recentlyDelivered:
            return "A matching bolus was just delivered — if you meant to dose again, wait a moment and resend."
        case .notARemote: return "This request didn't come from a paired remote."
        case .noDoseSpecified: return "No dose this pump can take was specified."
        case .invalidAmount: return "That amount isn't a number the pump can take."
        case .requestIdReused: return "This request doesn't match the one already received — send it again."
        case .missingEstimate: return "Missing dose estimate — reopen the remote and try again."
        case .pumpSettingsNotRead:
            return "faBolus hasn't read this pump's bolus settings and active insulin yet, so it can't size a "
                + "dose. Wait a moment for the pump to connect, then try again."
        case .pumpSettingsNotVerified:
            return "Pump settings not verified yet — open faBolus on the phone to confirm this dose."
        case .pumpSettingsUnusable:
            return "The pump's bolus calculator can't use its current settings. Check the target on the pump."
        case .doseChanged(let estimate, let dose):
            return String(
                format: "Dose changed since your estimate (%.2f U → %.2f U). Reopen and confirm.", estimate, dose)
        case .implausibleGlucose:
            return "That glucose reading looks out of range — re-check your glucose before dosing."
        case .nothingToDeliver: return "No insulin needed."
        case .aboveRemoteLimit(let limit):
            return String(format: "This dose is above your remote limit of %.2f U — lower it and try again.", limit)
        case .refusedBefore(let reason): return reason
        case .needsConfirmation(let needed, _):
            // A remote's screen is small: each in a few words. The remote's button names the dose.
            return needed.map(\.shortMessage).joined(separator: " ")
        }
    }
}

extension DoseComposer {
    /// The checks that come before any dose is sized: access from `surface`, the pump link, the ledger
    /// and the cartridge.
    static func availability(surface: AccessPolicy.Surface, context: DoseContext) -> DoseRefusal? {
        availability(surface: surface, pump: context.pump, access: context.access, bolusBlock: context.bolusBlock)
    }

    /// Whether `surface` may start a bolus now, before any amount: the same checks a dose meets first, so a
    /// remote's button and the composer agree. `nil` when one may be attempted.
    public static func availability(
        surface: AccessPolicy.Surface, pump: PumpState, access context: AccessPolicy.AccessContext,
        bolusBlock: BolusBlock?
    ) -> DoseRefusal? {
        var access = AccessPolicy.evaluate(.deliverBolus, surface: surface, context: context)
        // The model the pump itself was identified as must take a dose too, whatever capabilities the
        // caller put in the access context.
        if access.allowed && !pump.capabilities.canDeliverBolus { access = .deny(.capabilityUnavailable) }
        if let reason = BolusGate.availability(
            reachable: true, linked: pump.link.isConnected, bolusInFlight: bolusBlock == .bolusInProgress,
            cartridgeReady: pump.cartridgeReadiness != .notReady, access: access)
        {
            return .unavailable(reason)
        }
        if let block = bolusBlock { return .blocked(block) }
        return nil
    }

    /// The pump's bounds on a sized dose: its minimum and, when known, its max.
    static func bounds(_ units: Double, context: DoseContext) -> DoseRefusal? {
        guard units.isFinite else { return .invalidAmount }
        guard units > 0 else { return .nothingToDeliver }
        return BolusGate.amountCheck(units, minimum: BolusVolume.minimumUnits, maximum: context.pumpMaxBolusUnits)
            .map { .unavailable($0) }
    }

    /// Notices about the pump that apply to any dose.
    static func pumpNotices(units: Double, context: DoseContext) -> [DoseNotice] {
        var notices: [DoseNotice] = []
        if context.pump.cartridgeReadiness == .unknown { notices.append(.cartridgeStateUnknown) }
        if let max = context.pumpMaxBolusUnits {
            let disclosure = StackingGuard.maxBolusProximity(enteredUnits: units, maxBolusUnits: max)
            if disclosure.friction != .none { notices.append(.atPumpMax(disclosure)) }
        }
        return notices
    }

    /// The current reading when it is stale but may still be included in a correction: no older than
    /// `FreshnessThresholds.maxIncludableGlucoseAge`, inside 40–400 mg/dL, with a time that can be trusted.
    /// `nil` otherwise, including when the reading is fresh.
    /// The pump's caution on its reading for this attempt: its CGM state must have been read for it.
    static func glucoseCaution(_ context: DoseContext) -> PumpGlucoseCaution? {
        context.pump.glucoseCaution(cgmStateReadSince: context.inputsRequestedAt)
    }

    /// The current reading when it may correct this dose by itself.
    static func glucoseForCorrection(_ context: DoseContext) -> PumpGlucose? {
        context.pump.glucoseForCorrection(
            thresholds: context.freshness, now: context.now, cgmStateReadSince: context.inputsRequestedAt)
    }

    static func includableStaleReading(_ context: DoseContext) -> Observed<PumpGlucose>? {
        // A reading the pump cautions against is never offered, however old.
        guard glucoseCaution(context) == nil else { return nil }
        guard let reading = context.pump.glucose, reading.hasValidTime,
            GlucosePlausibility.isPlausible(mgdl: reading.value.mgdl),
            StaleBolusPrompt.mayOfferInclude(
                glucoseMgdl: reading.value.mgdl, glucoseDate: reading.measuredAt, thresholds: context.freshness,
                now: context.now)
        else { return nil }
        return reading
    }
}
