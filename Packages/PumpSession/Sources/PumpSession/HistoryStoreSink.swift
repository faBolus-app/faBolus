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
                carbs: batch.carbs.map { (date: $0.date, grams: $0.grams) },
                sourceID: Self.sourceID, glucosePriority: Self.glucosePriority)
        }
    }
}
