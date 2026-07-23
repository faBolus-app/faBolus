import Foundation

/// Configurable, multi-signal eating-nudge trigger. The user picks which signals must agree (accelerometer
/// eating prediction, CGM unannounced-meal prediction, optional location), how they combine, a
/// no-recent-bolus gate, and a **confirmation delay** (patience). Advisory only — it decides *whether to
/// prompt*, never doses. Pure/testable; lives in faBolusCore so the app + tests share it.
public struct EatingTriggerConfig: Codable, Equatable, Sendable {
    public enum Combine: String, Codable, CaseIterable, Sendable {
        case all          // every enabled signal must be positive (fewest false alerts)
        case any          // any one enabled signal (most sensitive)
        case atLeastTwo   // ≥2 enabled signals agree
    }
    /// Accelerometer p(eating) ≥ this counts as positive. Higher = fewer false alerts, lower recall.
    public var accelEnabled = true
    public var accelThreshold = 0.85
    /// CGM unannounced-meal score (0…1) ≥ this counts as positive. Higher = stricter.
    public var cgmMealEnabled = true
    public var cgmMealThreshold = 0.5
    /// Only nudge at a learned "meal place" (optional/advanced; off by default for privacy).
    public var locationEnabled = false
    public var combine: Combine = .all
    /// Suppress if a bolus was given within this many minutes (you already covered it).
    public var minMinutesSinceBolus = 20
    /// The fused condition must hold this long before firing. Longer = more confident / fewer false
    /// alerts, but a later (clinically weaker) nudge. Maps to the detector's sustained-window debounce.
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

    public func evaluate(_ s: EatingSignals, now: Date = Date()) -> EatingDecision {
        if s.minutesSinceBolus < Double(config.minMinutesSinceBolus) {
            conditionSince = nil
            return .suppress(reason: "bolused in the last \(config.minMinutesSinceBolus) min")
        }
        if config.locationEnabled, s.atMealPlace == false {
            conditionSince = nil
            return .suppress(reason: "not at a meal location")
        }

        var required = 0, positives = 0
        if config.accelEnabled {
            required += 1
            if let p = s.accelProb, p >= config.accelThreshold { positives += 1 }
        }
        if config.cgmMealEnabled {
            required += 1
            if let m = s.cgmMealScore, m >= config.cgmMealThreshold { positives += 1 }
        }
        // Location, when enabled, is a gate (handled above), not a counted signal.

        let met: Bool
        switch config.combine {
        case .all:        met = required > 0 && positives == required
        case .any:        met = positives >= 1
        case .atLeastTwo: met = positives >= 2
        }
        guard met else {
            conditionSince = nil
            return .hold(reason: "signals not met (\(positives)/\(required))")
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
/// Direction is what matters: stricter thresholds / more signals (`.all`) / longer delay ⇒ fewer false
/// alerts and a later nudge; `.any` / lower thresholds ⇒ earlier + more sensitive but noisier. The
/// on-device personalizer + AlertIntelligence refine actual rates per user over time.
public struct EatingTriggerEstimate: Equatable, Sendable {
    public let falseAlertsPerDay: Double
    public let recallPercent: Int          // ~% of meals caught
    public let typicalTimeToAlertSeconds: Int
}

public enum EatingTriggerEstimator {
    // Baselines at a "default" operating point, from the eating-model + CGM-meal literature (approx).
    private static let accelBaseFA = 4.0     // FA/day for accel alone at threshold ~0.85
    private static let cgmBaseFA = 1.5       // FA/day for CGM unannounced-meal alone
    private static let accelBaseRecall = 0.60
    private static let cgmBaseRecall = 0.55
    private static let cgmDetectionLagSec = 20 * 60   // CGM meal shows ~20 min after eating starts
    private static let accelDetectionLagSec = 60      // wrist motion is near-immediate

    public static func estimate(_ c: EatingTriggerConfig) -> EatingTriggerEstimate {
        // Per-signal FA/day and recall scaled by how strict the threshold is (higher threshold ⇒ fewer FA,
        // lower recall). Threshold 0.85/0.5 = baseline.
        func scaled(baseFA: Double, baseRecall: Double, threshold: Double, ref: Double)
            -> (fa: Double, recall: Double) {
            let strictness = max(0.1, threshold / ref)          // >1 = stricter than baseline
            return (baseFA / (strictness * strictness), min(0.95, baseRecall / strictness))
        }

        var faList: [Double] = [], recallList: [Double] = []
        var lags: [Int] = []
        if c.accelEnabled {
            let a = scaled(baseFA: accelBaseFA, baseRecall: accelBaseRecall, threshold: c.accelThreshold, ref: 0.85)
            faList.append(a.fa); recallList.append(a.recall); lags.append(accelDetectionLagSec)
        }
        if c.cgmMealEnabled {
            let g = scaled(baseFA: cgmBaseFA, baseRecall: cgmBaseRecall, threshold: c.cgmMealThreshold, ref: 0.5)
            faList.append(g.fa); recallList.append(g.recall); lags.append(cgmDetectionLagSec)
        }
        guard !faList.isEmpty else {
            return EatingTriggerEstimate(falseAlertsPerDay: 0, recallPercent: 0, typicalTimeToAlertSeconds: 0)
        }

        var fa: Double, recall: Double, lag: Int
        switch c.combine {
        case .all:
            // AND: false alerts must coincide → roughly the product (scaled to /day); recall is the min;
            // you wait for the slowest signal.
            fa = faList.reduce(1, *) / pow(24, Double(faList.count - 1))   // coincidence within ~1h windows
            recall = recallList.min() ?? 0
            lag = lags.max() ?? 0
        case .any:
            // OR: false alerts add up; recall combines; you fire on the fastest signal.
            fa = faList.reduce(0, +)
            recall = 1 - recallList.reduce(1) { $0 * (1 - $1) }
            lag = lags.min() ?? 0
        case .atLeastTwo:
            fa = (faList.reduce(1, *) / pow(24, Double(max(1, faList.count - 1)))) * 1.5
            recall = recallList.min() ?? 0
            lag = lags.max() ?? 0
        }

        // Confirmation delay: fewer transient false alerts (decays with delay), later alert (adds delay).
        let delay = Double(c.confirmationDelaySeconds)
        fa *= exp(-delay / 180)                        // ~3-min time-constant for transient FAs
        lag += c.confirmationDelaySeconds

        return EatingTriggerEstimate(falseAlertsPerDay: (fa * 10).rounded() / 10,
                                     recallPercent: Int((recall * 100).rounded()),
                                     typicalTimeToAlertSeconds: lag)
    }
}
