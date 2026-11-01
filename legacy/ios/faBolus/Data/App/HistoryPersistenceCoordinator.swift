import Foundation
import faBolusCore
import HistoryStore
import os

/// Persistent-history write-through + identity-diff bookkeeping, extracted from `AppModel` behind
/// the unchanged `GlucoseHistoryStore` seam. Owns the store, the two identity-diff key sets, and
/// every read/write that touches them (`persist`, `storedStatistics`, `clearStoredHistory`,
/// `applyRetention`, `recordCarbs`, `storedHistoryApproxBytes`, plus the
/// `#if DEBUG` test seams).
///
/// Needs no injected closures — every method takes its inputs as plain values
/// (`persist(glucose:boluses:provenance:)`) and returns plain values. Zero back-pointer either
/// direction; `AppModel` never hands this coordinator a reference to itself, and this coordinator
/// never reaches back into `AppModel`.
///
/// `AppModel` exposes a forwarding `history` computed property (`historyPersistence.store`) so
/// call sites read persisted history through `AppModel` without reaching into this coordinator.
@MainActor
final class HistoryPersistenceCoordinator {
    private static let log = Logger(subsystem: "com.fabolus.app", category: "history")

    /// Persistent history (SwiftData) — write-through target for long-term glucose/bolus history;
    /// powers time-in-range / future plotting and feeds the advisory tools. Optional so a store-init
    /// failure never breaks the app. `#if DEBUG` `setHistoryStoreForTesting` substitutes an in-memory
    /// store for test isolation; production never reassigns it after init.
    private(set) var store: GlucoseHistoryStore?

    /// Opens the persistent store, surfacing (not discarding) any `ModelContainer` failure so the
    /// whole history subsystem going dark is visible somewhere instead of silent. `store` stays nil on
    /// failure — every caller already treats a nil store as "no persisted history" — but the cause is
    /// now logged rather than swallowed by a bare `try?`.
    init() {
        do {
            store = try GlucoseHistoryStore()
        } catch {
            Self.log.error("GlucoseHistoryStore failed to open: \(String(describing: error), privacy: .public)")
            store = nil
        }
    }

    // Identity-diff bookkeeping (this cycle's readings vs. what the LAST `persist` call already
    // wrote), NOT a forward-only date watermark. A forward watermark (`$0.date > lastGlucoseIngest`)
    // silently dropped any gap-sync record dated OLDER than the watermark — exactly the
    // interior/forward-gap records gap-sync exists to fetch. Diffing against the previous snapshot's
    // identity set lets an older record through (it wasn't in the last snapshot, so it's "new")
    // while still not re-inserting the same already-ingested readings on every `refresh()` tick
    // (`refresh()`/`persist` fire far more often than history actually changes).
    private var lastPersistedGlucoseKeys: Set<TimeInterval> = []
    private var lastPersistedBolusKeys: Set<TimeInterval> = []

    /// Write only NEW readings/boluses into the persistent store (never re-insert the rolling buffer).
    /// "New" is identity-diffed against the previous call's snapshot, not date-watermarked — a
    /// gap-sync record dated older than everything previously seen still reaches `GlucoseHistoryStore`
    /// here, while an unchanged reading already written on the last call is still skipped (no
    /// unbounded re-insert on every `refresh()` tick). See `lastPersistedGlucoseKeys`.
    func persist(glucose: [GlucoseReading], boluses: [BolusMarker], provenance: GlucoseProvenance) {
        guard let store else { return }
        let sourceID: String
        let priority: Int
        switch provenance {
        case .failover(let sid, _):
            sourceID = sid
            priority = 100  // independent source
        default:
            sourceID = "pump"
            priority = 50  // pump-relayed
        }
        let glucoseKeys = Set(glucose.map(\.date.timeIntervalSince1970))
        let newGlucose = glucose.filter { !lastPersistedGlucoseKeys.contains($0.date.timeIntervalSince1970) }
        if !newGlucose.isEmpty {
            store.ingestGlucose(newGlucose, sourceID: sourceID, priority: priority)
        }
        lastPersistedGlucoseKeys = glucoseKeys

        let bolusKeys = Set(boluses.map(\.date.timeIntervalSince1970))
        let newBoluses = boluses.filter { !lastPersistedBolusKeys.contains($0.date.timeIntervalSince1970) }
        if !newBoluses.isEmpty {
            store.ingestBoluses(newBoluses, sourceID: "pump")
        }
        lastPersistedBolusKeys = bolusKeys
    }

    /// Time-in-range / GMI over the *persisted* history (default 90 days) — for stats / future plotting.
    func storedStatistics(days: Int = 90) -> GlucoseStatistics? {
        guard let store else { return nil }
        let end = Date()
        let start = end.addingTimeInterval(-Double(days) * 86400)
        return store.statistics(in: start...end)
    }

    /// Wipe all persisted history (Settings → data-minimization / "Clear history").
    func clearStoredHistory() { store?.clear() }

    /// Approximate on-disk size of stored history, for a "history uses ~X MB" line.
    func storedHistoryApproxBytes() -> Int { store?.approximateBytes() ?? 0 }

    /// Apply a retention window (days); 0 = keep everything. Safe to call any time (e.g. on launch and
    /// when the setting changes).
    func applyRetention(days: Int) {
        guard days > 0, let store else { return }
        store.deleteGlucose(olderThan: Date().addingTimeInterval(-Double(days) * 86400))
    }

    /// Record user-entered carbs (from a carb bolus) into the persistent store, so sensitivity/insights
    /// have carb context. Source = faBolus (its own entry).
    func recordCarbs(grams: Double) {
        guard grams > 0 else { return }
        store?.ingestCarbs([(date: Date(), grams: grams)], sourceID: "fabolus")
    }

    #if DEBUG
    /// Test seam: substitute the persistent history store (e.g. an in-memory `GlucoseHistoryStore`) so a
    /// test can assert on `persist`'s write-through without touching the real on-disk store or leaking
    /// state across tests/suites. Production never calls this — `store` is set once at init.
    func setHistoryStoreForTesting(_ newStore: GlucoseHistoryStore?) {
        store = newStore
        lastPersistedGlucoseKeys = []
        lastPersistedBolusKeys = []
    }
    /// Test seam: read-through into the injected store, mirroring `storedStatistics`'s public read
    /// pattern — lets a test assert a fetched (incl. gap-sync) history record actually reached the
    /// persistent store, not just the in-memory rolling buffer.
    func storedGlucoseForTesting(in range: ClosedRange<Date>) -> [GlucoseReading] { store?.glucose(in: range) ?? [] }
    #endif
}
