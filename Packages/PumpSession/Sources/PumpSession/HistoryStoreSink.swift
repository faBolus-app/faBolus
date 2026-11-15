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
                events: batch.events, eventLimit: PumpSession.logbookLimit,
                bolusRecords: batch.completedBoluses,
                sourceID: Self.sourceID, glucosePriority: Self.glucosePriority)
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

    /// A failed read is logged and holds nothing: an unknown outcome is then searched for on the pump.
    public func completedBoluses() async -> [HistoryBolus] {
        let store = self.store
        return await MainActor.run {
            do { return try store.bolusRecords(sourceID: Self.sourceID) } catch {
                sessionLog.error("bolus records not read: \(String(describing: error), privacy: .public)")
                return []
            }
        }
    }

    /// A failed delete is logged and left: what it held stays until the next forget or a clear of the store.
    /// The completed-bolus records go first, each clear on its own, so another pump's (or a restarted log's)
    /// bolus IDs can't be taken for this one's even when another clear fails; the basal changes go too, so
    /// its rate isn't drawn as this one's.
    public func clearEvents() async {
        let store = self.store
        await MainActor.run {
            let clears: [(String, () throws -> Void)] = [
                ("bolus records", { try store.clearBolusRecords(sourceID: Self.sourceID) }),
                ("logbook", { try store.clearHistoryEvents(sourceID: Self.sourceID) }),
                ("basal changes", { try store.clearDeliveryChanges(sourceID: Self.sourceID) })
            ]
            for (what, clear) in clears {
                do { try clear() } catch {
                    sessionLog.error(
                        "\(what, privacy: .public) not cleared: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
