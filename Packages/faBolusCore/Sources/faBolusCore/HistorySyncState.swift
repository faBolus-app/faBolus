import Foundation

/// Where pump history sync stands, for the "Pump history sync" section. `PumpSession` emits it as
/// `PumpEvent.historySync`.
public enum HistorySyncState: Sendable, Hashable {
    /// No sync currently active. `lastSynced` is `nil` before the first-ever sync, or the timestamp
    /// of the last completed check (including a check that found nothing missing — a confirmed
    /// up-to-date connect is still a completed sync).
    case idle(lastSynced: Date?)
    /// A gap-fetch is actively paging. Shown only for a long-running sync; a fast routine check
    /// settles back to `.idle` unnoticed.
    case syncing
    /// The sync stopped part way, and continues by itself: the link dropped, the pump's battery is low
    /// in the background, or another history job (a search settling a bolus) went first. The persisted
    /// coverage map credits only what was actually fetched. Not styled as an error.
    case paused
    /// A genuine unexpected failure (e.g. an unparseable history-log frame) — the only case styled red.
    case error(String)
}
