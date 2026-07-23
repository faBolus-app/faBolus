import Foundation

/// Configurable, multi-signal eating-nudge trigger. The user picks a **mode** (how the accelerometer and
/// CGM-meal signals combine), thresholds, a no-recent-bolus gate, an optional location gate, and a
/// **confirmation delay**. Advisory only — it decides *whether to prompt*, never doses. Pure/testable;
/// lives in faBolusCore so the app + tests share it.
public struct EatingTriggerConfig: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// DEFAULT, battery-smart: the CGM (already streaming, no extra battery) flags a likely meal, then
        /// the wrist sensor spins up to CONFIRM. Fewest false alerts + lowest battery, but a *later* nudge
        /// (CGM lags ~20 min) — a "you ate & haven't bolused" catch rather than an early pre-bolus prompt.
        case cgmThenAccel
        /// Accel + CGM both sensed continuously; both must agree. Early + precise, but highest battery.
        case bothAlways
        /// Either signal fires. Earliest + most sensitive, most false alerts.
        case either
        /// Accelerometer only (early; needs the wrist sensor running).
        case accelOnly
        /// CGM only (no wrist sensor; later; noisier — CGM rises aren't always meals).
        case cgmOnly

        public var usesAccel: Bool { self != .cgmOnly }
        public var usesCGM: Bool { self != .accelOnly }
        /// Keep the wrist sensor OFF until the CGM flags a likely meal (the battery win).
        public var escalatesAccelFromCGM: Bool { self == .cgmThenAccel }
    }

    public var mode: Mode = .cgmThenAccel
    /// Accelerometer p(eating) ≥ this counts as positive. Higher = fewer false alerts, lower recall.
    public var accelThreshold = 0.85
    /// CGM unannounced-meal score (0…1) ≥ this counts as positive. Higher = stricter.
    public var cgmMealThreshold = 0.5
    /// Only nudge at a learned "meal place" (optional/advanced; off by default for privacy).
    public var locationEnabled = false
    /// Suppress if a bolus was given within this many minutes (you already covered it).
    public var minMinutesSinceBolus = 20
    /// The fused condition must hold this long before firing. Longer = more confident / fewer false
    /// alerts, but a later (clinically weaker) nudge.
    public var confirmationDelaySeconds = 60

    public init() {}
}

/// A snapshot of the live signals fed to the engine. `nil` = unavailable/not measured.
public struct EatingSignals: Sendable {
    public var accelProb: Double?          // p(eating) from the model
    public var cgmMealScore: Double?       // 0…1 unannounced-meal score
    public var minutesSinceBolus: Double   // very large if never bolused
    public var atMealPlace: Bool?          // location gate result (nil if off/unknown)
    public init(accelProb: Double? = nil, cgmMealScore: Double? = nil,
                minutesSinceBolus: Double = .greatestFiniteMagnitude, atMealPlace: Bool? = nil) {
        self.accelProb = accelProb; self.cgmMealScore = cgmMealScore
        self.minutesSinceBolus = minutesSinceBolus; self.atMealPlace = atMealPlace
    }
}

public enum EatingDecision: Equatable, Sendable {
    case fire
    case hold(reason: String)       // conditions partly met / still confirming — no prompt yet
    case suppress(reason: String)   // a gate blocked it
}

/// Pure fusion + confirmation-delay engine. Call `evaluate` on each new signal snapshot; it tracks how
/// long the fused condition has continuously held and returns `.fire` once it clears the delay. Firing
/// resets the timer; downstream `AlertIntelligence` handles re-fire rate limiting / quiet hours.
public final class EatingTriggerEngine {
    public private(set) var config: EatingTriggerConfig
    private var conditionSince: Date?

    public init(config: EatingTriggerConfig) { self.config = config }
    public func setConfig(_ c: EatingTriggerConfig) { config = c; conditionSince = nil }
    public func reset() { conditionSince = nil }

    /// Whether the accel/CGM signals meet the configured combination (ignores the bolus/location
    /// gates and the confirmation delay). Used to detect that eating was *recognized* even when a nudge
    /// is suppressed — e.g. a pre-bolus meal, which is a silent positive training example.
    public func signalsMet(_ s: EatingSignals) -> Bool {
        let accelPos = (s.accelProb ?? -1) >= config.accelThreshold
        let cgmPos = (s.cgmMealScore ?? -1) >= config.cgmMealThreshold
        switch config.mode {
        case .accelOnly:                 return accelPos
        case .cgmOnly:                   return cgmPos
        case .either:                    return accelPos || cgmPos
        case .bothAlways, .cgmThenAccel: return accelPos && cgmPos   // cgmThenAccel differs only in *when*
        }                                                            // accel is sensed (wiring/battery)
    }

    public func evaluate(_ s: EatingSignals, now: Date = Date()) -> EatingDecision {
        if s.minutesSinceBolus < Double(config.minMinutesSinceBolus) {
            conditionSince = nil
            return .suppress(reason: "bolused in the last \(config.minMinutesSinceBolus) min")
        }
        if config.locationEnabled, s.atMealPlace == false {
            conditionSince = nil
            return .suppress(reason: "not at a meal location")
        }

        guard signalsMet(s) else {
            conditionSince = nil
            return .hold(reason: "signals not met")
        }

        if conditionSince == nil { conditionSince = now }
        let held = now.timeIntervalSince(conditionSince ?? now)
        if held < Double(config.confirmationDelaySeconds) {
            return .hold(reason: "confirming (\(Int(held))/\(config.confirmationDelaySeconds)s)")
        }
        conditionSince = nil
        return .fire
    }
}

/// Rough, clearly-approximate guidance shown next to each setting so the user can tune the trade-off.
/// Direction is what matters: stricter thresholds / `.cgmThenAccel` / `.bothAlways` / longer delay ⇒ fewer
/// false alerts (and, for `cgmThenAccel`, lower battery + a later nudge); `.either` / lower thresholds ⇒
/// earlier + more sensitive but noisier. The on-device personalizer + AlertIntelligence refine actual
/// rates per user over time.
public struct EatingTriggerEstimate: Equatable, Sendable {
    public enum Battery: String, Sendable { case none, low, medium, high }
    public let falseAlertsPerDay: Double
    public let recallPercent: Int          // ~% of meals caught
    public let typicalTimeToAlertSeconds: Int
    public let battery: Battery
}

/// Accelerometer-model operating points **from the model's own held-out assessment** (faBolusNudge
/// `RESULTS_SUMMARY.md`), shipped in the ModelCatalogKit manifest so the guidance reflects the ACTUAL
/// deployed model — not a hand-picked guess. The app passes the manifest's metrics; `faBolusDefault` is
/// the documented fallback.
public struct EatingModelMetrics: Codable, Equatable, Sendable {
    public struct OperatingPoint: Codable, Equatable, Sendable {
        public let threshold: Double          // accel enter-threshold
        public let recall: Double             // meal recall (0…1)
        public let falseAlertsPerDay: Double
        public init(threshold: Double, recall: Double, falseAlertsPerDay: Double) {
            self.threshold = threshold; self.recall = recall; self.falseAlertsPerDay = falseAlertsPerDay
        }
    }
    public let operatingPoints: [OperatingPoint]
    public let source: String
    public init(operatingPoints: [OperatingPoint], source: String) {
        self.operatingPoints = operatingPoints.sorted { $0.threshold < $1.threshold }
        self.source = source
    }
    /// Clamped linear interpolation of (recall, FA/day) at an enter-threshold.
    public func at(_ t: Double) -> (recall: Double, falseAlertsPerDay: Double) {
        guard let lo = operatingPoints.first, let hi = operatingPoints.last else { return (0, 0) }
        if t <= lo.threshold { return (lo.recall, lo.falseAlertsPerDay) }
        if t >= hi.threshold { return (hi.recall, hi.falseAlertsPerDay) }
        for i in 1..<operatingPoints.count {
            let a = operatingPoints[i - 1], b = operatingPoints[i]
            if t <= b.threshold {
                let f = (t - a.threshold) / (b.threshold - a.threshold)
                return (a.recall + f * (b.recall - a.recall),
                        a.falseAlertsPerDay + f * (b.falseAlertsPerDay - a.falseAlertsPerDay))
            }
        }
        return (hi.recall, hi.falseAlertsPerDay)
    }
    /// From the held-out free-living assessment (episode-scale + debounce, 45 held-out meals — the
    /// largest sample in RESULTS_SUMMARY.md). Ship the deployed model's real points via the manifest.
    public static let faBolusDefault = EatingModelMetrics(operatingPoints: [
        .init(threshold: 0.80, recall: 0.62, falseAlertsPerDay: 7.2),
        .init(threshold: 0.85, recall: 0.62, falseAlertsPerDay: 4.1),
        .init(threshold: 0.90, recall: 0.51, falseAlertsPerDay: 2.2),
        .init(threshold: 0.95, recall: 0.49, falseAlertsPerDay: 0.6),
    ], source: "held-out free-living assessment")
}

public enum EatingTriggerEstimator {
    // CGM unannounced-meal signal: no per-threshold assessment yet — a documented literature placeholder
    // (Loop Missed-Meal-style), to be replaced by the ported detector's own eval.
    private static let cgmBaseFA = 1.5
    private static let cgmBaseRecall = 0.55
    private static let cgmDetectionLagSec = 20 * 60
    private static let accelDetectionLagSec = 60

    /// `accelMetrics` come from the accel model's held-out assessment (via the manifest).
    public static func estimate(_ c: EatingTriggerConfig,
                                accelMetrics: EatingModelMetrics = .faBolusDefault) -> EatingTriggerEstimate {
        func scaled(baseFA: Double, baseRecall: Double, threshold: Double, ref: Double) -> (fa: Double, recall: Double) {
            let strictness = max(0.1, threshold / ref)
            return (baseFA / (strictness * strictness), min(0.95, baseRecall / strictness))
        }
        // Accelerometer FA/recall come straight from the model's assessed operating points.
        let ap = accelMetrics.at(c.accelThreshold)
        let a = (fa: ap.falseAlertsPerDay, recall: ap.recall)
        let g = scaled(baseFA: cgmBaseFA, baseRecall: cgmBaseRecall, threshold: c.cgmMealThreshold, ref: 0.5)

        var fa = 0.0, recall = 0.0, lag = 0, battery: EatingTriggerEstimate.Battery = .low
        // AND coincidence within ~1 h windows ⇒ product / 24.
        let andFA = (a.fa * g.fa) / 24.0
        switch c.mode {
        case .accelOnly:
            fa = a.fa; recall = a.recall; lag = accelDetectionLagSec; battery = .medium
        case .cgmOnly:
            fa = g.fa; recall = g.recall; lag = cgmDetectionLagSec; battery = .none
        case .either:
            fa = a.fa + g.fa; recall = 1 - (1 - a.recall) * (1 - g.recall)
            lag = min(accelDetectionLagSec, cgmDetectionLagSec); battery = .high
        case .bothAlways:
            fa = andFA; recall = min(a.recall, g.recall); lag = max(accelDetectionLagSec, cgmDetectionLagSec); battery = .high
        case .cgmThenAccel:
            // CGM flags first, wrist confirms during a burst → same precision as bothAlways, but accel only
            // runs on demand (low battery) and the nudge waits for the CGM lag + a short confirm.
            fa = andFA; recall = min(a.recall, g.recall); lag = cgmDetectionLagSec + accelDetectionLagSec; battery = .low
        }

        let delay = Double(c.confirmationDelaySeconds)
        fa *= exp(-delay / 180)
        lag += c.confirmationDelaySeconds
        return EatingTriggerEstimate(falseAlertsPerDay: (fa * 10).rounded() / 10,
                                     recallPercent: Int((recall * 100).rounded()),
                                     typicalTimeToAlertSeconds: lag, battery: battery)
    }
}
