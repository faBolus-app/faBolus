// Adapted from LoopPowerPack/Loop @ ad4c4d498f936a25e22dd3a8dc93354138458509 (MIT)
//
//  LoopInsights_CaffeineTracker.swift — faBolus benign vendored tracker (09.18d-02, D-14/D-17).
//
//  Cherry-picked from the LoopPowerPack `CaffeineTracker`: ONLY the benign log / remove / update /
//  current-state APIs + the entry field shape (milligrams / source / timestamp / stable id). Adapted
//  (not a byte-for-byte port) because persistence is re-pointed from the mirror's UserDefaults to the
//  faBolus SwiftData `GlucoseHistoryStore`, so entries live in HistoryStore and are queryable alongside
//  glucose.
//
//  DELIBERATELY OMITTED (D-14, binding no-novel-medical-advice rule + §13):
//   • `buildCaffeinePromptContext` — an AI-feeding prompt builder (novel advice surface).
//   • `syncFromHealthKit` / `healthKitManager` — HealthKit plumbing (kept Foundation-only).
//  The `currentState` readout is kept as a PURELY DESCRIPTIVE estimate (current level via the mirror's
//  5.7 h half-life decay, 24 h totals, last intake) — no threshold/warning/risk language. Informational
//  only: faBolus never changes a dose.

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

/// A purely descriptive caffeine readout: current estimated level (5.7 h half-life decay), 24 h total,
/// count, and last intake. NO risk assessment, NO directive — informational only (D-14).
struct CaffeineState: Equatable {
    let currentLevelMg: Double
    let totalMgLast24h: Double
    let entriesLast24h: Int
    let lastIntakeTime: Date?
    static let empty = CaffeineState(currentLevelMg: 0, totalMgLast24h: 0,
                                     entriesLast24h: 0, lastIntakeTime: nil)
}

/// Thin benign caffeine tracker over the shared `GlucoseHistoryStore` (09.18d-02). All mutation and
/// queries go through the store's `ingestCaffeine` / `caffeine(in:)` / `deleteCaffeine` CRUD.
@MainActor
struct LoopInsights_CaffeineTracker {
    /// Caffeine half-life in seconds (5.7 hours) — the mirror's descriptive decay constant.
    private static let halfLife: TimeInterval = 5.7 * 3600
    /// `sourceID` stamped on logged entries (matches `AppModel.trackerSourceID`).
    static let sourceID = "app.loopInsightsTrackers"
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

    /// Update an existing entry, preserving its stable id (delete + re-insert).
    func update(id: String, milligrams: Double, source: String, at timestamp: Date) {
        store?.deleteCaffeine(id: id)
        store?.ingestCaffeine(entryID: id, milligrams: milligrams, source: source,
                              date: timestamp, sourceID: Self.sourceID)
    }

    /// Descriptive current-state readout (informational only — no risk assessment, D-14).
    func currentState(now: Date = Date()) -> CaffeineState {
        let all = entries(now: now)
        guard !all.isEmpty else { return .empty }
        var currentLevel = 0.0, total24 = 0.0, count24 = 0
        var lastIntake: Date?
        let dayAgo = now.addingTimeInterval(-24 * 3600)
        for e in all {
            let elapsed = now.timeIntervalSince(e.date)
            if elapsed >= 0 {
                let remaining = e.milligrams * pow(0.5, elapsed / Self.halfLife)
                if remaining > 0.1 { currentLevel += remaining }
            }
            if e.date >= dayAgo { total24 += e.milligrams; count24 += 1 }
            if lastIntake == nil || e.date > lastIntake! { lastIntake = e.date }
        }
        return CaffeineState(currentLevelMg: currentLevel, totalMgLast24h: total24,
                             entriesLast24h: count24, lastIntakeTime: lastIntake)
    }
}
