//  G6TrendDirection.swift — LoopKit-free trend mapping (the app maps it to faBolusCore.GlucoseTrend).
import Foundation

public enum G6TrendDirection: Sendable, Equatable {
    case downDownDown, downDown, down, flat, up, upUp, upUpUp

    /// Map a signed trend rate (mg/dL/min) to a direction (same buckets as G7SensorKit).
    public init?(rate: Double?) {
        guard let rate else { return nil }
        switch rate {
        case let x where x <= -3.0: self = .downDownDown
        case let x where x <= -2.0: self = .downDown
        case let x where x <= -1.0: self = .down
        case let x where x <   1.0: self = .flat
        case let x where x <   2.0: self = .up
        case let x where x <   3.0: self = .upUp
        default: self = .upUpUp
        }
    }
}
