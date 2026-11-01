import Foundation
import faBolusCore

/// Clinician-edit disclosure sidecar. Owns `settingChangeStore` and the last-manual-mode-change
/// stamp. Provenance only — never a gate on the therapy write it annotates; this type never reads
/// `lastError` and holds no back-pointer to `AppModel`.
@MainActor
final class ClinicianEditProvenanceRecorder {

    /// The provenance / change-log sidecar (S7). Test-injectable (a test swaps in a unique/failing
    /// store); production uses the App-Group-backed store. Best-effort + fail-open by construction
    /// (`StoredSettingChangeStore.record`/`saveBestEffort` never throw/block) — provenance is
    /// disclosure, never a gate on the therapy write it annotates.
    var settingChangeStore: StoredSettingChangeStore

    /// P16 S3 — when the user last changed the pump's activity/sleep mode BY HAND (from the Pump
    /// Control UI). Stamped ONLY by `noteManualModeChange` (called from the mode buttons) — never by
    /// `ModeAutomation`'s automated apply — so scheduled automation can tell "the user just did this
    /// themselves" from "we did it".
    private var lastManualModeChangeAt: Date?

    init(
        settingChangeStore: StoredSettingChangeStore = StoredSettingChangeStore(
            url: StoredSettingChangeStore.defaultURL(appGroupID: WidgetStore.appGroup)
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("setting-change-log.json"))
    ) {
        self.settingChangeStore = settingChangeStore
    }

    /// Record a user-made clinician-tier edit as `.selfSet` — but ONLY when `succeeded` is true (the
    /// caller's own `lastError == nil` check at the moment of the write, taken as a VALUE — this type
    /// never reads `lastError` itself) AND the value actually changed. So a blocked, failed, or no-op
    /// edit records nothing.
    func recordClinicianEditIfChanged(
        _ key: SettingKey, before: BackupValue?, afterOnSuccess after: BackupValue,
        succeeded: Bool
    ) {
        guard succeeded, before != after else { return }
        settingChangeStore.record(
            StoredSettingChange(
                key: key, before: before, after: after, provenance: .selfSet,
                atSeconds: Int(Date().timeIntervalSince1970)))
    }

    /// §2.1(2): record `.selfSet` provenance for each CHANGED therapy field of a profile segment. Keyed
    /// on the segment's START TIME — its stable identity across the pump's index-renumbering (S7 /
    /// `SettingKey` doc). Fail-open and only on a successful, value-changing edit (both guarded by
    /// `recordClinicianEditIfChanged`).
    func recordSegmentEditIfChanged(
        idpId: Int, startMinutes: Int,
        beforeBasal: Double?, afterBasal: Double,
        beforeCR: Double?, afterCR: Double,
        beforeISF: Int?, afterISF: Int,
        beforeTarget: Int?, afterTarget: Int,
        succeeded: Bool
    ) {
        func key(_ f: String) -> SettingKey { .segment(idpId: idpId, startMinutes: startMinutes, field: f) }
        recordClinicianEditIfChanged(
            key("basalRate"), before: beforeBasal.map(BackupValue.double),
            afterOnSuccess: .double(afterBasal), succeeded: succeeded)
        recordClinicianEditIfChanged(
            key("carbRatio"), before: beforeCR.map(BackupValue.double),
            afterOnSuccess: .double(afterCR), succeeded: succeeded)
        recordClinicianEditIfChanged(
            key("isf"), before: beforeISF.map(BackupValue.int),
            afterOnSuccess: .int(afterISF), succeeded: succeeded)
        recordClinicianEditIfChanged(
            key("targetBg"), before: beforeTarget.map(BackupValue.int),
            afterOnSuccess: .int(afterTarget), succeeded: succeeded)
    }

    /// §2.1(2) B1(a): the per-field provenance for one profile segment, for the editor's origin badges.
    /// Keyed by the SAME field names `recordSegmentEditIfChanged` writes (`basalRate`/`carbRatio`/`isf`/
    /// `targetBg`). A field with no record is `.consensusDefault` (absence == consensus default, per
    /// `StoredSettingChange`). Returns `nil` when the store failed closed (corrupt) — the UI then shows
    /// NO badge rather than mislabeling every value as a consensus default. Pure read; never gates
    /// anything.
    func segmentFieldProvenance(idpId: Int, startMinutes: Int) -> [String: SettingProvenance]? {
        let outcome = settingChangeStore.loadOutcome()
        if outcome.failedClosed { return nil }
        func p(_ f: String) -> SettingProvenance {
            outcome.log.provenance(.segment(idpId: idpId, startMinutes: startMinutes, field: f)) ?? .consensusDefault
        }
        return ["basalRate": p("basalRate"), "carbRatio": p("carbRatio"), "isf": p("isf"), "targetBg": p("targetBg")]
    }

    /// B1(c): record an explicit `.consensusDefault` baseline (`before == nil`) for each therapy field of
    /// a segment that has NO record yet — so every value carries an explicit origin and a one-tap-revert
    /// anchor even if the user never edited it. **Idempotent:** a field that already has any record (a
    /// prior baseline OR a real `.selfSet` edit) is skipped, so a re-read never re-baselines and never
    /// overwrites `.selfSet` provenance. Baselines go to `latest` only (`recordBaseline`), never the
    /// visible audit trail. Fail-open: skipped entirely when the store failed closed (don't scribble on
    /// an unreadable store), and `recordBaseline` never throws. Keyed on the segment START TIME (its
    /// stable identity). Unconditional on any write-success bit — a profile READ, not a gated write.
    func recordConsensusBaselineIfAbsent(
        idpId: Int, startMinutes: Int,
        basalRate: Double, carbRatio: Double, isf: Int, targetBg: Int
    ) {
        let outcome = settingChangeStore.loadOutcome()
        if outcome.failedClosed { return }
        let now = Int(Date().timeIntervalSince1970)
        func baseline(_ field: String, _ value: BackupValue) {
            let key = SettingKey.segment(idpId: idpId, startMinutes: startMinutes, field: field)
            guard outcome.log.current(key) == nil else { return }
            settingChangeStore.recordBaseline(
                StoredSettingChange(
                    key: key, before: nil, after: value, provenance: .consensusDefault, atSeconds: now))
        }
        baseline("basalRate", .double(basalRate))
        baseline("carbRatio", .double(carbRatio))
        baseline("isf", .int(isf))
        baseline("targetBg", .int(targetBg))
    }

    /// Record a manual (user-initiated) activity/sleep mode change for P16 S3 manual-precedence. The
    /// `at` clock is injectable (matching the codebase's `now:`/`add:` convention); production stamps now.
    func noteManualModeChange(at: Date = Date()) { lastManualModeChangeAt = at }

    /// P16 S3 — the max of the most recent recorded clinician-tier setting edit (excluding
    /// consensus-default baselines, which are stamped at profile-READ time, not at a user edit) and the
    /// last manual mode change. `AppModel.lastManualTherapyActionAt` additionally folds in
    /// `snapshot.lastBolusDate`, which lives outside this recorder (it's pump-derived, not
    /// provenance-store state). nil ⇒ no known manual action recorded by this sidecar. Disclosure only
    /// — never gates delivery.
    func latestManualEditOrModeChange() -> Date? {
        var candidates: [Date] = []
        if let latestEditSeconds = settingChangeStore.load().latest
            .filter({ $0.provenance != .consensusDefault }).map(\.atSeconds).max()
        {
            candidates.append(Date(timeIntervalSince1970: Double(latestEditSeconds)))
        }
        if let mode = lastManualModeChangeAt { candidates.append(mode) }
        return candidates.max()
    }
}
