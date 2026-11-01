import Foundation

/// Display models shared by the phone, widgets and remotes. faBolus is a manual remote-bolus and
/// status app, not an automated closed loop. Glucose is in mg/dL.

public struct GlucoseReading: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let date: Date
    public let mgdl: Int
    public init(date: Date, mgdl: Int) {
        self.date = date
        self.mgdl = mgdl
    }
}

/// Insulin-on-board sample over time, for the chart's IOB overlay.
public struct IOBSample: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let date: Date
    public let iob: Double
    public init(date: Date, iob: Double) {
        self.date = date
        self.iob = iob
    }
}

/// A delivered bolus marked on the chart (vertical bar, height ∝ units).
public struct BolusMarker: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let date: Date
    public let units: Double
    public init(date: Date, units: Double) {
        self.date = date
        self.units = units
    }
}

public enum GlucoseTrend: String, Sendable, Hashable, Codable {
    case flat = "→", up = "↑", down = "↓", upUp = "⇈", downDown = "⇊"
    case rising = "↗", falling = "↘"

    /// Stable ASCII token identifying the trend direction, sent to remotes (Garmin) which draw
    /// their own arrow shape — their fonts can't render Unicode arrows.
    public var token: String {
        switch self {
        case .flat: return "flat"
        case .up: return "up"
        case .upUp: return "upup"
        case .rising: return "up45"
        case .down: return "down"
        case .downDown: return "downdown"
        case .falling: return "down45"
        }
    }

    /// Map a raw trend string (may be a Unicode arrow) to its direction token, or `nil` when there is
    /// no trend to report.
    ///
    /// An empty or unrecognized arrow means *unknown*, and must stay unknown all the way to the
    /// remote. This used to fall back to `.flat`, so a pump reporting "no arrow" became a flat arrow on
    /// the watch and on Garmin — an inferred trend presented as a reported one.
    public static func token(from raw: String) -> String? {
        GlucoseTrend(rawValue: raw)?.token
    }
}

/// Modern glucose ranges for coloring. Uses the **closed clinical convention** (matching
/// `GlucoseStatistics` and the Battelino 2019 TIR definition): 70…180 is in-range, 181…250 is high,
/// > 250 is urgent-high — so coloring agrees with the reported Time-in-Range at the exact boundaries
/// (180 colors in-range, 250 colors high). The four bands map to a 0…3 index the remotes/widgets consume.
/// (The display enum has no very-low band; readings below 70 all color `.low`.)
public enum GlucoseRange: Sendable {
    case low, inRange, high, urgentHigh
    public static func classify(_ mgdl: Int) -> GlucoseRange {
        switch mgdl {
        case ..<GlucoseThresholds.low: return .low  // < 70
        case GlucoseThresholds.low...GlucoseThresholds.high: return .inRange  // 70…180 (closed)
        case (GlucoseThresholds.high + 1)...GlucoseThresholds.veryHigh: return .high  // 181…250
        default: return .urgentHigh  // > 250
        }
    }

    /// Stable 0…3 band index (`low=0, inRange=1, high=2, urgentHigh=3`) — the single definition the
    /// remote client and widget snapshot delegate to instead of re-hardcoding the same 70/180/250 switch.
    public var index: Int {
        switch self {
        case .low: return 0
        case .inRange: return 1
        case .high: return 2
        case .urgentHigh: return 3
        }
    }

    /// Non-color channel for the glucose band (WCAG 1.4.1 "use of color"): a short label so the band
    /// reads without relying on color, for users who can't distinguish the green/yellow/orange/red
    /// tokens. Spoken by VoiceOver on every surface's accessibility label. On-screen the band is the
    /// number's zone color only — a glyph next to the value read as a checkmark or a second trend
    /// arrow beside the real CGM trend. faBolusCore doesn't import SwiftUI, so this stays a String.
    public var shortLabel: String {
        switch self {
        case .low: return "Low"
        case .inRange: return "In range"
        case .high: return "High"
        case .urgentHigh: return "Very high"
        }
    }
}

/// The honest "% of your configured max basal rate" readout. This is faBolus's OWN construct
/// (Tandem ships no such gauge): `basalRateUnitsPerHour ÷ maxBasalUnitsPerHour`, both already
/// decoded from the pump (`CurrentBasalStatusResponse` / `BasalLimitSettingsResponse`). Labeled
/// honestly as the pump's CONFIGURED max-basal delivery limit — a cap on ALL basal delivery —
/// and NEVER a Control-IQ or auto-bolus figure. Binding anti-misconstrual rules: (i) the label
/// always contains "basal"; (ii) the absolute U/hr always accompanies the %; (iii) the readout
/// lives physically separated from any bolus/correction surface (enforced at the call site,
/// `PumpControlView`'s pump-settings area — not here); (iv) a copy-audit test
/// (`CiqMaxBasalCopyAuditTests`) fails the build if the label ever contains one of
/// `forbiddenMisconstrualWords`; (v) opt-in, off by default, with a one-time feature-specific
/// explainer (also enforced at the call site).
public enum MaxBasalFraction {
    /// The exact forbidden misconstrual vocabulary, case-insensitive substring match. Any of
    /// these words in the label would misconstrue this faBolus-computed configured-basal-cap readout as
    /// a bolus, an automatic correction, a hard ceiling override, or "maxed out" delivery — none of
    /// which this feature is. Exposed as one shared list so the label builder and its test never drift.
    // <!-- planner-discipline-allow: bolus correction ceiling maxed -->
    public static let forbiddenMisconstrualWords: [String] = ["bolus", "correction", "ceiling", "maxed"]

    /// True when `text` contains any forbidden misconstrual word (case-insensitive substring).
    public static func hasForbiddenWord(_ text: String) -> Bool {
        forbiddenMisconstrualWords.contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// A fraction, NEVER a dose/units value: `currentUnitsPerHour ÷ maxUnitsPerHour`, clamped to
    /// `[0.0, 1.0]`. `nil` (fail-closed) when `maxUnitsPerHour <= 0` — the pump's configured
    /// max-basal limit is unknown/not yet read, so there is nothing honest to divide by; the caller
    /// must render the readout entirely ABSENT (not zero/dash) in that case.
    public static func fraction(currentUnitsPerHour: Double, maxUnitsPerHour: Double) -> Double? {
        guard maxUnitsPerHour > 0 else { return nil }
        let raw = currentUnitsPerHour / maxUnitsPerHour
        return min(max(raw, 0.0), 1.0)
    }

    /// Locked wording pair, or `nil` under the exact same fail-closed guard `fraction` uses.
    /// `headline` ALWAYS contains "basal"; `detail` ALWAYS shows both the current and configured
    /// max U/hr together (never the % alone). Both are guaranteed (by the copy-audit test) to never
    /// contain a `forbiddenMisconstrualWords` entry.
    public static func label(currentUnitsPerHour: Double, maxUnitsPerHour: Double) -> (
        headline: String, detail: String
    )? {
        guard let f = fraction(currentUnitsPerHour: currentUnitsPerHour, maxUnitsPerHour: maxUnitsPerHour) else {
            return nil
        }
        let pct = Int((f * 100).rounded())
        let headline = "\(pct)% of your configured max basal rate"
        let detail = String(format: "%.2f / %.2f U/hr", currentUnitsPerHour, maxUnitsPerHour)
        return (headline, detail)
    }
}

/// Which automated controller a pump runs, from the pump's own `PumpFeaturesV1` bits (op 79), never
/// guessed from the model name: none, classic Control-IQ, or Control-IQ+.
public enum ControllerVariant: String, Sendable, Hashable, Codable, CaseIterable {
    // The raw values are a v1 remote wire contract (`RemoteCommand.controllerVariant`), pinned so a
    // rename can't change the token an older remote parses. The product name is "Control-IQ+", but the
    // token stays `controlIQPro`.
    case none = "none"
    case controlIQ = "controlIQ"
    case controlIQPro = "controlIQPro"
}

/// A bolus the user is about to confirm (modern: carbs + BG → recommended units).
public struct BolusRecommendation: Sendable, Equatable {
    public var carbsGrams: Double = 0
    public var bgMgdl: Int?
    public var recommendedUnits: Double = 0
    public var iobUnits: Double = 0
    /// False when the pump's verified bolus-calculator profile (carb ratio / ISF / target) was not
    /// available and `assumedProfile` was used instead. Callers MUST require an explicit user
    /// confirmation of the assumed values before delivering, and never auto-deliver.
    public var inputsVerified: Bool = true
    /// The assumed profile used when `inputsVerified == false`, so the UI can show and confirm it.
    public var assumedProfile: BolusMath.Profile?
    /// TRUE when the pump has NEVER reported its bolus settings this session (op-115 never arrived),
    /// so `assumedProfile` is a HARDCODED fallback guess (CR 10 / ISF 40 / target 110), NOT the pump's real
    /// last-known values. A dose sized off that guess must NOT be deliverable via the warned "use last-known
    /// settings" override (there are no last-known settings, and a carb dose cannot be sized without a real
    /// carb ratio — a wrong guess is a potential multiple-dose). The gate blocks (cancel-only) in
    /// this case. FALSE means real CR/ISF/target were read at some point (they may be *stale* — that IS the
    /// legitimate warned-override case, using real-but-old values).
    public var therapyUnavailable: Bool = false
    /// Freshness channel. True when the active-insulin term the dose was built from was stale (or
    /// the op-115/op-109 IOB cross-check diverged) at compose time. `inputsVerified` is the fail-closed
    /// gate every surface already honors; these carry the *why* (and the ages) so the UI can later offer the
    /// warned include-last-known override. `iobStale || therapyStale` ⇒ `inputsVerified == false`.
    public var iobStale: Bool = false
    /// True when the therapy params (CR/ISF/target) the dose was built from were stale at compose time.
    public var therapyStale: Bool = false
    /// Age provenance of the two calc inputs (from the snapshot at compose time), for the UI/remote wire.
    public var iobDate: Date?
    public var therapyParamsDate: Date?
    /// Display gate. A recommendation is sized off a hardcoded CR/ISF/target guess whenever the
    /// pump's bolus settings were never read this session (`therapyUnavailable`); any number derived from
    /// that guess — the "Recommended dose", the carb+correction/IOB reasoning breakdown, an override-divergence
    /// note, or a pre-filled units field — traces to an uncited literal (every displayed number
    /// traces to a pump read, a user entry, or a published constant). It MUST NOT be displayed; the UI shows
    /// a "waiting for the pump's settings" prompt instead. Delivery is already blocked in this case
    /// (`CalcInputGate.decide` → `.blockNoTherapy`). A recommendation off real-but-STALE last-known therapy is
    /// exempt (its numbers trace to real pump reads, just old — the legitimate warned-override case).
    public var displaysNumericDose: Bool { !therapyUnavailable }
    public init() {}
}
