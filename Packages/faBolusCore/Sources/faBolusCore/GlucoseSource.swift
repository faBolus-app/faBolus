import Foundation

/// Freshness policy shared by **every** glucose feed — the pump-relayed reading and any independent
/// `GlucoseSource`. One definition of "stale" so the primary and its failover agree. Adjustable at
/// runtime (e.g. from Settings); default 6 minutes. Old readings are worse than none, so anything
/// past this threshold is never presented as the current value.
public enum GlucoseFreshness {
    /// Readings older than this are stale. Default 6 minutes; open for adjustment. Set once at
    /// launch (e.g. from Settings) before feeds start; reads are benign, hence `nonisolated(unsafe)`.
    public nonisolated(unsafe) static var staleAfter: TimeInterval = 6 * 60

    /// Age of a reading taken at `date` (never negative).
    public static func age(of date: Date, now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(date))
    }

    /// True when a reading taken at `date` is older than the threshold. A nil date → stale.
    public static func isStale(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return true }
        return now.timeIntervalSince(date) > staleAfter
    }

    /// Compact relative age label for a reading taken at `date`, e.g. "now", "3 min ago",
    /// "1h 12m ago". Shown next to every reading so its age is always visible.
    public static func ageLabel(for date: Date, now: Date = Date()) -> String {
        let s = Int(age(of: date, now: now))
        if s < 30 { return "now" }
        if s < 3600 { return "\(max(1, s / 60)) min ago" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h)h ago" : "\(h)h \(m)m ago"
    }
}

/// One glucose reading from an independent CGM source (i.e. not relayed by the pump). mg/dL.
public struct GlucoseSample: Sendable, Equatable {
    public let mgdl: Int
    public let date: Date
    public let trend: GlucoseTrend
    /// Stable id of the source that produced it (matches its `GlucoseSourceDescriptor.id`).
    public let sourceID: String
    public init(mgdl: Int, date: Date, trend: GlucoseTrend = .flat, sourceID: String) {
        self.mgdl = mgdl; self.date = date; self.trend = trend; self.sourceID = sourceID
    }
    public var reading: GlucoseReading { GlucoseReading(date: date, mgdl: mgdl) }
    /// Stale per the shared `GlucoseFreshness` policy.
    public var isStale: Bool { GlucoseFreshness.isStale(date) }
}

/// Health of a `GlucoseSource`, so the UI can show what the failover feed is doing.
public enum GlucoseSourceStatus: Sendable, Equatable {
    case idle            // not started
    case needsSetup      // missing credentials / not paired
    case searching       // starting / scanning / logging in
    case connected       // receiving fresh data
    case stale           // connected but the latest reading is old
    case error(String)
}

/// The **glucose source** seam — an independent CGM feed used as a failover when the pump-relayed
/// glucose goes stale (pump↔phone, watch↔phone, or pump↔sensor drops). Parallels `PumpBackend`
/// (async + `onChange`, the repo doesn't use Combine) and mirrors LoopKit's `CGMManager`. Sources are
/// **read-only** and must never displace the pump or the official vendor app.
@MainActor
public protocol GlucoseSource: AnyObject {
    /// Stable id (matches its `GlucoseSourceDescriptor.id`), stamped onto every `GlucoseSample`.
    var id: String { get }
    /// Selection priority when several sources are healthy (higher wins). Local BLE outranks cloud.
    var priority: Int { get }
    /// Most recent reading, or nil if none yet.
    var latest: GlucoseSample? { get }
    /// Recent history (newest last), to backfill the chart when failing over.
    var history: [GlucoseReading] { get }
    var status: GlucoseSourceStatus { get }
    func start() async
    func stop()
    /// Called whenever `latest`/`status` change so the app can re-arbitrate promptly.
    var onChange: (@MainActor () -> Void)? { get set }
}
