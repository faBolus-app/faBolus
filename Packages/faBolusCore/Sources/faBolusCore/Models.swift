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
