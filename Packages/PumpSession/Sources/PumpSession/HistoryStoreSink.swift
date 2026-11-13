import Foundation
import HistoryStore
import faBolusCore

/// Pump history into faBolus's history store. Glucose goes in at the pump's priority, below an
/// independent CGM source, as the old app ranked them; a save that fails throws, so the session fetches
/// the records again.
public struct HistoryStoreSink: PumpHistorySink {
    public static let sourceID = "pump"
    public static let glucosePriority = 50

    private let store: GlucoseHistoryStore

    public init(store: GlucoseHistoryStore) { self.store = store }

    public func record(_ batch: PumpHistoryBatch) async throws {
        let store = self.store
        try await MainActor.run {
            try store.ingestPumpHistory(
                glucose: batch.glucose, boluses: batch.boluses,
                carbs: batch.carbs.map { (date: $0.date, grams: $0.grams) }, deliveryChanges: batch.deliveryChanges,
                events: batch.events,
                eventLimit: PumpSession.logbookLimit, sourceID: Self.sourceID, glucosePriority: Self.glucosePriority)
        }
    }

    /// A failed read is logged and shows as an empty logbook; the history itself isn't fetched again.
    public func loadEvents(limit: Int) async -> [HistoryEvent] {
        let store = self.store
        return await MainActor.run {
            do { return try store.historyEvents(sourceID: Self.sourceID, limit: limit) } catch {
                sessionLog.error("logbook not read: \(String(describing: error), privacy: .public)")
                return []
            }
        }
    }

    /// A failed delete is logged and left: the events stay until the next forget or a clear of the store.
    /// The basal changes go too, so another pump's (or a restarted log's) rate isn't drawn as this one's.
    public func clearEvents() async {
        let store = self.store
        await MainActor.run {
            do {
                try store.clearHistoryEvents(sourceID: Self.sourceID)
                try store.clearDeliveryChanges(sourceID: Self.sourceID)
            } catch {
                sessionLog.error("logbook not cleared: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
