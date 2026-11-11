import Foundation

/// The glucose the bolus calculator corrects from, typed or from the pump's CGM: 20 to 600 mg/dL, both
/// ends inclusive, the range Mobi takes a typed BG and fills in a CGM reading from (the owner's choice).
/// A glucose outside it is invalid: a calculated dose is refused rather than sized without it.
///
/// Not the sanity gate on a backup CGM's samples (`GlucosePlausibility`, 40-400 mg/dL as the CGM kits
/// report), which drops a garbled reading before it is stored.
public enum CalculatorGlucose {
    public static let minimum = 20
    public static let maximum = 600
    public static func isValid(mgdl: Int) -> Bool { mgdl >= minimum && mgdl <= maximum }
}
