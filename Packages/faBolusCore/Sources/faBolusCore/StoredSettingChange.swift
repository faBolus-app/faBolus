import Foundation

/// P14 Slice 7 — provenance + change-log record model for therapy settings (§2.1(3)(4)).
///
/// This is the DATA the §2.1 provenance/change-log/revert features read. Off-pump by necessity (C11):
/// a `PumpProfileSegment` is wiped and rebuilt from the pump on every refresh, so provenance can't live
/// on it. It also can't be a `HistoryStore` `@Model` (SwiftData) — that clashes with the atomic-JSON /
/// fail-closed persistence this needs — so it's a standalone sidecar (`StoredSettingChangeStore`,
/// modeled on `RemoteBolusLedgerStore`). Pure record + query; no wiring to the therapy-edit path yet
/// (that lands with S6/S8).

/// §13 provenance vocabulary (chosen over §2.1's "unchanged": a consensus default IS a provenance; the
/// absence of a record is what "unchanged" means).
public enum SettingProvenance: String, Codable, Sendable, CaseIterable {
    case consensusDefault  // a published/guideline default the user never changed
    case clinicianSet  // set with clinical guidance (the §2.1 clinician tier)
    case selfSet  // the user set it themselves

    /// §2.1(2) B1(a) — the SF Symbol paired with `ClinicianTierAck.label(for:)` so the provenance badge
    /// carries a non-color cue too (a book for a published default, a stethoscope for clinician-set, a
    /// person for self-set). Pure data; the view renders it via `Image(systemName:)`.
    public var symbolName: String {
        switch self {
        case .consensusDefault: return "book.closed"
        case .clinicianSet: return "stethoscope"
        case .selfSet: return "person.fill"
        }
    }
}

/// Stable identity for a tracked therapy setting.
///
/// Keyed on the segment's **start time** (minutes past midnight), NOT its array index.
/// The pump renumbers segment indices when one is deleted (`TandemBackend` rebuilds the array), so an
/// index key would silently re-point a record at the wrong segment after a delete. A segment's start
/// time is its natural identity and is unique within a profile, so it survives renumbering — no
/// post-refresh index-remap reconcile is needed. Profile-level and global settings (max bolus/basal,
/// Control-IQ) use `segmentStartMinutes == nil`; a global (non-profile) setting also uses `idpId == nil`.
public struct SettingKey: Codable, Sendable, Hashable {
    public var idpId: Int?
    public var segmentStartMinutes: Int?
    public var field: String

    public init(idpId: Int? = nil, segmentStartMinutes: Int? = nil, field: String) {
        self.idpId = idpId
        self.segmentStartMinutes = segmentStartMinutes
        self.field = field
    }

    /// A global (non-profile) setting: `maxBolus`, `maxBasal`, `controlIQ`, …
    public static func global(_ field: String) -> SettingKey { SettingKey(field: field) }
    /// A per-segment therapy value keyed on the segment's stable start time.
    public static func segment(idpId: Int, startMinutes: Int, field: String) -> SettingKey {
        SettingKey(idpId: idpId, segmentStartMinutes: startMinutes, field: field)
    }
}

/// One recorded change to a tracked setting: the before/after values (for the §2.1(4) one-tap revert),
/// its provenance, and when it happened. `atSeconds` is Unix seconds passed IN by the caller — the store
/// never reads the wall clock, so tests are deterministic. `before == nil` marks the first record for a key.
public struct StoredSettingChange: Codable, Sendable, Equatable {
    public var key: SettingKey
    public var before: BackupValue?
    public var after: BackupValue
    public var provenance: SettingProvenance
    public var atSeconds: Int

    public init(
        key: SettingKey, before: BackupValue?, after: BackupValue,
        provenance: SettingProvenance, atSeconds: Int
    ) {
        self.key = key
        self.before = before
        self.after = after
        self.provenance = provenance
        self.atSeconds = atSeconds
    }
}

/// The persisted container: the current record per key (provenance + revert target) plus a bounded,
/// chronological audit log (the §2.1(3) exportable change-log). Kept as flat arrays (not a
/// `[SettingKey: …]` dictionary) so the JSON stays clean — a struct dictionary key would encode as an
/// awkward alternating array.
public struct SettingChangeLog: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    /// The most recent change per key — the current provenance + the one-tap-revert target.
    public var latest: [StoredSettingChange]
    /// Chronological audit trail (oldest first), bounded by the store's cap.
    public var log: [StoredSettingChange]

    public init(
        version: Int = SettingChangeLog.currentVersion,
        latest: [StoredSettingChange] = [], log: [StoredSettingChange] = []
    ) {
        self.version = version
        self.latest = latest
        self.log = log
    }

    /// Record a change: replace the key's `latest` entry and append to the audit log (trimming the oldest
    /// when over `cap`). Appending, never mutating in place, so the audit trail is honest.
    public mutating func record(_ change: StoredSettingChange, cap: Int) {
        latest.removeAll { $0.key == change.key }
        latest.append(change)
        log.append(change)
        if log.count > cap { log.removeFirst(log.count - cap) }
    }

    /// B1(c) — set a key's baseline/current record WITHOUT appending to the visible audit trail. Used for
    /// the §2.1(4) consensus-default snapshot (`before == nil`, `.consensusDefault`) so an unedited value
    /// still carries an explicit origin + a one-tap-revert anchor, without flooding the change-log with a
    /// "— → value" row per field or consuming the audit-trail cap. Only replaces `latest`; a subsequent
    /// real `record` overwrites this baseline for the key. No-op'd by callers unless the key is unrecorded.
    public mutating func setBaseline(_ change: StoredSettingChange) {
        latest.removeAll { $0.key == change.key }
        latest.append(change)
    }

    /// B1(c) — prune audit-log entries older than the retention window. Applied ALONGSIDE the count cap
    /// (both bounds hold). NEVER touches `latest`: a key's current provenance + one-tap-revert target must
    /// survive regardless of age, so a long-untouched setting stays revertible. Pure — `nowSeconds` is
    /// passed in (the store uses the recording change's own timestamp as "now").
    public mutating func pruneExpired(retentionSeconds: Int, nowSeconds: Int) {
        let cutoff = nowSeconds - retentionSeconds
        log.removeAll { $0.atSeconds < cutoff }
    }

    /// The current record for a key (nil ⇒ never changed ⇒ treat as consensus-default).
    public func current(_ key: SettingKey) -> StoredSettingChange? { latest.last { $0.key == key } }
    /// The current provenance for a key (nil ⇒ never recorded).
    public func provenance(_ key: SettingKey) -> SettingProvenance? { current(key)?.provenance }

    /// B1(c) — the one-tap-revert target for a key: the `before` value of its most recent change, or nil
    /// when the key was never changed from its baseline (a pure consensus-default snapshot has `before ==
    /// nil`, so there is nothing to revert to). Pure lookup; the caller re-applies it through the gated
    /// therapy-write funnel.
    public func revertTarget(_ key: SettingKey) -> BackupValue? { current(key)?.before }
    /// The full chronological history for a key (for the change-log view / export).
    public func history(_ key: SettingKey) -> [StoredSettingChange] { log.filter { $0.key == key } }

    /// B1(b) — the entire audit trail, NEWEST FIRST, for the §2.1(3) change-log view.
    public func history() -> [StoredSettingChange] { log.reversed() }

    /// B1(b) — a deterministic, shareable plain-text rendering of the whole change-log (newest first).
    /// Timestamps are ISO-8601 **UTC** so the export is portable and the text is test-stable regardless of
    /// device locale/zone; the on-screen view formats dates for the device separately. Pure.
    public func exportText() -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        let entries = history()
        var lines = [
            "faBolus setting change log — \(entries.count) entr\(entries.count == 1 ? "y" : "ies") (newest first)"
        ]
        for c in entries {
            let when = iso.string(from: Date(timeIntervalSince1970: TimeInterval(c.atSeconds)))
            let before = c.before?.displayString ?? "—"
            lines.append(
                "\(when) · \(c.key.field): \(before) → \(c.after.displayString) (\(ClinicianTierAck.label(for: c.provenance)))"
            )
        }
        return lines.joined(separator: "\n")
    }
}
