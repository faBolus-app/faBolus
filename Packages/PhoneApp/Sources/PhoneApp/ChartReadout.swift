import Foundation
import faBolusCore

/// The values the chart's scrub readout shows at a touched time: glucose, IOB and a bolus near it, each
/// `nil` (shown "—") when no sample is close enough. Display only; nothing here is a dose input.
public struct ChartReadout: Sendable, Equatable {
    public let date: Date
    public let glucoseMgdl: Int?
    public let iob: Double?
    public let bolusUnits: Double?

    /// Glucose and IOB samples within 6 minutes count; boluses, which are sparse, within 10.
    public static let tolerance: TimeInterval = 6 * 60
    public static let bolusTolerance: TimeInterval = 10 * 60

    public init(at date: Date, glucose: [GlucoseReading], iob: [IOBSample], boluses: [BolusMarker]) {
        self.date = date
        glucoseMgdl = Self.nearest(to: date, in: glucose, key: \.date, within: Self.tolerance)?.mgdl
        self.iob = Self.nearest(to: date, in: iob, key: \.date, within: Self.tolerance)?.iob
        bolusUnits = Self.nearest(to: date, in: boluses, key: \.date, within: Self.bolusTolerance)?.units
    }

    /// The sample closest to `date` within `tolerance` (inclusive); of two equally close, the earlier, so a
    /// scrub never flickers between them.
    public static func nearest<T>(to date: Date, in samples: [T], key: KeyPath<T, Date>, within tolerance: TimeInterval)
        -> T?
    {
        var best: (sample: T, delta: TimeInterval, date: Date)?
        for sample in samples {
            let d = sample[keyPath: key]
            let delta = abs(d.timeIntervalSince(date))
            if best.map({ delta < $0.delta || (delta == $0.delta && d < $0.date) }) ?? true {
                best = (sample, delta, d)
            }
        }
        guard let best, best.delta <= tolerance else { return nil }
        return best.sample
    }

    /// What VoiceOver reads for the readout; a missing value is "no reading", not a dash. Glucose carries
    /// its range word, so the band the chart shows by colour is heard too (`GlucoseRange.shortLabel`, as
    /// the widgets say it).
    public func spoken(unit: GlucoseUnit) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let g =
            glucoseMgdl.map { "\(unit.format(mgdl: $0)) mg/dL, \(GlucoseRange.classify($0).shortLabel)" }
            ?? "no reading"
        let i = iob.map { String(format: "%.2f units", $0) } ?? "no value"
        let b = bolusUnits.map { String(format: "%.2f units", $0) } ?? "none"
        return "At \(time): glucose \(g), active insulin \(i), bolus \(b)"
    }
}
