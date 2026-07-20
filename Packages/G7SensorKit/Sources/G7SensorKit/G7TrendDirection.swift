//  G7TrendDirection.swift — LoopKit-free replacement for the `LoopKit.GlucoseTrend` mapping the
//  vendored decoders used. The app maps this to `faBolusCore.GlucoseTrend`.
import Foundation

public enum G7TrendDirection: Sendable, Equatable {
    case downDownDown, downDown, down, flat, up, upUp, upUpUp

    /// Map the sensor's signed trend rate (mg/dL/min) to a direction, matching G7SensorKit.
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
