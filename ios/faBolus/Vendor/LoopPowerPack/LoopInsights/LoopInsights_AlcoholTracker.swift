// Adapted from LoopPowerPack/Loop @ ad4c4d498f936a25e22dd3a8dc93354138458509 (MIT)
//
//  LoopInsights_AlcoholTracker.swift — faBolus benign vendored tracker (09.18d-02, D-14/D-17).
//
//  Cherry-picked from the LoopPowerPack `AlcoholTracker`: ONLY the benign log / remove APIs + the entry
//  field shape (standardDrinks / source / timestamp / stable id). Adapted (not a byte-for-byte port)
//  because persistence is re-pointed from the mirror's UserDefaults to the faBolus SwiftData
//  `GlucoseHistoryStore`, so entries live in HistoryStore and are queryable alongside glucose.
//
//  DELIBERATELY OMITTED (D-14, binding no-novel-medical-advice rule + §13):
//   • `computeHypoRisk` and the `hypoRiskLevel` / `hypoRiskWindowEnd` state fields — a delayed-
//     hypoglycemia MEDICAL INFERENCE (novel advice surface). Not ported, not recomputed anywhere.
//   • `buildAlcoholPromptContext` — an AI-feeding prompt builder (includes the excluded risk copy).
//   • `currentState` / `AlcoholState` / `update(id:)` — the descriptive ~1 drink/hr linear-metabolism
//     "current level" pool estimate and its value type. Cherry-picked in 09.18d-02 but surfaced by NO
//     view (grep-verified dead); removed in the 09.18d code-review (IN-01 — also retires the M-01
//     unbounded-pool math). Not a re-vendor — a local deletion of unused adapted surface (see
//     UPSTREAM.md).
//  Informational only: faBolus never changes a dose.

import Foundation
import HistoryStore

/// One logged alcohol intake surfaced to the UI — a value type over the `StoredAlcohol` @Model.
struct AlcoholEntry: Identifiable, Equatable {
    let id: String            // stable entryID (UUID string) — delete + backup identity
    var standardDrinks: Double
    var source: String
    var date: Date
    init(id: String = UUID().uuidString, standardDrinks: Double, source: String, date: Date) {
        self.id = id; self.standardDrinks = standardDrinks; self.source = source; self.date = date
    }
}

/// Thin benign alcohol tracker over the shared `GlucoseHistoryStore` (09.18d-02). All mutation and
/// queries go through the store's `ingestAlcohol` / `alcohol(in:)` / `deleteAlcohol` CRUD.
@MainActor
struct LoopInsights_AlcoholTracker {
    /// `sourceID` stamped on logged entries — the single shared constant (IN-02).
    static let sourceID = GlucoseHistoryStore.loopInsightsTrackerSourceID
    /// How far back the log list / state window reaches.
    private static let window: TimeInterval = 30 * 86400

    private let store: GlucoseHistoryStore?
    init(store: GlucoseHistoryStore?) { self.store = store }

    /// All logged entries in the recent window, most-recent first.
    func entries(now: Date = Date()) -> [AlcoholEntry] {
        guard let store else { return [] }
        let range = now.addingTimeInterval(-Self.window)...now.addingTimeInterval(60)
        return store.alcohol(in: range).map {
            AlcoholEntry(id: $0.entryID, standardDrinks: $0.standardDrinks, source: $0.source, date: $0.date)
        }
    }

    /// Log an alcohol intake. Returns the created entry (with its stable id).
    @discardableResult
    func log(standardDrinks: Double, source: String, at timestamp: Date = Date()) -> AlcoholEntry {
        let entry = AlcoholEntry(standardDrinks: standardDrinks, source: source, date: timestamp)
        store?.ingestAlcohol(entryID: entry.id, standardDrinks: standardDrinks, source: source,
                             date: timestamp, sourceID: Self.sourceID)
        return entry
    }

    /// Remove a logged entry by its stable id.
    func remove(id: String) { store?.deleteAlcohol(id: id) }
}
