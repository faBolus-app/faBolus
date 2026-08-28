import Foundation
import faBolusCore

/// A below-measurable-range vendor reading (e.g. a Dexcom "LOW" result under 40 mg/dL) detected at the
/// CGM ingest boundary. Advisory/display-only — deliberately NOT a `GlucoseSample`: the plausibility
/// gate (`GlucoseSample.init?`, `[GlucosePlausibility.minimum, .maximum]` = [40, 400]) still rejects
/// the raw value exactly as before, so it can never reach `latest`, `GlucoseArbiter.merge`,
/// `PumpSnapshot.glucose`, or `AppModel.freshCorrectionBG` (the frozen dose path). This type only
/// carries the fact that an urgent-low reading was seen, for a display/alert layer to read.
struct UrgentLowSentinel: Sendable, Equatable {
    let date: Date
    let sourceID: String
}

/// Base class for cloud follower sources (Nightscout, LibreLinkUp, Dexcom Share). Handles the poll
/// loop, `latest`/`history`/`status`, and change notification; subclasses implement `poll()` to fetch
/// readings and return them newest-last. Read-only — these never write to the sensor or the pump.
@MainActor
class PollingGlucoseSource: GlucoseSource {
    let id: String
    let priority: Int
    /// Cloud pollers (Dexcom Share / Nightscout / LibreLinkUp) inherit this classification.
    let connectionKind: GlucoseConnectionKind = .cloudPoll
    private(set) var latest: GlucoseSample?
    private(set) var history: [GlucoseReading] = []
    private(set) var status: GlucoseSourceStatus = .idle
    /// The most recent below-measurable-range vendor reading seen at ingest, or nil. See
    /// `UrgentLowSentinel` — this is a SEPARATE typed value, never a `GlucoseSample`.
    private(set) var urgentLowSentinel: UrgentLowSentinel?
    var onChange: (@MainActor () -> Void)?

    /// Poll cadences (seconds). Battery-aware: while the pump feed is healthy we poll rarely
    /// (`idleInterval`) just to keep a warm value; once it goes stale we ramp to `activeInterval`
    /// and poll immediately, since the cloud feed is now the live source.
    let activeInterval: TimeInterval
    let idleInterval: TimeInterval
    private var task: Task<Void, Never>?
    private var started = false
    private var primaryHealthy = false

    /// Exponential backoff on consecutive poll failures. A sustained outage or credential
    /// problem must NOT keep re-hitting the endpoint at the fixed `activeInterval` (as often as every
    /// 60s during failover) — for Dexcom Share that is the self-inflicted `SSO_Authenticate` lockout
    /// risk at the exact moment failover is needed. The retry cadence widens with each consecutive
    /// failure (capped) and resets on the first success. Generalized here so every cloud poller
    /// inherits it, not just Dexcom Share.
    private(set) var consecutiveFailures = 0

    /// Cap the widening so the retry interval can't grow unbounded (e.g. 60s base → at most 8×).
    static let maxBackoffMultiplier = 8

    /// Update the consecutive-failure counter that drives backoff. Extracted so a test can assert the
    /// widen-on-failure / reset-on-success behavior without a live poll loop.
    func recordPollOutcome(success: Bool) {
        consecutiveFailures = success ? 0 : consecutiveFailures + 1
    }

    /// The effective wait before the next poll: the base cadence widened by `2^failures` (capped at
    /// `maxBackoffMultiplier`). Pure so a test can assert the widening directly. `failures == 0` leaves
    /// the base cadence unchanged.
    func effectiveInterval(base: TimeInterval, failures: Int) -> TimeInterval {
        let mult = min(Self.maxBackoffMultiplier, 1 << min(max(failures, 0), 20))
        return base * Double(mult)
    }

    init(id: String, priority: Int, activeInterval: TimeInterval = 60, idleInterval: TimeInterval = 600) {
        self.id = id; self.priority = priority
        self.activeInterval = activeInterval; self.idleInterval = idleInterval
    }

    func start() async {
        guard !started else { return }
        started = true
        status = .searching; onChange?()
        restartLoop(pollNow: true)
    }

    func stop() {
        started = false
        task?.cancel(); task = nil
        status = .idle; onChange?()
    }

    /// Ramp up (poll now + fast cadence) when the primary goes stale; back off to the idle cadence
    /// when it recovers. No-op until the source has been started.
    func setPrimaryHealthy(_ healthy: Bool) {
        guard started, healthy != primaryHealthy else { return }
        primaryHealthy = healthy
        restartLoop(pollNow: !healthy)   // became stale → fetch immediately
    }

    private func restartLoop(pollNow: Bool) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            if pollNow { await self.tick() }
            while !Task.isCancelled {
                let base = self.primaryHealthy ? self.idleInterval : self.activeInterval
                // Widen the wait on consecutive failures so a broken/locked-out feed isn't
                // hammered at the fixed cadence; a success (below) resets `consecutiveFailures` to 0.
                let delay = self.effectiveInterval(base: base, failures: self.consecutiveFailures)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { break }
                await self.tick()
            }
        }
    }

    private func tick() async {
        do {
            let readings = try await poll()   // newest-last
            recordPollOutcome(success: true)   // a good poll resets the backoff
            ingest(readings)
        } catch SourceError.needsSetup {
            // A missing config is not an endpoint failure — don't widen the backoff for it.
            status = .needsSetup; onChange?()
        } catch let e {
            recordPollOutcome(success: false)   // repeated auth/fetch failure widens the cadence
            status = .error((e as? LocalizedError)?.errorDescription ?? "\(e)")
            onChange?()
        }
    }

    /// Subclass hook: fetch recent readings (newest-last). Throw `SourceError.needsSetup` if the
    /// provider isn't configured.
    func poll() async throws -> [GlucoseSample] { [] }

    /// Not `private` (matches `poll()`/`recordPollOutcome`/`effectiveInterval`'s existing testability
    /// pattern) so app-target hygiene tests can feed readings directly without a live poll loop.
    func ingest(_ readings: [GlucoseSample]) {
        guard let newest = readings.max(by: { $0.date < $1.date }) else {
            status = .stale; onChange?(); return
        }
        // Monotonic-by-timestamp — a late/stale poll must never step `latest` backward in time.
        // Only a STRICTLY newer timestamp replaces the currently-held reading; an older-or-equal
        // timestamp is ignored for `latest` (history below still merges the full poll either way).
        if latest == nil || newest.date > latest!.date {
            latest = newest
        }
        var byBucket: [Int: GlucoseReading] = [:]
        for r in history + readings.map(\.reading) {
            byBucket[Int(r.date.timeIntervalSince1970 / 300)] = r
        }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        history = byBucket.values.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        // Status must describe the reading actually HELD as `latest`, not a just-rejected
        // stale/late poll result — the monotonic guard above can now make these differ.
        status = (latest?.isStale ?? true) ? .stale : .connected
        onChange?()
    }

    /// Ingest-boundary: feed ONE raw vendor reading (mg/dL, not yet a `GlucoseSample`) through the
    /// [40, 400] plausibility gate. In-range → normal `ingest` path. Below range (< 40, a
    /// below-measurable-range / "LOW" vendor result) → the gate still rejects it exactly as before
    /// (never becomes `latest`/a dose input), but it is ALSO surfaced via `urgentLowSentinel` so a
    /// display/alert layer can react to a silently-dropped hypo. Above range (> 400, decode
    /// garbage) → no sentinel, unchanged silent-drop — only a below-range reading is a genuine
    /// safety signal worth surfacing.
    func ingestRawReading(mgdl: Int, date: Date) {
        if let sample = GlucoseSample(mgdl: mgdl, date: date, sourceID: id) {
            ingest([sample])
            return
        }
        guard mgdl < GlucosePlausibility.minimum else { return }
        urgentLowSentinel = UrgentLowSentinel(date: date, sourceID: id)
        onChange?()
    }
}

enum SourceError: LocalizedError {
    case needsSetup(String)
    case invalidConfig(String)
    case http(Int)
    case badResponse
    var errorDescription: String? {
        switch self {
        case .needsSetup(let s): return "\(s) not configured"
        case .invalidConfig(let s): return "\(s) is invalid — check settings"
        case .http(let c): return "HTTP \(c)"
        case .badResponse: return "Unexpected response"
        }
    }
}
