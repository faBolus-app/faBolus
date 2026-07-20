import Foundation

/// Domain models for the modern HUD. Terminology uses common names (IOB = "Active Insulin",
/// COB = "Active Carbohydrates"), but ControlX2 is a manual remote-bolus + status viewer, NOT
/// an automated closed loop. Glucose is in mg/dL.

public struct GlucoseReading: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let date: Date
    public let mgdl: Int
    public init(date: Date, mgdl: Int) { self.date = date; self.mgdl = mgdl }
}

/// Insulin-on-board sample over time, for the chart's IOB overlay.
public struct IOBSample: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let date: Date
    public let iob: Double
    public init(date: Date, iob: Double) { self.date = date; self.iob = iob }
}

/// A delivered bolus marked on the chart (vertical bar, height ∝ units).
public struct BolusMarker: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let date: Date
    public let units: Double
    public init(date: Date, units: Double) { self.date = date; self.units = units }
}

public enum GlucoseTrend: String, Sendable {
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

    /// Map a raw trend string (may be a Unicode arrow) to its direction token.
    public static func token(from raw: String) -> String {
        (GlucoseTrend(rawValue: raw) ?? .flat).token
    }
}

/// modern glucose ranges for coloring.
public enum GlucoseRange: Sendable {
    case low, inRange, high, urgentHigh
    public static func classify(_ mgdl: Int) -> GlucoseRange {
        switch mgdl {
        case ..<70: return .low
        case 70..<180: return .inRange
        case 180..<250: return .high
        default: return .urgentHigh
        }
    }
}

/// Connection/activity status shown by the HUD ring (a status ring —
/// we show link/bolus state, never closed-loop automation).
public enum PumpConnectionState: String, Sendable {
    case disconnected = "Disconnected"
    case scanning = "Scanning…"
    case connecting = "Connecting…"
    case connected = "Connected"
    case bolusing = "Delivering…"
    case error = "Error"
}

/// Snapshot of pump state for the HUD.
public struct PumpSnapshot: Sendable, Equatable {
    public var connection: PumpConnectionState = .disconnected
    public var glucose: Int? = nil
    /// When the current glucose reading was taken. Used to hide readings older than 6 minutes.
    public var glucoseDate: Date? = nil
    public var trend: String = GlucoseTrend.flat.rawValue
    public var iobUnits: Double = 0          // Active Insulin
    public var reservoirUnits: Double = 0
    public var batteryPercent: Int = 0
    public var cgmActive: Bool = false
    public var lastBolusUnits: Double? = nil
    public var lastBolusDate: Date? = nil
    /// Pump's configured max bolus (units), read from the calculator snapshot. Governs the UI
    /// cap instead of a hardcoded number. Falls back to the pump's absolute max.
    public var maxBolusUnits: Double = 25
    // Bolus-calculator settings (from the pump), shared with remotes so they can compute
    // carbs→units locally.
    public var carbRatio: Double = 0    // grams per unit
    public var isf: Int = 0             // correction factor, mg/dL per unit
    public var targetBg: Int = 0        // mg/dL
    public init() {}

    /// A CGM reading is considered stale (don't display the number) after 6 minutes.
    public var isGlucoseStale: Bool {
        guard let d = glucoseDate else { return glucose != nil }  // unknown age → treat as stale
        return Date().timeIntervalSince(d) > 6 * 60
    }
}

/// A bolus the user is about to confirm (modern: carbs + BG → recommended units).
public struct BolusRecommendation: Sendable, Equatable {
    public var carbsGrams: Double = 0
    public var bgMgdl: Int? = nil
    public var recommendedUnits: Double = 0
    public var iobUnits: Double = 0
    public init() {}
}
