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
        /// One short row: glucose, its age, two fields and the bolus and alert row. The Mac shows the same
        /// card when its menu-bar pill is clicked.
        case slim
    }

    public var style: Style
    /// The chosen fields, in order (`LiveActivityField`).
    public var fields: [LiveActivityField]
    public var topRight: LiveActivityTopRight
    /// How many hours the curve spans.
    public var plotRangeHours: Int
    public var showXAxisLine: Bool
    public var showYAxisLine: Bool
    public var showXAxisTicks: Bool
    public var showYAxisTicks: Bool
    public var showRangeLines: Bool
    /// What the compact view shows beside the glucose: in the Dynamic Island and the Mac's menu bar. `nil`
    /// is the trend arrow; optional so a layout saved before it existed still reads.
    public var compact: LiveActivityCompact?

    public init(
        style: Style = .fullBleed, fields: [LiveActivityField] = LiveActivityField.defaults,
        topRight: LiveActivityTopRight = .iobDelta, plotRangeHours: Int = 3,
        showXAxisLine: Bool = false, showYAxisLine: Bool = false, showXAxisTicks: Bool = false,
        showYAxisTicks: Bool = false, showRangeLines: Bool = false, compact: LiveActivityCompact? = nil
    ) {
        self.style = style
        self.fields = fields
        self.topRight = topRight
        self.plotRangeHours = plotRangeHours
        self.showXAxisLine = showXAxisLine
        self.showYAxisLine = showYAxisLine
        self.showXAxisTicks = showXAxisTicks
        self.showYAxisTicks = showYAxisTicks
        self.showRangeLines = showRangeLines
        self.compact = compact
    }

    public static let plotRangeOptions = [3, 6, 8]

    /// A span from before these options, made one of them: the nearest, the shorter on a tie.
    public static func plotRange(_ hours: Int) -> Int {
        plotRangeOptions.min { abs($0 - hours) < abs($1 - hours) } ?? plotRangeOptions[0]
    }
}

/// A value the Live Activity can show.
public enum LiveActivityField: String, Codable, Sendable, CaseIterable {
    case glucose, iob, reservoir, battery, basal, controlIQ, lastAutoCorrection, connection, delta, tir, lastBolus

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
        case .lastBolus: return "Last bolus"
        }
    }
}

/// What the compact view shows beside the glucose. A Live Activity bolus going or just finished shows
/// instead, whatever the choice.
public enum LiveActivityCompact: String, Codable, Sendable, CaseIterable {
    case arrow, delta, iob

    public var label: String {
        switch self {
        case .arrow: return "Trend arrow"
        case .delta: return "30-min change"
        case .iob: return "Active insulin"
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
    /// The bolus and alert controls; `nil` draws the card alone.
    public var panel: LiveActivityPanel?
    /// The pump alerts the card's row shows; `nil` when there are none.
    public var alerts: LiveActivityAlerts?

    public init(
        snapshot: WidgetSnapshot, layout: LiveActivityLayout, panel: LiveActivityPanel? = nil,
        alerts: LiveActivityAlerts? = nil
    ) {
        self.snapshot = snapshot
        self.layout = layout
        self.panel = panel
        self.alerts = alerts
    }

    /// ActivityKit's limit on one update's encoded content.
    public static let sizeLimit = 4096
    /// The most curve points one update carries, to stay under `sizeLimit`.
    public static let maxPoints = 36

    /// The update for `snapshot`, with the points inside the layout's window, thinned evenly.
    public static func make(
        from snapshot: WidgetSnapshot, layout: LiveActivityLayout, panel: LiveActivityPanel? = nil,
        alerts: LiveActivityAlerts? = nil, now: Date
    ) -> LiveActivityContent {
        var trimmed = snapshot
        trimmed.recent = window(snapshot.recent, hours: layout.plotRangeHours, now: now, cap: maxPoints)
        return LiveActivityContent(snapshot: trimmed, layout: layout, panel: panel, alerts: alerts)
    }

    /// When this update stops being current: the first moment any value it shows passes its window, or the
    /// app has stopped publishing long enough that the pump link can't be believed (already past for a
    /// stale reading, so it shows stale at once). The system re-renders and marks the Live Activity stale
    /// then, the only render it gets while the app isn't running, so a value like IOB, whose window is
    /// shorter than glucose's, is never shown current past it.
    public func staleDate(now: Date) -> Date? {
        if let glucose = snapshot.glucose {
            guard glucose.age(now: now) != nil else { return now }
            let glucoseStale = glucose.measuredAt.addingTimeInterval(snapshot.freshness.glucoseStaleAfter)
            if glucoseStale <= now { return glucoseStale }
        }
        let publisherStale = snapshot.publishedAt.addingTimeInterval(WidgetSnapshot.publisherStaleAfter)
        return (snapshot.decayCrossings(asOf: now) + [publisherStale]).min()
    }

    /// The readings the 30-minute change is worked out from, kept whole however long the span.
    static let wholeRecent: TimeInterval = 35 * 60

    /// The points in the window, at most `cap`, oldest first: the newest `wholeRecent` whole (thinned only
    /// when readings come more often than every few minutes, always keeping the one 30 minutes before the
    /// newest), and the older ones thinned evenly into the room left.
    static func window(_ points: [WidgetSnapshot.Point], hours: Int, now: Date, cap: Int) -> [WidgetSnapshot.Point] {
        let start = now.addingTimeInterval(-Double(max(hours, 1)) * 3600)
        let windowed = points.filter { $0.t >= start && $0.t <= now }
        guard windowed.count > cap, cap > 1 else { return windowed }
        let cut = now.addingTimeInterval(-wholeRecent)
        var recent = windowed.filter { $0.t >= cut }
        if recent.count > cap / 2, let newest = recent.last {
            let target = newest.t.addingTimeInterval(-30 * 60)
            let back = recent.min { abs($0.t.timeIntervalSince(target)) < abs($1.t.timeIntervalSince(target)) }
            recent = Set(evenly(recent, cap / 2 - 1) + [back].compactMap { $0 }).sorted { $0.t < $1.t }
        }
        return evenly(windowed.filter { $0.t < cut }, cap - recent.count) + recent
    }

    /// `n` of `points` evenly spread, the first and last among them; all of them when there are no more.
    static func evenly(_ points: [WidgetSnapshot.Point], _ n: Int) -> [WidgetSnapshot.Point] {
        guard points.count > n else { return points }
        guard n > 1 else { return n == 1 ? [points[points.count - 1]] : [] }
        let last = points.count - 1
        let step = Double(last) / Double(n - 1)
        return (0..<n).map { points[min(last, Int((Double($0) * step).rounded()))] }
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
