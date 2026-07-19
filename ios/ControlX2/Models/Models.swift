import Foundation

/// Domain models for the Loop-style HUD. Terminology mirrors Loop (IOB = "Active Insulin",
/// COB = "Active Carbohydrates"), but ControlX2 is a manual remote-bolus + status viewer, NOT
/// an automated closed loop. Glucose is in mg/dL.

public struct GlucoseReading: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let date: Date
    public let mgdl: Int
    public init(date: Date, mgdl: Int) { self.date = date; self.mgdl = mgdl }
}

public enum GlucoseTrend: String, Sendable {
    case flat = "→", up = "↑", down = "↓", upUp = "⇈", downDown = "⇊"
    case rising = "↗", falling = "↘"
}

/// Loop-style glucose ranges for coloring.
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

/// Connection/activity status shown by the HUD ring (adapted from Loop's loop-status ring —
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
    public var trend: String = GlucoseTrend.flat.rawValue
    public var iobUnits: Double = 0          // Active Insulin
    public var cobGrams: Double = 0          // Active Carbohydrates
    public var reservoirUnits: Double = 0
    public var batteryPercent: Int = 0
    public var cgmActive: Bool = false
    public var lastBolusUnits: Double? = nil
    public var lastBolusDate: Date? = nil
    public init() {}
}

/// A bolus the user is about to confirm (Loop-style: carbs + BG → recommended units).
public struct BolusRecommendation: Sendable, Equatable {
    public var carbsGrams: Double = 0
    public var bgMgdl: Int? = nil
    public var recommendedUnits: Double = 0
    public var iobUnits: Double = 0
    public init() {}
}
