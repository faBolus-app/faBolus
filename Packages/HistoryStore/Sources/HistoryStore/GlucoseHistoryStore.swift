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
    /// The single `sourceID` stamped on the benign LoopInsights caffeine/alcohol tracker entries so they
    /// are attributable in export/backup (IN-02). Hoisted here — the one type both the vendored trackers
    /// and `AppModel` already reference — so the literal is declared once instead of three times.
    public static let loopInsightsTrackerSourceID = "app.loopInsightsTrackers"

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    public init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: StoredGlucose.self, StoredBolus.self, StoredCarb.self,
                                       StoredSite.self,
                                       StoredCaffeine.self, StoredAlcohol.self,
                                       StoredHeartRate.self,
                                       configurations: config)
        if !inMemory { Self.pinFileProtection(storeURL: config.url) }
    }

    /// F1 (§13) — pin the on-disk SwiftData store (and its `-wal` / `-shm` siblings) to
    /// `completeUntilFirstUserAuthentication`: encrypted at rest, still readable at a locked background
    /// relaunch when the pump/CGM sync writes new history. Deliberately NOT `.complete` (which would lock
    /// history writes/reads whenever the device locks). New files created later inherit iOS's default
    /// protection class, which is also `CompleteUntilFirstUserAuthentication`; this pins existing files
    /// explicitly. Best-effort: platforms without file protection (the Simulator) silently no-op.
    private static func pinFileProtection(storeURL: URL) {
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        for url in [storeURL,
                    URL(fileURLWithPath: storeURL.path + "-wal"),
                    URL(fileURLWithPath: storeURL.path + "-shm")]
        where fm.fileExists(atPath: url.path) {
            try? fm.setAttributes(attrs, ofItemAtPath: url.path)
        }
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

    // MARK: SiteAtlas CRUD (09.18a, D-10)

    /// Record an infusion-site / CGM-sensor placement. `kind` is "pump" | "sensor"; `bodySide` is
    /// "front" | "back" (raw enum values, keeping the schema primitive). `siteID` defaults to a fresh
    /// UUID string; callers pass a stable one when they need delete/backup identity.
    public func ingestSite(siteID: String = UUID().uuidString, kind: String, bodySide: String,
                           normalizedX: Double, normalizedY: Double, note: String? = nil,
                           date: Date = Date(), sourceID: String,
                           recordedAt: Date = Date()) {
        context.insert(StoredSite(siteID: siteID, kind: kind, bodySide: bodySide,
                                  normalizedX: normalizedX, normalizedY: normalizedY, note: note,
                                  date: date, sourceID: sourceID, recordedAt: recordedAt))
        try? context.save()
    }

    /// All recorded sites, most-recent placement first.
    public func allSites() -> [StoredSite] {
        var desc = FetchDescriptor<StoredSite>()
        desc.sortBy = [SortDescriptor(\.date, order: .reverse)]
        return (try? context.fetch(desc)) ?? []
    }

    /// Recorded sites whose placement `date` falls in `range`, most-recent first.
    public func sites(in range: ClosedRange<Date>) -> [StoredSite] {
        let lo = range.lowerBound, hi = range.upperBound
        var desc = FetchDescriptor<StoredSite>(predicate: #Predicate { $0.date >= lo && $0.date <= hi })
        desc.sortBy = [SortDescriptor(\.date, order: .reverse)]
        return (try? context.fetch(desc)) ?? []
    }

    /// Delete the site with the given stable `siteID`.
    public func deleteSite(id siteID: String) {
        try? context.delete(model: StoredSite.self, where: #Predicate { $0.siteID == siteID })
        try? context.save()
    }

    // MARK: Caffeine / Alcohol benign trackers CRUD (09.18d-02, D-14/D-17)

    /// Log a caffeine intake (informational only — never a dose input). `entryID` defaults to a fresh
    /// UUID string; callers pass a stable one when they need delete/backup identity.
    public func ingestCaffeine(entryID: String = UUID().uuidString, milligrams: Double, source: String,
                               date: Date = Date(), sourceID: String, recordedAt: Date = Date()) {
        context.insert(StoredCaffeine(entryID: entryID, milligrams: milligrams, source: source,
                                      date: date, sourceID: sourceID, recordedAt: recordedAt))
        try? context.save()
    }

    /// Caffeine entries whose `date` falls in `range`, most-recent first.
    public func caffeine(in range: ClosedRange<Date>) -> [StoredCaffeine] {
        let lo = range.lowerBound, hi = range.upperBound
        var desc = FetchDescriptor<StoredCaffeine>(predicate: #Predicate { $0.date >= lo && $0.date <= hi })
        desc.sortBy = [SortDescriptor(\.date, order: .reverse)]
        return (try? context.fetch(desc)) ?? []
    }

    /// Delete the caffeine entry with the given stable `entryID`.
    public func deleteCaffeine(id entryID: String) {
        try? context.delete(model: StoredCaffeine.self, where: #Predicate { $0.entryID == entryID })
        try? context.save()
    }

    /// Log an alcohol intake (informational only — never a dose input). `entryID` defaults to a fresh
    /// UUID string; callers pass a stable one when they need delete/backup identity.
    public func ingestAlcohol(entryID: String = UUID().uuidString, standardDrinks: Double, source: String,
                              date: Date = Date(), sourceID: String, recordedAt: Date = Date()) {
        context.insert(StoredAlcohol(entryID: entryID, standardDrinks: standardDrinks, source: source,
                                     date: date, sourceID: sourceID, recordedAt: recordedAt))
        try? context.save()
    }

    /// Alcohol entries whose `date` falls in `range`, most-recent first.
    public func alcohol(in range: ClosedRange<Date>) -> [StoredAlcohol] {
        let lo = range.lowerBound, hi = range.upperBound
        var desc = FetchDescriptor<StoredAlcohol>(predicate: #Predicate { $0.date >= lo && $0.date <= hi })
        desc.sortBy = [SortDescriptor(\.date, order: .reverse)]
        return (try? context.fetch(desc)) ?? []
    }

    /// Delete the alcohol entry with the given stable `entryID`.
    public func deleteAlcohol(id entryID: String) {
        try? context.delete(model: StoredAlcohol.self, where: #Predicate { $0.entryID == entryID })
        try? context.save()
    }

    // MARK: Heart-rate history (09.23-02, D-14 — extends the 09.18b ephemeral chart-context reader)

    /// Persist imported/recorded heart-rate samples. `entryID` defaults to a fresh UUID string per
    /// sample; callers needing delete/backup identity should ingest one at a time with a stable id.
    public func ingestHeartRate(_ samples: [(date: Date, bpm: Double)], sourceID: String,
                                source: String? = nil, recordedAt: Date = Date()) {
        for s in samples {
            context.insert(StoredHeartRate(entryID: UUID().uuidString, bpm: s.bpm,
                                           source: source ?? sourceID,
                                           date: s.date, sourceID: sourceID, recordedAt: recordedAt))
        }
        try? context.save()
    }

    /// Heart-rate rows whose `date` falls in `range`, most-recent first.
    public func heartRate(in range: ClosedRange<Date>) -> [StoredHeartRate] {
        let lo = range.lowerBound, hi = range.upperBound
        var desc = FetchDescriptor<StoredHeartRate>(predicate: #Predicate { $0.date >= lo && $0.date <= hi })
        desc.sortBy = [SortDescriptor(\.date, order: .reverse)]
        return (try? context.fetch(desc)) ?? []
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

    public func carbs(in range: ClosedRange<Date>) -> [(date: Date, grams: Double)] {
        let lo = range.lowerBound, hi = range.upperBound
        var desc = FetchDescriptor<StoredCarb>(predicate: #Predicate { $0.date >= lo && $0.date <= hi })
        desc.sortBy = [SortDescriptor(\.date)]
        return ((try? context.fetch(desc)) ?? []).map { (date: $0.date, grams: $0.grams) }
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
        try? context.delete(model: StoredSite.self)
        try? context.delete(model: StoredCaffeine.self)
        try? context.delete(model: StoredAlcohol.self)
        try? context.delete(model: StoredHeartRate.self)
        try? context.save()
    }
}
