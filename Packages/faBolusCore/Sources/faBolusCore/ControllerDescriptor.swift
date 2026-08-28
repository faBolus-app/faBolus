import Foundation

/// A pump's automated-controller behavior expressed as **data**, so the app describes what a controller
/// does by reading one value instead of scattering `if controlIQ { … }` branches and hardcoded clinical
/// numbers across the UI. This is the "controller descriptor as data" of P13c: the single source of truth
/// for the five behaviors §2.4 enumerates, keyed on `ControllerVariant` (the pump's own Control-IQ /
/// Control-IQ+ discriminator from `PumpFeatureBits`, never guessed from the model name).
///
/// **These are DISCLOSURE facts, not therapy parameters.** They describe what the *pump's* onboard
/// controller does on its own — what the user is told (S1 auto-correction lockout disclosure, O1/O3,
/// DS1), never what faBolus computes with. faBolus is a manual remote-bolus + status viewer (C3: it never
/// models the controller's state and never predicts glucose). Nothing here feeds a dose: bolus math uses
/// the pump's own carb-ratio / ISF / target read live from the pump.
///
/// **§13 — every clinical number names its source, and every value here is subject to the clinical-review
/// distribution gate** before any `experimental` build leaves the developer. Sources for the Tandem
/// values below:
///   - Tandem *Control-IQ Technology User Guide* (auto-correction: 60% of the calculated dose toward a
///     110 mg/dL target, at most once per 60 min, blocked by any bolus in the previous 60 min; standard
///     range treats a 30-min prediction of 112.5–160 mg/dL as in-range; suspends toward < 70 mg/dL;
///     Sleep activity targets 112.5–120 mg/dL with automatic correction boluses disabled; Exercise
///     activity targets 140–160 mg/dL and raises the suspension threshold).
///   - Brown SA et al. "Six-Month Randomized, Multicenter Trial of Closed-Loop Control in Type 1
///     Diabetes." *N Engl J Med* 2019;381(18):1707–1717 (pivotal Control-IQ trial).
///   - The Control-IQ vs Control-IQ+ discriminator: Control-IQ+ (newer software, Mobi and t:slim X2)
///     additionally delivers automatic correction boluses during the Sleep activity, which classic
///     Control-IQ does not — the one behavior difference the descriptor must render correctly.
///
/// **Pump-agnostic by construction (C10, and the seam the §2.4 DASH exercise + future Omnipod work reads).**
/// The type carries no Tandem-specific assumptions: a pump with no onboard controller (Omnipod DASH) is
/// `.none` and every controller-specific line simply doesn't render; a pump whose targets the user sets
/// (Omnipod 5) sets `targetsUserAdjustable = true`; a controller that learns basal from history rather
/// than from weight/TDI expresses that through `drivingParameters`. See `ControllerDescriptor.dashExercise`
/// notes in the P13d design doc for how a non-Tandem descriptor is assembled.
public struct ControllerDescriptor: Sendable, Equatable {
    /// The controller this descriptor describes (the pump's own bits decide it; see `ControllerVariant`).
    public var variant: ControllerVariant
    /// Brand name shown to the user for the controller itself, e.g. "Control-IQ" / "Control-IQ+".
    /// Empty for `.none` (a pump with no onboard controller has no controller name to show).
    /// NOTE: this is the controller's *marketing* name for UI copy; it is deliberately separate from the
    /// pump-*model* brand (`PumpModel.displayName`) and from the manufacturer legal name.
    public var displayName: String
    /// §2.4 field 1 — automatic (closed-loop) correction behavior.
    public var automaticCorrection: AutomaticCorrection
    /// §2.4 field 2 — activity/mode presets and how they shift the target band.
    public var activityPresets: [ActivityPreset]
    /// §2.4 field 3 — which programmed therapy parameters the controller consumes to drive its automation.
    public var drivingParameters: [TherapyParameter]
    /// §2.4 field 4 — whether the controller's glucose target is user-adjustable. Control-IQ: no (a fixed
    /// internal target); Omnipod 5: yes (the user programs the target). Governs whether a "target" control
    /// is even offered and whether the app may present the controller target as settable.
    public var targetsUserAdjustable: Bool
    /// §2.4 field 5 — whether the controller modulates basal relative to the programmed profile, and any
    /// ceiling on that modulation.
    public var basalModulation: BasalModulation

    public init(
        variant: ControllerVariant, displayName: String,
        automaticCorrection: AutomaticCorrection, activityPresets: [ActivityPreset],
        drivingParameters: [TherapyParameter], targetsUserAdjustable: Bool,
        basalModulation: BasalModulation
    ) {
        self.variant = variant
        self.displayName = displayName
        self.automaticCorrection = automaticCorrection
        self.activityPresets = activityPresets
        self.drivingParameters = drivingParameters
        self.targetsUserAdjustable = targetsUserAdjustable
        self.basalModulation = basalModulation
    }

    /// True when this pump runs an automated controller at all (i.e. not `.none`). The single predicate
    /// UI should ask before rendering *any* controller-specific line — so a no-controller pump (DASH)
    /// hides all of it with one check rather than N scattered `variant == .none` tests.
    public var hasController: Bool { variant != .none }

    /// The descriptor for a given controller variant. The whole point of P13c: one place maps the pump's
    /// own bits to what its controller does, so every future consumer reads it instead of re-deriving.
    public static func `for`(_ variant: ControllerVariant) -> ControllerDescriptor {
        switch variant {
        case .none: return .noController
        case .controlIQ: return .controlIQ
        case .controlIQPro: return .controlIQPlus
        }
    }
}

/// §2.4 field 1 — the closed-loop automatic-correction bolus behavior.
public struct AutomaticCorrection: Sendable, Equatable {
    /// Whether the controller delivers automatic correction boluses at all.
    public var enabled: Bool
    /// The fraction of the *calculated* correction the controller actually delivers (Control-IQ /
    /// Control-IQ+: 0.60). nil when there is no automatic correction.
    public var deliveredFraction: Double?
    /// The glucose target the automatic correction aims for, mg/dL (Control-IQ: 110). Fixed and internal
    /// to the controller — NOT the user's Personal-Profile bolus target, and not what faBolus doses to.
    public var targetMgdl: Double?
    /// Minimum spacing between automatic corrections, minutes (Control-IQ: 60 — at most once per hour).
    public var minIntervalMinutes: Int?
    /// A user/automatic bolus in the previous N minutes blocks the next automatic correction (Control-IQ:
    /// 60). This is the "lockout" S1 discloses: after a manual bolus the controller won't auto-correct for
    /// this long, which is exactly what the stacking-guard temp-rate alternative (Addendum A) works around.
    public var blockedByRecentBolusMinutes: Int?

    public init(
        enabled: Bool, deliveredFraction: Double? = nil, targetMgdl: Double? = nil,
        minIntervalMinutes: Int? = nil, blockedByRecentBolusMinutes: Int? = nil
    ) {
        self.enabled = enabled
        self.deliveredFraction = deliveredFraction
        self.targetMgdl = targetMgdl
        self.minIntervalMinutes = minIntervalMinutes
        self.blockedByRecentBolusMinutes = blockedByRecentBolusMinutes
    }

    /// No automatic correction (a pump with no controller).
    public static let none = AutomaticCorrection(enabled: false)
}

/// §2.4 field 2 — one activity/mode preset and how it shifts the controller's behavior.
public struct ActivityPreset: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// Preset name as the user knows it, e.g. "Sleep" / "Exercise".
    public var name: String
    /// The controller's target band while this preset is active, mg/dL. `low == high` for a single target.
    public var targetLowMgdl: Double
    public var targetHighMgdl: Double
    /// The glucose the controller suspends insulin toward while this preset is active, mg/dL. nil when the
    /// preset doesn't change the standard suspension behavior.
    public var suspendThresholdMgdl: Double?
    /// Whether automatic correction boluses are delivered while this preset is active. This is the
    /// Control-IQ vs Control-IQ+ discriminator for Sleep: classic Control-IQ disables auto-corrections
    /// during Sleep; Control-IQ+ keeps them on.
    public var automaticCorrectionEnabled: Bool

    public init(
        name: String, targetLowMgdl: Double, targetHighMgdl: Double,
        suspendThresholdMgdl: Double? = nil, automaticCorrectionEnabled: Bool
    ) {
        self.name = name
        self.targetLowMgdl = targetLowMgdl
        self.targetHighMgdl = targetHighMgdl
        self.suspendThresholdMgdl = suspendThresholdMgdl
        self.automaticCorrectionEnabled = automaticCorrectionEnabled
    }
}

/// §2.4 field 3 — a programmed therapy parameter a controller consumes. Pump-agnostic: covers the
/// Tandem inputs (basal profile, carb ratio, correction factor, plus the Control-IQ personalization of
/// body weight + total daily insulin) and the Omnipod-5 input (adaptive basal learned from history) so a
/// non-Tandem descriptor can express what drives it without a new type.
public enum TherapyParameter: String, Sendable, Equatable, CaseIterable {
    /// The programmed basal-rate schedule.
    case basalProfile
    /// Insulin-to-carb ratio (grams per unit).
    case carbRatio
    /// Correction factor / insulin sensitivity (mg/dL per unit).
    case correctionFactor
    /// The programmed glucose target (used by controllers that let the user set it, e.g. Omnipod 5).
    case targetGlucose
    /// Body weight — Control-IQ requires it to seed its model.
    case bodyWeight
    /// Total daily insulin — Control-IQ requires it to seed its model.
    case totalDailyInsulin
    /// Basal adaptively learned from delivery history rather than programmed (Omnipod 5). Present so the
    /// DASH/OP5 exercise can express an adaptive controller.
    case adaptiveBasalLearning

    /// Short human label for disclosure UI.
    public var label: String {
        switch self {
        case .basalProfile: return "Basal profile"
        case .carbRatio: return "Carb ratio"
        case .correctionFactor: return "Correction factor"
        case .targetGlucose: return "Glucose target"
        case .bodyWeight: return "Body weight"
        case .totalDailyInsulin: return "Total daily insulin"
        case .adaptiveBasalLearning: return "Adaptive basal (learned)"
        }
    }
}

/// §2.4 field 5 — whether/how the controller modulates basal relative to the programmed profile.
public enum BasalModulation: Sendable, Equatable {
    /// The controller does not modulate basal (a pump with no onboard controller — DASH).
    case none
    /// The controller adjusts basal relative to the programmed profile, optionally capped at a multiple of
    /// the profile rate. Control-IQ increases/decreases and can suspend around the programmed profile; the
    /// ceiling is expressed as a multiple (nil when unspecified/uncapped in the descriptor).
    case relativeToProfile(maxMultiple: Double?)
}

// MARK: - Tandem instances (§13 clinical-review-gated values)

public extension ControllerDescriptor {
    /// A pump with no onboard automated controller (e.g. Omnipod DASH). Every controller-specific line
    /// disclaims to nothing. This is also the value the §2.4 DASH exercise (P13d) starts from.
    static let noController = ControllerDescriptor(
        variant: .none,
        displayName: "",
        automaticCorrection: .none,
        activityPresets: [],
        drivingParameters: [],
        targetsUserAdjustable: false,
        basalModulation: .none)

    /// Classic **Control-IQ** (t:slim X2). Automatic correction 60% toward 110 mg/dL, ≤ once/60 min,
    /// blocked by any bolus in the prior 60 min; Sleep disables auto-corrections; Exercise raises the band.
    static let controlIQ = ControllerDescriptor(
        variant: .controlIQ,
        displayName: "Control-IQ",
        automaticCorrection: AutomaticCorrection(
            enabled: true, deliveredFraction: 0.60, targetMgdl: 110,
            minIntervalMinutes: 60, blockedByRecentBolusMinutes: 60),
        activityPresets: [
            // Sleep: tighter target band, and classic Control-IQ delivers NO automatic corrections here.
            ActivityPreset(
                name: "Sleep", targetLowMgdl: 112.5, targetHighMgdl: 120,
                automaticCorrectionEnabled: false),
            // Exercise: higher target band and a raised suspension threshold.
            ActivityPreset(
                name: "Exercise", targetLowMgdl: 140, targetHighMgdl: 160,
                suspendThresholdMgdl: 79, automaticCorrectionEnabled: false)
        ],
        // Control-IQ is seeded by body weight + total daily insulin on top of the programmed profile.
        drivingParameters: [.basalProfile, .carbRatio, .correctionFactor, .bodyWeight, .totalDailyInsulin],
        targetsUserAdjustable: false,  // Control-IQ's target is fixed and internal — not user-settable.
        basalModulation: .relativeToProfile(maxMultiple: nil))

    /// **Control-IQ+** (Mobi, and t:slim X2 on newer software). Identical to classic Control-IQ except it
    /// **also delivers automatic corrections during Sleep** — the one behavior the CIQ/CIQ+ discriminator
    /// exists to render correctly (O7).
    static let controlIQPlus = ControllerDescriptor(
        variant: .controlIQPro,
        displayName: "Control-IQ+",
        automaticCorrection: AutomaticCorrection(
            enabled: true, deliveredFraction: 0.60, targetMgdl: 110,
            minIntervalMinutes: 60, blockedByRecentBolusMinutes: 60),
        activityPresets: [
            // Sleep on Control-IQ+ keeps automatic corrections ON (the discriminator's clinical meaning).
            ActivityPreset(
                name: "Sleep", targetLowMgdl: 112.5, targetHighMgdl: 120,
                automaticCorrectionEnabled: true),
            ActivityPreset(
                name: "Exercise", targetLowMgdl: 140, targetHighMgdl: 160,
                suspendThresholdMgdl: 79, automaticCorrectionEnabled: false)
        ],
        drivingParameters: [.basalProfile, .carbRatio, .correctionFactor, .bodyWeight, .totalDailyInsulin],
        targetsUserAdjustable: false,
        basalModulation: .relativeToProfile(maxMultiple: nil))
}
