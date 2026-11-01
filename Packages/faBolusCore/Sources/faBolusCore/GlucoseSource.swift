import Foundation

/// Glucose freshness, shared by the pump's reading and every independent `GlucoseSource`, so the primary
/// and its failover agree on "stale". The windows come from `FreshnessThresholds`, passed in by the caller.
/// Old readings are worse than none, so anything past the window is never presented as the current value.
public enum GlucoseFreshness {
    /// A reading dated more than this ahead of `now` came from a source with a fast clock. Its real age
    /// can't be known, so it is stale rather than current; without this a negative age would never age
    /// out. Small enough to tolerate ordinary phone↔sensor jitter. LoopKit also rejects future glucose.
    public static let futureSkewTolerance: TimeInterval = 5 * 60

    /// Age of a reading taken at `date` (never negative).
    public static func age(of date: Date, now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(date))
    }

    /// True when a reading taken at `date` is older than the glucose window. A nil date is stale, and so
    /// is one dated more than `futureSkewTolerance` in the future, and every reading is stale under a
    /// window that isn't a finite, non-negative number.
    public static func isStale(_ date: Date?, thresholds: FreshnessThresholds, now: Date = Date()) -> Bool {
        CalcInputFreshness.isStale(date, staleAfter: thresholds.glucoseStaleAfter, now: now)
    }

    /// True when a reading taken at `date` is stale yet no older than `maxIncludableGlucoseAge`: the only
    /// window in which the user may include a stale reading in a correction. A fresh, missing or
    /// future-dated reading is outside it.
    public static func withinIncludableStaleness(
        _ date: Date?, thresholds: FreshnessThresholds, now: Date = Date()
    ) -> Bool {
        guard let date, thresholds.maxIncludableGlucoseAge.isFinite else { return false }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < -futureSkewTolerance { return false }
        return isStale(date, thresholds: thresholds, now: now) && elapsed <= thresholds.maxIncludableGlucoseAge
    }

    /// How a reading of a given age should be presented on screen.
    public static func presentation(
        of date: Date?, thresholds: FreshnessThresholds, now: Date = Date()
    ) -> GlucosePresentation {
        guard let date else { return .stale }
        let age = now.timeIntervalSince(date)
        if !isStale(date, thresholds: thresholds, now: now) { return .fresh }
        if age < -futureSkewTolerance { return .stale }
        if let hide = thresholds.glucoseHideAfter, age >= Swift.max(hide, thresholds.glucoseStaleAfter) {
            return .hidden
        }
        return .stale
    }

    /// Compact relative age label for a reading taken at `date`, e.g. "now", "3 min ago", "1h 12m ago".
    /// A reading dated beyond `futureSkewTolerance` in the future says "clock ahead" rather than "now".
    public static func ageLabel(for date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < -futureSkewTolerance { return "clock ahead" }
        let s = Int(age(of: date, now: now))
        if s < 30 { return "now" }
        if s < 3600 { return "\(max(1, s / 60)) min ago" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h)h ago" : "\(h)h \(m)m ago"
    }
}

/// How a glucose reading should be shown, by age (see `GlucoseFreshness.presentation`).
public enum GlucosePresentation: Sendable, Equatable {
    case fresh  // within glucoseStaleAfter — normal styling, live value
    case stale  // past glucoseStaleAfter — shown de-emphasized (grey) with its age
    case hidden  // past glucoseHideAfter — not shown ("--")
}

/// One glucose reading from an independent CGM source (i.e. not relayed by the pump). mg/dL.
public struct GlucoseSample: Sendable, Equatable {
    public let mgdl: Int
    public let date: Date
    /// The trend **as reported by the source**, or `nil` when the source does not report one.
    ///
    /// faBolus never calculates a trend arrow, and "no trend available" must render as *no arrow*
    /// rather than a flat one. This defaulted to `.flat`, so every source without a trend — HealthKit
    /// among them — silently published "steady", an inferred clinical signal dressed as a reported one.
    public let trend: GlucoseTrend?
    /// Stable id of the source that produced it (matches its `GlucoseSourceDescriptor.id`).
    public let sourceID: String
    /// Shared plausibility gate: FAILS (returns `nil`) for a value outside the physiologic range
    /// `[GlucosePlausibility.minimum, .maximum]` — REJECT, not clamp (clamping is fail-open, silently
    /// substituting a dose input). This is the only initializer, so every `GlucoseSource` is forced
    /// through the gate at construction: no source's `latest` or `history` can ever hold an implausible
    /// value, and the Test-flow UI (which reads `source.latest` directly, bypassing the arbiter) cannot
    /// render garbage as a Test "success". `GlucoseReading` (shared with the pump's own ungated history)
    /// is deliberately not gated — only `GlucoseSample`, the failover-only type.
    public init?(mgdl: Int, date: Date, trend: GlucoseTrend? = nil, sourceID: String) {
        guard GlucosePlausibility.isPlausible(mgdl: mgdl) else { return nil }
        self.mgdl = mgdl
        self.date = date
        self.trend = trend
        self.sourceID = sourceID
    }
    public var reading: GlucoseReading { GlucoseReading(date: date, mgdl: mgdl) }
    public func isStale(thresholds: FreshnessThresholds, now: Date = Date()) -> Bool {
        GlucoseFreshness.isStale(date, thresholds: thresholds, now: now)
    }
}

/// How a `GlucoseSource` physically connects — a typed classification later waves branch on instead
/// of scattered `id == "dexcom-g6-ble" || id == "dexcom-g7-ble"` string literals. Lives on the
/// protocol only (mirroring `priority`'s placement), so a new source is forced to classify itself —
/// there is deliberately no protocol extension default a new BLE source could silently inherit.
public enum GlucoseConnectionKind: Sendable, Equatable {
    case localBLE  // Dexcom G6 / G7 — CoreBluetooth passive read
    case cloudPoll  // Dexcom Share / Nightscout / LibreLinkUp — polled over the network
    case localOnDevice  // HealthKit / xDrip App Group — on-device, no BLE, no network
}

/// Health of a `GlucoseSource`, so the UI can show what the failover feed is doing.
public enum GlucoseSourceStatus: Sendable, Equatable {
    case idle  // not started
    case needsSetup  // missing credentials / not paired
    case searching  // starting / scanning / logging in
    case connected  // receiving fresh data
    case stale  // connected but the latest reading is old
    case unavailable(GlucoseSourceProblem)  // not reading, and why
}

/// What a glucose source reports right now.
public struct GlucoseSourceState: Sendable, Equatable {
    /// Most recent reading, or nil if none yet.
    public var latest: GlucoseSample?
    /// Recent history (newest last), to backfill the chart when failing over.
    public var history: [GlucoseReading]
    public var status: GlucoseSourceStatus
    /// Measurement time of the newest reading below the sensor's measurable range (Dexcom "LOW", under
    /// 40 mg/dL). `GlucoseSample` rejects such a value, so it can never be `latest` or fill a
    /// correction; the urgent-low alarm reads this instead.
    public var belowRangeAt: Date?
    public init(
        latest: GlucoseSample?, history: [GlucoseReading] = [], status: GlucoseSourceStatus,
        belowRangeAt: Date? = nil
    ) {
        self.latest = latest
        self.history = history
        self.status = status
        self.belowRangeAt = belowRangeAt
    }
}

/// The **glucose source** seam — an independent CGM feed used as a failover when the pump-relayed
/// glucose goes stale (pump↔phone, watch↔phone, or pump↔sensor drops), mirroring LoopKit's
/// `CGMManager`. Sources are **read-only** and must never displace the pump or the official vendor app.
///
/// Not tied to the main actor: a source runs wherever its Bluetooth or network work runs (an actor
/// is the natural conformer) and is read through `state` and `updates()`.
///
/// **To add a CGM source:** conform a new type to this protocol, then add a `GlucoseSourceDescriptor`
/// for it to `GlucoseSourceRegistry` (in the `GlucoseSources` package). `GlucoseArbiter` handles failover.
public protocol GlucoseSource: AnyObject, Sendable {
    /// Stable id (matches its `GlucoseSourceDescriptor.id`), stamped onto every `GlucoseSample`.
    var id: String { get }
    /// Selection priority when several sources are healthy (higher wins). Local BLE outranks cloud.
    var priority: Int { get }
    /// Typed connection classification — Test-flow/copy logic branches on this instead of `id`-string
    /// literals. No extension default: every source must classify itself.
    var connectionKind: GlucoseConnectionKind { get }
    /// The latest reading, history and status.
    var state: GlucoseSourceState { get async }
    /// Every later change to `state`. Each call returns its own stream.
    func updates() async -> AsyncStream<GlucoseSourceState>
    func start() async
    func stop() async
    /// Tell the source whether the PRIMARY (pump) feed is currently healthy, so it can throttle its
    /// work. Cloud pollers poll lazily while the primary is healthy and ramp up when it goes stale;
    /// local BLE sources ignore this and run continuously for instant failover.
    func setPrimaryHealthy(_ healthy: Bool) async
}
