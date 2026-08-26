import Foundation

/// Observable sync state for the "Pump history sync" UI section (D-01/D-05, Phase 09.7-02).
///
/// GO-2 Step 0/1 (16-08, REMED-16, RESEARCH Open Question 3 / Assumption A3): relocated from
/// `TandemBackend.swift` into `faBolusCore` per the owner's move-to-core decision (recorded in
/// `.planning/OWNER-DECISIONS.md` and `.planning/RESUME-2026-08-26.md`) — the additive
/// `PumpHistoryProviding` capability protocol references this type as a property, and a `faBolusCore`
/// protocol cannot reference an app-layer type. `HistorySyncState` is a pure value type with no dose
/// coupling, so the move introduces no new Core↔app entanglement; `TandemBackend`/
/// `PumpHistorySyncCoordinator` (app-concrete) are its only production producers today, surfaced to
/// `AppModel` via the `source as? TandemOnlyOps` mirror pattern already used for
/// `onCommandLatency`/`historySyncState` (GO-1 Step 7, REMED-16).
public enum HistorySyncState: Equatable {
    /// No sync currently active. `lastSynced` is `nil` before the first-ever sync ("Not synced yet" /
    /// "Never"), or the timestamp of the last completed check (including a check that found nothing
    /// missing — a confirmed-up-to-date connect is still a completed sync, D-05).
    case idle(lastSynced: Date?)
    /// A gap-fetch is actively paging. The UI's hybrid progress model (UI-SPEC assumption 1) only shows
    /// this visibly for a long-running sync; a fast routine check settles back to `.idle` unnoticed.
    case syncing
    /// The link dropped mid-sync (UI-SPEC "partial/interrupted" state) — benign and resumable, since the
    /// persisted coverage map (D-04) credits only what was actually fetched. NOT styled as an error.
    case paused
    /// A genuine unexpected failure (e.g. an unparseable history-log frame) — the only case styled red.
    case error(String)
}
