import SwiftUI
import faBolusCore

/// modern semantic palette. Green = in range, yellow/orange = high, red = urgent/low,
/// purple accents for insulin. (Visual language only — FaBolus does not automate dosing.)
public enum AppTheme {
    public static let inRange = Color(red: 0.30, green: 0.78, blue: 0.36)   // green
    public static let high = Color(red: 0.98, green: 0.76, blue: 0.18)      // yellow
    public static let urgentHigh = Color(red: 0.95, green: 0.55, blue: 0.15) // orange
    public static let low = Color(red: 0.90, green: 0.25, blue: 0.22)       // red
    public static let insulin = Color(red: 0.36, green: 0.42, blue: 0.90)   // indigo
    public static let carbs = Color(red: 0.95, green: 0.62, blue: 0.20)     // carb orange
    public static let disconnected = Color.gray
    public static let stale = Color.gray                                    // de-emphasized old reading

    public static func glucoseColor(_ mgdl: Int) -> Color {
        switch GlucoseRange.classify(mgdl) {
        case .low: return low
        case .inRange: return inRange
        case .high: return high
        case .urgentHigh: return urgentHigh
        }
    }

    /// Glucose color, de-emphasized to `stale` gray when the reading is old — old values must read
    /// as "not current" at a glance, never as a live in-range/high/low number.
    public static func glucoseColor(_ mgdl: Int, stale: Bool) -> Color {
        stale ? self.stale : glucoseColor(mgdl)
    }

    public static func ringColor(_ state: PumpConnectionState) -> Color {
        switch state {
        case .connected: return inRange
        case .bolusing: return insulin
        case .scanning, .connecting: return high
        case .disconnected: return disconnected
        case .error: return low
        }
    }
}
