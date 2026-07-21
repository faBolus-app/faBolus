import Foundation
import faBolusCore

/// Base class for cloud follower sources (Nightscout, LibreLinkUp, Dexcom Share). Handles the poll
/// loop, `latest`/`history`/`status`, and change notification; subclasses implement `poll()` to fetch
/// readings and return them newest-last. Read-only — these never write to the sensor or the pump.
@MainActor
class PollingGlucoseSource: GlucoseSource {
    let id: String
    let priority: Int
    private(set) var latest: GlucoseSample?
    private(set) var history: [GlucoseReading] = []
    private(set) var status: GlucoseSourceStatus = .idle
    var onChange: (@MainActor () -> Void)?

    /// Poll cadences (seconds). Battery-aware: while the pump feed is healthy we poll rarely
    /// (`idleInterval`) just to keep a warm value; once it goes stale we ramp to `activeInterval`
    /// and poll immediately, since the cloud feed is now the live source.
    let activeInterval: TimeInterval
    let idleInterval: TimeInterval
    private var task: Task<Void, Never>?
    private var started = false
    private var primaryHealthy = false

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
                let delay = self.primaryHealthy ? self.idleInterval : self.activeInterval
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { break }
                await self.tick()
            }
        }
    }

    private func tick() async {
        do {
            let readings = try await poll()   // newest-last
            ingest(readings)
        } catch SourceError.needsSetup {
            status = .needsSetup; onChange?()
        } catch let e {
            status = .error((e as? LocalizedError)?.errorDescription ?? "\(e)")
            onChange?()
        }
    }

    /// Subclass hook: fetch recent readings (newest-last). Throw `SourceError.needsSetup` if the
    /// provider isn't configured.
    func poll() async throws -> [GlucoseSample] { [] }

    private func ingest(_ readings: [GlucoseSample]) {
        guard let newest = readings.max(by: { $0.date < $1.date }) else {
            status = .stale; onChange?(); return
        }
        latest = newest
        var byBucket: [Int: GlucoseReading] = [:]
        for r in history + readings.map(\.reading) {
            byBucket[Int(r.date.timeIntervalSince1970 / 300)] = r
        }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        history = byBucket.values.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        status = newest.isStale ? .stale : .connected
        onChange?()
    }
}

enum SourceError: LocalizedError {
    case needsSetup(String)
    case http(Int)
    case badResponse
    var errorDescription: String? {
        switch self {
        case .needsSetup(let s): return "\(s) not configured"
        case .http(let c): return "HTTP \(c)"
        case .badResponse: return "Unexpected response"
        }
    }
}
