//  GlucoseLimits.swift — mirrors LoopKit/G7SensorKit's GlucoseLimits (MIT, D-01) so DexcomG6Kit and
//  G7SensorKit share one notion of "physiologically plausible glucose" (Don't-Hand-Roll) rather than
//  each vendored kit inventing its own range constant.
import Foundation

public enum GlucoseLimits {
    public static let minimum: UInt16 = 40
    public static let maximum: UInt16 = 400
}
