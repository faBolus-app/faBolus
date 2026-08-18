// Adapted from LoopPowerPack/Loop @ ad4c4d498f936a25e22dd3a8dc93354138458509 (MIT)
//
//  LoopInsights_CaffeineTracker.swift — faBolus benign vendored tracker (09.18d-02, D-14/D-17).
//
//  Cherry-picked from the LoopPowerPack `CaffeineTracker`: ONLY the benign log / remove APIs + the entry
//  field shape (milligrams / source / timestamp / stable id). Adapted (not a byte-for-byte port) because
//  persistence is re-pointed from the mirror's UserDefaults to the faBolus SwiftData
//  `GlucoseHistoryStore`, so entries live in HistoryStore and are queryable alongside glucose.
//
//  DELIBERATELY OMITTED (D-14, binding no-novel-medical-advice rule + §13):
//   • `buildCaffeinePromptContext` — an AI-feeding prompt builder (novel advice surface).
//   • `syncFromHealthKit` / `healthKitManager` — HealthKit plumbing (kept Foundation-only).
//   • `currentState` / `CaffeineState` / `update(id:)` — the descriptive half-life "current level"
//     estimate and its value type. Cherry-picked in 09.18d-02 but surfaced by NO view (grep-verified
//     dead); removed in the 09.18d code-review (IN-01) to shrink the §13 review surface. Not a
//     re-vendor — a local deletion of unused adapted surface (see UPSTREAM.md).
//  Informational only: faBolus never changes a dose.

import Foundation
import HistoryStore

/// One logged caffeine intake surfaced to the UI — a value type over the `StoredCaffeine` @Model.
struct CaffeineEntry: Identifiable, Equatable {
    let id: String            // stable entryID (UUID string) — delete + backup identity
    var milligrams: Double
    var source: String
    var date: Date
    init(id: String = UUID().uuidString, milligrams: Double, source: String, date: Date) {
        self.id = id; self.milligrams = milligrams; self.source = source; self.date = date
    }
}

/// Thin benign caffeine tracker over the shared `GlucoseHistoryStore` (09.18d-02). All mutation and
/// queries go through the store's `ingestCaffeine` / `caffeine(in:)` / `deleteCaffeine` CRUD.
@MainActor
struct LoopInsights_CaffeineTracker {
    /// `sourceID` stamped on logged entries — the single shared constant (IN-02).
    static let sourceID = GlucoseHistoryStore.loopInsightsTrackerSourceID
    /// How far back the log list / state window reaches.
    private static let window: TimeInterval = 30 * 86400

    private let store: GlucoseHistoryStore?
    init(store: GlucoseHistoryStore?) { self.store = store }

    /// All logged entries in the recent window, most-recent first.
    func entries(now: Date = Date()) -> [CaffeineEntry] {
        guard let store else { return [] }
        let range = now.addingTimeInterval(-Self.window)...now.addingTimeInterval(60)
        return store.caffeine(in: range).map {
            CaffeineEntry(id: $0.entryID, milligrams: $0.milligrams, source: $0.source, date: $0.date)
        }
    }

    /// Log a caffeine intake. Returns the created entry (with its stable id).
    @discardableResult
    func log(milligrams: Double, source: String, at timestamp: Date = Date()) -> CaffeineEntry {
        let entry = CaffeineEntry(milligrams: milligrams, source: source, date: timestamp)
        store?.ingestCaffeine(entryID: entry.id, milligrams: milligrams, source: source,
                              date: timestamp, sourceID: Self.sourceID)
        return entry
    }

    /// Remove a logged entry by its stable id.
    func remove(id: String) { store?.deleteCaffeine(id: id) }
}
