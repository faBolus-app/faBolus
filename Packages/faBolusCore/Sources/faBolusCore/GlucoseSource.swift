import Foundation
import os

/// Freshness policy shared by **every** glucose feed — the pump-relayed reading and any independent
/// `GlucoseSource`. One definition of "stale" so the primary and its failover agree. Adjustable at
/// runtime (e.g. from Settings); default 6 minutes. Old readings are worse than none, so anything
/// past this threshold is never presented as the current value.
public enum GlucoseFreshness {
    // Thread-safe backing (audit A-09): these are set at launch (e.g. from Settings) and read from many
    // isolation domains. An `OSAllocatedUnfairLock` gives a genuinely-safe shared store instead of a
    // `nonisolated(unsafe) static var` (which only silences the checker).
    private static let _staleAfter = OSAllocatedUnfairLock<TimeInterval>(initialState: 6 * 60)
    private static let _hideAfter = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

    /// Readings older than this are **stale**: shown de-emphasized ("grey") and — critically — no
    /// longer used to auto-fill a bolus carb→unit correction. Default 6 minutes; open for adjustment.
    public static var staleAfter: TimeInterval {
        get { _staleAfter.withLock { $0 } }
        set { _staleAfter.withLock { $0 = newValue } }
    }

    /// Age past which a reading is **hidden** ("--") instead of shown grey. `nil` = never hide (always
    /// show the grey value once stale). Set equal to `staleAfter` to skip the grey stage entirely
    /// (go straight from fresh to "--"). Effective value is clamped to ≥ `staleAfter`.
    public static var hideAfter: TimeInterval? {
        get { _hideAfter.withLock { $0 } }
        set { _hideAfter.withLock { $0 = newValue } }
    }

    /// Age of a reading taken at `date` (never negative).
    public static func age(of date: Date, now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(date))
    }

    /// True when a reading taken at `date` is older than the threshold. A nil date → stale.
    public static func isStale(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return true }
        return now.timeIntervalSince(date) > staleAfter
    }

    /// How a reading of a given age should be presented on screen.
    public static func presentation(of date: Date?, now: Date = Date()) -> GlucosePresentation {
        guard let date else { return .stale }          // unknown age → conservative (marked, shown)
        let age = now.timeIntervalSince(date)
        if age <= staleAfter { return .fresh }
        if let hide = hideAfter, age >= Swift.max(hide, staleAfter) { return .hidden }
        return .stale
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

/// How a glucose reading should be shown, by age (see `GlucoseFreshness.presentation`).
public enum GlucosePresentation: Sendable, Equatable {
    case fresh      // within staleAfter — normal styling, live value
    case stale      // past staleAfter — shown de-emphasized (grey) with its age
    case hidden     // past hideAfter — not shown ("--")
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
///
/// **To add a CGM source:** conform a new type to this protocol, then add a `GlucoseSourceDescriptor`
/// for it to `GlucoseSourceRegistry.enabled` (in the app target). `GlucoseArbiter` handles failover.
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
    /// Tell the source whether the PRIMARY (pump) feed is currently healthy, so it can throttle its
    /// work. Cloud pollers poll lazily while the primary is healthy and ramp up when it goes stale;
    /// local BLE sources ignore this and run continuously for instant failover. Default: no-op.
    func setPrimaryHealthy(_ healthy: Bool)
    /// Called whenever `latest`/`status` change so the app can re-arbitrate promptly.
    var onChange: (@MainActor () -> Void)? { get set }
}

public extension GlucoseSource {
    func setPrimaryHealthy(_ healthy: Bool) {}
}
