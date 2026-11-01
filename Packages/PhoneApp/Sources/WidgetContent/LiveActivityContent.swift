import Foundation
import faBolusCore

/// The user's Live Activity layout. Baked into each update, so the Live Activity's views never read the
/// App Group themselves.
public struct LiveActivityLayout: Codable, Sendable, Hashable {
    public enum Style: String, Codable, Sendable, CaseIterable {
        /// A zone-coloured glucose curve filling the Lock Screen card.
        case fullBleed
        /// The glucose number with a row of chips.
        case classic
    }

    public var style: Style
    /// The chosen fields, in order (`LiveActivityField`).
    public var fields: [LiveActivityField]
    public var topRight: LiveActivityTopRight
    /// How many hours the curve spans.
    public var plotRangeHours: Int
    public var plotFloorMgdl: Int
    public var plotCeilingMgdl: Int
    public var showXAxisLine: Bool
    public var showYAxisLine: Bool
    public var showXAxisTicks: Bool
    public var showYAxisTicks: Bool
    public var showRangeLines: Bool
    /// A "Bolus" pill that opens the app's bolus screen. Navigation only: nothing is sent from it.
    public var showBolusShortcut: Bool

    public init(
        style: Style = .fullBleed, fields: [LiveActivityField] = LiveActivityField.defaults,
        topRight: LiveActivityTopRight = .iobDelta, plotRangeHours: Int = 2,
        plotFloorMgdl: Int = GlucosePlotScale.defaultFloor, plotCeilingMgdl: Int = GlucosePlotScale.defaultCeiling,
        showXAxisLine: Bool = false, showYAxisLine: Bool = false, showXAxisTicks: Bool = false,
        showYAxisTicks: Bool = false, showRangeLines: Bool = false, showBolusShortcut: Bool = false
    ) {
        self.style = style
        self.fields = fields
        self.topRight = topRight
        self.plotRangeHours = plotRangeHours
        self.plotFloorMgdl = plotFloorMgdl
        self.plotCeilingMgdl = plotCeilingMgdl
        self.showXAxisLine = showXAxisLine
        self.showYAxisLine = showYAxisLine
        self.showXAxisTicks = showXAxisTicks
        self.showYAxisTicks = showYAxisTicks
        self.showRangeLines = showRangeLines
        self.showBolusShortcut = showBolusShortcut
    }

    public static let plotRangeOptions = [1, 2, 3, 4, 6]
}

/// A value the Live Activity can show.
public enum LiveActivityField: String, Codable, Sendable, CaseIterable {
    case glucose, iob, reservoir, battery, basal, controlIQ, lastAutoCorrection, connection, delta, tir

    public static let defaults: [LiveActivityField] = [.glucose, .iob, .reservoir, .battery]

    public var label: String {
        switch self {
        case .glucose: return "Glucose"
        case .iob: return "Active insulin"
        case .reservoir: return "Reservoir"
        case .battery: return "Battery"
        case .basal: return "Basal"
        case .controlIQ: return "Control-IQ"
        case .lastAutoCorrection: return "Last auto-correction"
        case .connection: return "Pump connection (when down)"
        case .delta: return "30-min change"
        case .tir: return "Time in range"
        }
    }
}

/// What the full-bleed style shows in its top-right corner.
public enum LiveActivityTopRight: String, Codable, Sendable, CaseIterable {
    case iobDelta, iob, delta, tir, battery, reservoir, none

    public var label: String {
        switch self {
        case .iobDelta: return "Active insulin and change"
        case .iob: return "Active insulin"
        case .delta: return "30-min change"
        case .tir: return "Time in range"
        case .battery: return "Battery"
        case .reservoir: return "Reservoir"
        case .none: return "Nothing"
        }
    }
}

/// One Live Activity update: the snapshot the widgets get (its points cut to the plot window) and the
/// layout. The views judge staleness at render time from the carried windows, and the update's stale date
/// makes the system re-render when the glucose goes stale, so a Live Activity whose updates stopped never
/// shows its last reading as current.
public struct LiveActivityContent: Codable, Sendable, Hashable {
    public var snapshot: WidgetSnapshot
    public var layout: LiveActivityLayout

    public init(snapshot: WidgetSnapshot, layout: LiveActivityLayout) {
        self.snapshot = snapshot
        self.layout = layout
    }

    /// ActivityKit's limit on one update's encoded content.
    public static let sizeLimit = 4096
    /// The most curve points one update carries, to stay under `sizeLimit`.
    public static let maxPoints = 36

    /// The update for `snapshot`, with the points inside the layout's window, thinned evenly.
    public static func make(from snapshot: WidgetSnapshot, layout: LiveActivityLayout, now: Date) -> LiveActivityContent
    {
        var trimmed = snapshot
        trimmed.recent = window(snapshot.recent, hours: layout.plotRangeHours, now: now, cap: maxPoints)
        return LiveActivityContent(snapshot: trimmed, layout: layout)
    }

    /// When this update stops being current: when its glucose goes stale (already past for a stale
    /// reading, so it shows stale at once), or with no glucose, when the first other value does. The
    /// system marks the Live Activity stale then, and the views grey it.
    public func staleDate(now: Date) -> Date? {
        guard let glucose = snapshot.glucose else { return snapshot.decayCrossings(asOf: now).first }
        guard glucose.age(now: now) != nil else { return now }
        return glucose.measuredAt.addingTimeInterval(snapshot.freshness.glucoseStaleAfter)
    }

    static func window(_ points: [WidgetSnapshot.Point], hours: Int, now: Date, cap: Int) -> [WidgetSnapshot.Point] {
        let start = now.addingTimeInterval(-Double(max(hours, 1)) * 3600)
        let windowed = points.filter { $0.t >= start && $0.t <= now }
        guard windowed.count > cap, cap > 1 else { return windowed }
        let last = windowed.count - 1
        let step = Double(last) / Double(cap - 1)
        return (0..<cap).map { windowed[min(last, Int((Double($0) * step).rounded()))] }
    }
}

/// Display math the Live Activity's corner and chips use.
public enum LiveActivityMetrics {
    /// The change over the last 30 minutes, from the reading nearest 30 minutes before the newest. `nil`
    /// with less than 10 minutes of points or when the newest is more than 10 minutes old.
    public static func delta(_ points: [WidgetSnapshot.Point], now: Date) -> Int? {
        guard let first = points.first, let last = points.last, last.t.timeIntervalSince(first.t) >= 10 * 60,
            now.timeIntervalSince(last.t) <= 10 * 60
        else { return nil }
        let target = last.t.addingTimeInterval(-30 * 60)
        guard
            let nearest = points.min(by: { abs($0.t.timeIntervalSince(target)) < abs($1.t.timeIntervalSince(target)) })
        else { return nil }
        return last.mgdl - nearest.mgdl
    }

    public static func deltaText(_ points: [WidgetSnapshot.Point], unit: GlucoseUnit, now: Date) -> String? {
        guard let d = delta(points, now: now) else { return nil }
        return "\(d > 0 ? "+" : d < 0 ? "−" : "±")\(unit.format(mgdl: abs(d))) 30m"
    }

    /// Percent of `points` in 70–180 mg/dL; `nil` with none.
    public static func timeInRange(_ points: [WidgetSnapshot.Point]) -> Int? {
        guard !points.isEmpty else { return nil }
        let inRange = points.filter { $0.mgdl >= GlucoseThresholds.low && $0.mgdl <= GlucoseThresholds.high }.count
        return Int((Double(inRange) / Double(points.count) * 100).rounded())
    }

    /// "now", "4m", "2h".
    public static func shortAge(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date))) / 60
        if minutes < 1 { return "now" }
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
    }
}
