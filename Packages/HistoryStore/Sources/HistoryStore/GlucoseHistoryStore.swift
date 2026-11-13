import Foundation
import SwiftData
import faBolusCore

/// faBolus's persistent history store: the pump's glucose, boluses, carbs, basal changes and logbook, and the backup CGM's
/// readings, read back for the chart and time-in-range. On-device only.
///
/// Merge rule (multi-source): de-duplicate readings in the same 5-min slot, keeping the **higher source
/// priority** (imports / local BLE outrank cloud follows, per `GlucoseSource.priority`), ties broken by
/// the most recent `recordedAt` — the same policy as `GlucoseArbiter`.
///
/// Retention is the app's: it keeps one day of glucose (`deleteGlucose(olderThan:)` at launch), and
/// `clear()` wipes everything.
@MainActor
public final class GlucoseHistoryStore {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    public convenience init(inMemory: Bool = false) throws {
        try self.init(ModelConfiguration(isStoredInMemoryOnly: inMemory), onDisk: !inMemory)
    }

    /// A store on disk at `url`.
    public convenience init(url: URL) throws {
        try self.init(ModelConfiguration(url: url), onDisk: true)
    }

    private init(_ config: ModelConfiguration, onDisk: Bool) throws {
        container = try ModelContainer(
            for: StoredGlucose.self, StoredBolus.self, StoredCarb.self, StoredDeliveryChange.self,
            StoredHistoryEvent.self,
            configurations: config)
        if onDisk { Self.pinFileProtection(storeURL: config.url) }
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
        for url in [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
        where fm.fileExists(atPath: url.path) {
            try? fm.setAttributes(attrs, ofItemAtPath: url.path)
        }
    }

    // MARK: Ingest

    public func ingest(_ samples: [GlucoseSample], priority: Int, recordedAt: Date = Date()) {
        for s in samples {
            context.insert(
                StoredGlucose(
                    date: s.date, mgdl: s.mgdl, sourceID: s.sourceID,
                    priority: priority, recordedAt: recordedAt))
        }
        try? context.save()
    }

    public func ingestGlucose(
        _ readings: [GlucoseReading], sourceID: String, priority: Int,
        recordedAt: Date = Date()
    ) {
        for r in readings {
            context.insert(
                StoredGlucose(
                    date: r.date, mgdl: r.mgdl, sourceID: sourceID,
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

    /// Pump history in one save that throws when it fails, so the caller can keep the records and try
    /// again. A bolus, carb entry or delivery change already held from `sourceID` with the same amount within 2 seconds is
    /// skipped, so writing the same records twice (a retried sync, whose times move by the pump clock
    /// anchor's sub-second drift) doesn't count it twice; glucose needs no such check, because a query
    /// keeps one reading per 5-minute slot.
    ///
    /// The logbook's events go in the same save, one per pump sequence number, so the logbook and the
    /// chart never disagree about what the phone holds.
    ///
    /// - Parameter eventLimit: how many of the source's events to keep, newest first; older ones are
    ///   deleted in the same save. All are kept when `nil`.
    public func ingestPumpHistory(
        glucose: [GlucoseReading], boluses: [BolusMarker], carbs: [(date: Date, grams: Double)],
        deliveryChanges: [DeliveryChange] = [], events: [HistoryEvent] = [], eventLimit: Int? = nil, sourceID: String,
        glucosePriority: Int,
        recordedAt: Date = Date()
    ) throws {
        let slack: TimeInterval = 2
        let dates = boluses.map(\.date) + carbs.map(\.date) + deliveryChanges.map(\.date)
        let lo = (dates.min() ?? .distantFuture).addingTimeInterval(-slack)
        let hi = (dates.max() ?? .distantPast).addingTimeInterval(slack)
        let heldBoluses = try context.fetch(
            FetchDescriptor<StoredBolus>(
                predicate: #Predicate { $0.sourceID == sourceID && $0.date >= lo && $0.date <= hi })
        ).map { (date: $0.date, amount: $0.units) }
        let heldCarbs = try context.fetch(
            FetchDescriptor<StoredCarb>(
                predicate: #Predicate { $0.sourceID == sourceID && $0.date >= lo && $0.date <= hi })
        ).map { (date: $0.date, amount: $0.grams) }
        let heldChanges = try context.fetch(
            FetchDescriptor<StoredDeliveryChange>(
                predicate: #Predicate { $0.sourceID == sourceID && $0.date >= lo && $0.date <= hi })
        )
        func isHeld(_ held: [(date: Date, amount: Double)], _ date: Date, _ amount: Double) -> Bool {
            held.contains { abs($0.date.timeIntervalSince(date)) <= slack && abs($0.amount - amount) < 0.0005 }
        }
        for r in glucose {
            context.insert(
                StoredGlucose(
                    date: r.date, mgdl: r.mgdl, sourceID: sourceID, priority: glucosePriority, recordedAt: recordedAt))
        }
        for b in boluses where !isHeld(heldBoluses, b.date, b.units) {
            context.insert(StoredBolus(date: b.date, units: b.units, sourceID: sourceID, recordedAt: recordedAt))
        }
        for c in carbs where !isHeld(heldCarbs, c.date, c.grams) {
            context.insert(StoredCarb(date: c.date, grams: c.grams, sourceID: sourceID, recordedAt: recordedAt))
        }
        for d in deliveryChanges
        where !isHeld(
            heldChanges.filter { $0.kind == d.kind.rawValue }.map { (date: $0.date, amount: $0.unitsPerHour) },
            d.date, d.unitsPerHour)
        {
            context.insert(
                StoredDeliveryChange(
                    date: d.date, kind: d.kind.rawValue, unitsPerHour: d.unitsPerHour, sourceID: sourceID,
                    recordedAt: recordedAt))
        }
        if !events.isEmpty {
            let sequences = events.map { Int($0.id) }
            let heldEvents = Set(
                try context.fetch(
                    FetchDescriptor<StoredHistoryEvent>(
                        predicate: #Predicate { $0.sourceID == sourceID && sequences.contains($0.sequence) })
                ).map(\.sequence))
            for e in events where !heldEvents.contains(Int(e.id)) {
                context.insert(
                    StoredHistoryEvent(
                        sequence: Int(e.id), date: e.date, category: e.category.rawValue, title: e.title,
                        detail: e.detail, sourceID: sourceID))
            }
            // Sorted in memory: a fetch offset doesn't skip the events inserted above, which aren't saved yet.
            if let eventLimit {
                for e in try context.fetch(Self.newestEvents(sourceID: sourceID)).dropFirst(eventLimit) {
                    context.delete(e)
                }
            }
        }
        try context.save()
    }

    /// The logbook's events from `sourceID`, in `HistoryEvent.newestFirst` order.
    public func historyEvents(sourceID: String, limit: Int) throws -> [HistoryEvent] {
        var desc = Self.newestEvents(sourceID: sourceID)
        desc.fetchLimit = limit
        return try context.fetch(desc).map {
            HistoryEvent(
                id: UInt32(clamping: $0.sequence), date: $0.date,
                category: HistoryEvent.Category(rawValue: $0.category) ?? .other, title: $0.title,
                detail: $0.detail)
        }
    }

    private static func newestEvents(sourceID: String) -> FetchDescriptor<StoredHistoryEvent> {
        FetchDescriptor(
            predicate: #Predicate { $0.sourceID == sourceID },
            sortBy: [SortDescriptor(\.date, order: .reverse), SortDescriptor(\.sequence, order: .reverse)])
    }

    /// Removes the logbook's events from `sourceID`, as when the pump they came from is forgotten.
    public func clearHistoryEvents(sourceID: String) throws {
        try context.delete(model: StoredHistoryEvent.self, where: #Predicate { $0.sourceID == sourceID })
        try context.save()
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
            } else {
                best[slot] = r
            }
        }
        return best.values.sorted { $0.date < $1.date }.map { GlucoseReading(date: $0.date, mgdl: $0.mgdl) }
    }

    public func boluses(in range: ClosedRange<Date>) -> [BolusMarker] {
        let lo = range.lowerBound, hi = range.upperBound
        var desc = FetchDescriptor<StoredBolus>(predicate: #Predicate { $0.date >= lo && $0.date <= hi })
        desc.sortBy = [SortDescriptor(\.date)]
        return ((try? context.fetch(desc)) ?? []).map { BolusMarker(date: $0.date, units: $0.units) }
    }

    public func carbs(in range: ClosedRange<Date>) -> [(
        date: Date, grams: Double
    )] {
        let lo = range.lowerBound, hi = range.upperBound
        var desc = FetchDescriptor<StoredCarb>(predicate: #Predicate { $0.date >= lo && $0.date <= hi })
        desc.sortBy = [SortDescriptor(\.date)]
        return ((try? context.fetch(desc)) ?? []).map { (date: $0.date, grams: $0.grams) }
    }

    /// How far before a window a rate or a suspension in effect at its start is looked for. An older one
    /// isn't drawn: the records since may not have been fetched yet, and a gap is unknown, not that rate.
    public static let deliveryCarryIn: TimeInterval = 24 * 3600

    /// The delivery changes in `range`, oldest first, and the rate and the suspend or resume in effect at
    /// its start (from up to `deliveryCarryIn` before it), so the chart draws a rate or a suspension already
    /// under way from the window's edge.
    public func deliveryChanges(in range: ClosedRange<Date>) -> [DeliveryChange] {
        let lo = range.lowerBound, hi = range.upperBound
        let inRange = fetchChanges(FetchDescriptor(predicate: #Predicate { $0.date >= lo && $0.date <= hi }))
        let carried = inEffect(at: lo).filter { $0.date >= lo.addingTimeInterval(-Self.deliveryCarryIn) }
        return (carried.compactMap(Self.change) + inRange.compactMap(Self.change)).sorted { $0.date < $1.date }
    }

    /// Removes the delivery changes from `sourceID`, as when the pump they came from is forgotten or its
    /// log restarts.
    public func clearDeliveryChanges(sourceID: String) throws {
        try context.delete(model: StoredDeliveryChange.self, where: #Predicate { $0.sourceID == sourceID })
        try context.save()
    }

    /// The newest basal rate change and the newest suspend or resume before `date`.
    private func inEffect(at date: Date) -> [StoredDeliveryChange] {
        let basal = DeliveryChange.Kind.basalRate.rawValue
        func newest(_ predicate: Predicate<StoredDeliveryChange>) -> StoredDeliveryChange? {
            var desc = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.date, order: .reverse)])
            desc.fetchLimit = 1
            return fetchChanges(desc).first
        }
        return [
            newest(#Predicate { $0.date < date && $0.kind == basal }),
            newest(#Predicate { $0.date < date && $0.kind != basal })
        ].compactMap { $0 }
    }

    private func fetchChanges(_ desc: FetchDescriptor<StoredDeliveryChange>) -> [StoredDeliveryChange] {
        var desc = desc
        if desc.sortBy.isEmpty { desc.sortBy = [SortDescriptor(\.date)] }
        return (try? context.fetch(desc)) ?? []
    }

    private static func change(_ s: StoredDeliveryChange) -> DeliveryChange? {
        DeliveryChange.Kind(rawValue: s.kind).map {
            DeliveryChange(date: s.date, kind: $0, unitsPerHour: s.unitsPerHour)
        }
    }

    /// Time-in-range / GMI / CV over the window, using faBolusCore's stats on the merged readings.
    public func statistics(in range: ClosedRange<Date>) -> GlucoseStatistics {
        GlucoseStatistics(readings: glucose(in: range))
    }

    // MARK: Retention / privacy

    public func glucoseCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<StoredGlucose>())) ?? 0
    }

    /// Optional advanced auto-delete: drop glucose older than `date`. The basal rate and the suspend or
    /// resume in effect at `date` are kept, so a rate that hasn't changed since is still drawn.
    public func deleteGlucose(olderThan date: Date) {
        try? context.delete(model: StoredGlucose.self, where: #Predicate { $0.date < date })
        try? context.delete(model: StoredBolus.self, where: #Predicate { $0.date < date })
        try? context.delete(model: StoredCarb.self, where: #Predicate { $0.date < date })
        let kept = Set(inEffect(at: date).map(\.persistentModelID))
        for change in fetchChanges(FetchDescriptor(predicate: #Predicate { $0.date < date }))
        where !kept.contains(change.persistentModelID) {
            context.delete(change)
        }
        try? context.save()
    }

    /// Wipe all stored history (data-minimization / "Clear history").
    public func clear() {
        try? context.delete(model: StoredGlucose.self)
        try? context.delete(model: StoredBolus.self)
        try? context.delete(model: StoredCarb.self)
        try? context.delete(model: StoredDeliveryChange.self)
        try? context.delete(model: StoredHistoryEvent.self)
        try? context.save()
    }
}
