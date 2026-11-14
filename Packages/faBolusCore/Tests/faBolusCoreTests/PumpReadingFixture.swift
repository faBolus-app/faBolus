import Foundation

@testable import faBolusCore

extension PumpState {
    /// The pump's CGM reading as a test sets it: the home-screen reading and the one the calculator reply
    /// carries, which a pump reports together. A reading from another source sets only `glucose`.
    var cgm: Observed<PumpGlucose>? {
        get { glucose }
        set {
            glucose = newValue
            guard newValue?.source ?? .pump == .pump else { return }
            bolusCalculator?.value.reading = newValue.map {
                .init(mgdl: $0.value.mgdl, measuredAt: $0.measuredAt, outOfRange: $0.value.outOfRange)
            }
        }
    }
}
