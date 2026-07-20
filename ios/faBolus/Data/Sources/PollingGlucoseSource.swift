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

    /// Poll cadence (seconds). Cloud CGM feeds update ~every 5 min; poll a bit faster to catch them.
    let interval: TimeInterval
    private var task: Task<Void, Never>?

    init(id: String, priority: Int, interval: TimeInterval = 60) {
        self.id = id; self.priority = priority; self.interval = interval
    }

    func start() async {
        guard task == nil else { return }
        status = .searching; onChange?()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64((self?.interval ?? 60) * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        status = .idle; onChange?()
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
