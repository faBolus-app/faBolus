// Adapted from LoopPowerPack/Loop @ ad4c4d498f936a25e22dd3a8dc93354138458509 (MIT)
//
//  LoopInsights_AlcoholTracker.swift — faBolus benign vendored tracker (09.18d-02, D-14/D-17).
//
//  Cherry-picked from the LoopPowerPack `AlcoholTracker`: ONLY the benign log / remove / update /
//  current-state APIs + the entry field shape (standardDrinks / source / timestamp / stable id).
//  Adapted (not a byte-for-byte port) because persistence is re-pointed from the mirror's UserDefaults
//  to the faBolus SwiftData `GlucoseHistoryStore`, so entries live in HistoryStore and are queryable
//  alongside glucose.
//
//  DELIBERATELY OMITTED (D-14, binding no-novel-medical-advice rule + §13):
//   • `computeHypoRisk` and the `hypoRiskLevel` / `hypoRiskWindowEnd` state fields — a delayed-
//     hypoglycemia MEDICAL INFERENCE (novel advice surface). Not ported, not recomputed anywhere.
//   • `buildAlcoholPromptContext` — an AI-feeding prompt builder (includes the excluded risk copy).
//  The `currentState` readout is kept PURELY DESCRIPTIVE (current level via the mirror's ~1 drink/hr
//  linear metabolism, 24 h total, count, last intake) — no risk assessment, no directive.
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

/// A purely descriptive alcohol readout: current estimated level (~1 drink/hr linear metabolism), 24 h
/// total, count, and last intake. NO hypo-risk inference, NO warning/directive — informational (D-14).
struct AlcoholState: Equatable {
    let currentDrinkLevel: Double
    let totalDrinksLast24h: Double
    let entriesLast24h: Int
    let lastIntakeTime: Date?
    static let empty = AlcoholState(currentDrinkLevel: 0, totalDrinksLast24h: 0,
                                    entriesLast24h: 0, lastIntakeTime: nil)
}

/// Thin benign alcohol tracker over the shared `GlucoseHistoryStore` (09.18d-02). All mutation and
/// queries go through the store's `ingestAlcohol` / `alcohol(in:)` / `deleteAlcohol` CRUD.
@MainActor
struct LoopInsights_AlcoholTracker {
    /// Linear metabolism rate: ~1 standard drink per hour — the mirror's descriptive decay constant.
    private static let metabolismRate: Double = 1.0
    /// `sourceID` stamped on logged entries (matches `AppModel.trackerSourceID`).
    static let sourceID = "app.loopInsightsTrackers"
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

    /// Update an existing entry, preserving its stable id (delete + re-insert).
    func update(id: String, standardDrinks: Double, source: String, at timestamp: Date) {
        store?.deleteAlcohol(id: id)
        store?.ingestAlcohol(entryID: id, standardDrinks: standardDrinks, source: source,
                             date: timestamp, sourceID: Self.sourceID)
    }

    /// Descriptive current-state readout (informational only — NO hypo-risk inference, D-14). Simulates
    /// the alcohol pool over time: the liver metabolizes ~1 drink/hr while the pool is non-empty.
    func currentState(now: Date = Date()) -> AlcoholState {
        let all = entries(now: now)
        guard !all.isEmpty else { return .empty }
        var total24 = 0.0, count24 = 0
        var lastIntake: Date?
        let dayAgo = now.addingTimeInterval(-24 * 3600)

        // Chronological metabolism simulation for the current descriptive level.
        let chronological = all.sorted { $0.date < $1.date }.filter { $0.date <= now }
        var pool = 0.0
        var lastEventTime: Date?
        for e in chronological {
            if let last = lastEventTime {
                let elapsedHours = e.date.timeIntervalSince(last) / 3600
                pool = max(0, pool - elapsedHours * Self.metabolismRate)
            }
            pool += e.standardDrinks
            lastEventTime = e.date
            if e.date >= dayAgo { total24 += e.standardDrinks; count24 += 1 }
            if lastIntake == nil || e.date > lastIntake! { lastIntake = e.date }
        }
        if let last = lastEventTime {
            let elapsedHours = now.timeIntervalSince(last) / 3600
            pool = max(0, pool - elapsedHours * Self.metabolismRate)
        }
        return AlcoholState(currentDrinkLevel: pool, totalDrinksLast24h: total24,
                            entriesLast24h: count24, lastIntakeTime: lastIntake)
    }
}
