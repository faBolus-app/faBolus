import Foundation
import SwiftData
import faBolusCore

/// faBolus's persistent history store. Write-through target for the live pump/CGM/source data (keeps the
/// 24 h in-memory buffers for the UI; this holds the long-term history) and the read source for
/// time-in-range, future plotting, and the advisory kits. On-device only.
///
/// Merge rule (multi-source): de-duplicate readings in the same 5-min slot, keeping the **higher source
/// priority** (imports / local BLE outrank cloud follows, per `GlucoseSource.priority`), ties broken by
/// the most recent `recordedAt` — the same policy as `GlucoseArbiter`.
///
/// Retention: **unlimited by default** (≈ 1 MB/month). `clear()` wipes everything (data-minimization);
/// `deleteGlucose(olderThan:)` powers the optional advanced auto-delete.
@MainActor
public final class GlucoseHistoryStore {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    public init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: StoredGlucose.self, StoredBolus.self, StoredCarb.self,
                                       configurations: config)
    }

    // MARK: Ingest

    public func ingest(_ samples: [GlucoseSample], priority: Int, recordedAt: Date = Date()) {
        for s in samples {
            context.insert(StoredGlucose(date: s.date, mgdl: s.mgdl, sourceID: s.sourceID,
                                         priority: priority, recordedAt: recordedAt))
        }
        try? context.save()
    }

    public func ingestGlucose(_ readings: [GlucoseReading], sourceID: String, priority: Int,
                              recordedAt: Date = Date()) {
        for r in readings {
            context.insert(StoredGlucose(date: r.date, mgdl: r.mgdl, sourceID: sourceID,
                                         priority: priority, recordedAt: recordedAt))
        }
        try? context.save()
    }

    public func ingestBoluses(_ markers: [BolusMarker], sourceID: String, recordedAt: Date = Date()) {
        for m in markers {
            context.insert(StoredBolus(date: m.date, units: m.units, sourceID: sourceID, recordedAt: recordedAt))
        }
        try? context.save()
    }

    public func ingestCarbs(_ entries: [(date: Date, grams: Double)], sourceID: String, recordedAt: Date = Date()) {
        for e in entries {
            context.insert(StoredCarb(date: e.date, grams: e.grams, sourceID: sourceID, recordedAt: recordedAt))
        }
        try? context.save()
    }

    // MARK: Query (conflict-resolved)

    /// Glucose in range, de-duplicated to one reading per 5-min slot (priority, then recency).
    public func glucose(in range: ClosedRange<Date>) -> [GlucoseReading] {
        let lo = range.lowerBound, hi = range.upperBound
        var desc = FetchDescriptor<StoredGlucose>(predicate: #Predicate { $0.date >= lo && $0.date <= hi })
        desc.sortBy = [SortDescriptor(\.date)]
        let rows = (try? context.fetch(desc)) ?? []
        var best: [Int: StoredGlucose] = [:]
        for r in rows {
            let slot = Int(r.date.timeIntervalSince1970 / 300)
            if let cur = best[slot] {
                if r.priority > cur.priority || (r.priority == cur.priority && r.recordedAt >= cur.recordedAt) {
                    best[slot] = r
                }
            } else { best[slot] = r }
        }
        return best.values.sorted { $0.date < $1.date }.map { GlucoseReading(date: $0.date, mgdl: $0.mgdl) }
    }

    public func boluses(in range: ClosedRange<Date>) -> [BolusMarker] {
        let lo = range.lowerBound, hi = range.upperBound
        var desc = FetchDescriptor<StoredBolus>(predicate: #Predicate { $0.date >= lo && $0.date <= hi })
        desc.sortBy = [SortDescriptor(\.date)]
        return ((try? context.fetch(desc)) ?? []).map { BolusMarker(date: $0.date, units: $0.units) }
    }

    /// Time-in-range / GMI / CV over the window, using faBolusCore's stats on the merged readings.
    public func statistics(in range: ClosedRange<Date>) -> GlucoseStatistics {
        GlucoseStatistics(readings: glucose(in: range))
    }

    // MARK: Retention / privacy

    public func glucoseCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<StoredGlucose>())) ?? 0
    }

    /// Approximate on-disk size of stored history (for a "history uses ~X MB" line). ~100 bytes/reading.
    public func approximateBytes() -> Int { glucoseCount() * 100 }

    /// Optional advanced auto-delete: drop glucose older than `date`.
    public func deleteGlucose(olderThan date: Date) {
        try? context.delete(model: StoredGlucose.self, where: #Predicate { $0.date < date })
        try? context.delete(model: StoredBolus.self, where: #Predicate { $0.date < date })
        try? context.delete(model: StoredCarb.self, where: #Predicate { $0.date < date })
        try? context.save()
    }

    /// Wipe all stored history (data-minimization / "Clear history").
    public func clear() {
        try? context.delete(model: StoredGlucose.self)
        try? context.delete(model: StoredBolus.self)
        try? context.delete(model: StoredCarb.self)
        try? context.save()
    }
}
