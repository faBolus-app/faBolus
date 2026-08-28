import Foundation

/// Observable sync state for the "Pump history sync" UI section.
///
/// Lives in faBolusCore because `PumpHistoryProviding` exposes it; a Core protocol cannot reference
/// an app-layer type. Pure value — no dose coupling. `TandemBackend` / `PumpHistorySyncCoordinator`
/// produce it; `AppModel` reads it via `source as? PumpHistoryProviding`.
public enum HistorySyncState: Equatable {
    /// No sync currently active. `lastSynced` is `nil` before the first-ever sync, or the timestamp
    /// of the last completed check (including a check that found nothing missing — a confirmed
    /// up-to-date connect is still a completed sync).
    case idle(lastSynced: Date?)
    /// A gap-fetch is actively paging. Shown only for a long-running sync; a fast routine check
    /// settles back to `.idle` unnoticed.
    case syncing
    /// The link dropped mid-sync — benign and resumable. The persisted coverage map credits only
    /// what was actually fetched. Not styled as an error.
    case paused
    /// A genuine unexpected failure (e.g. an unparseable history-log frame) — the only case styled red.
    case error(String)
}
