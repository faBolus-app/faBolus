// Adapted from LoopKit/LoopKit `a5beee96`: the round-down rule of
// `PumpManager.roundToSupportedBolusVolume` (DeviceManager/PumpManager.swift, © 2018 LoopKit Authors) and the
// decimal tolerance of `matchingOrTruncatedValue(from:withinDecimalPlaces:)` (Extensions/FloatingPoint.swift,
// © 2020 LoopKit Authors), MIT License.

import Foundation

/// The pump's bolus volumes: its smallest bolus and the step a calculated dose is rounded to.
public enum BolusVolume {
    /// The pump's minimum bolus, units.
    public static let minimumUnits = 0.05
    /// A calculated dose is a whole number of these steps.
    public static let stepUnits = 0.05
    private static let stepsPerUnit = 20.0

    /// A value this close to a step is that step, so binary error can't turn 2.30 U into 2.25 U.
    private static let tolerance = 1e-6

    /// The largest step that isn't above `units`, as LoopKit rounds a recommendation: never up, so a
    /// rounded dose is never more than the calculator's number. Zero for a non-finite or non-positive value.
    public static func roundedDown(_ units: Double) -> Double {
        guard units.isFinite, units > 0 else { return 0 }
        let steps = units * stepsPerUnit
        let nearest = steps.rounded()
        let whole = abs(nearest - steps) <= tolerance * stepsPerUnit ? nearest : steps.rounded(.down)
        return whole / stepsPerUnit
    }
}
