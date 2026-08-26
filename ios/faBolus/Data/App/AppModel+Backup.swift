import Foundation
import faBolusCore
import HistoryStore

/// Phase 16 GO-1 Step 4 (16-04, REMED-16, R25/R26) — the SiteAtlas + caffeine/alcohol tracker
/// backup/restore (R25) and unified privacy export (R26) METHODS moved verbatim out of
/// `AppModel.swift` into this separate-file extension, with the same `#if FABOLUS_BACKUP` gate
/// preserved exactly. Behavior-preserving: every function body below is an unchanged copy of the
/// original `AppModel` member.
///
/// **D4-07 note:** the vestigial Nightscout backfill (`maybeBackfillNightscout`/`lastNSBackfill`) is
/// NOT carved here — it was DELETED outright from `AppModel.swift` (zero-runtime-reference proof
/// recorded at the deletion site), so no `AppModel+Nightscout.swift` exists.
///
/// **FABOLUS_BACKUP build-matrix note (verified against `scripts/generate-project.sh`, not assumed):**
/// on `main`, `FABOLUS_BACKUP=1` is a documented no-op (the CR-01 gap-closure fix unconditionally
/// drops the `FABOLUS_BACKUP` compile-condition token regardless of the env override, because the 7
/// backup/SiteAtlas app-layer files these methods reference — e.g. `SiteAtlasStore.sourceID` below —
/// were physically `git rm`'d from `main` in 06-02). So, like `FABOLUS_NUDGE`/`FABOLUS_HEALTHKIT`,
/// only the compiled-out (`FABOLUS_BACKUP=0`) state is buildable in-sandbox on `main`; the `#if
/// FABOLUS_BACKUP` gate is preserved verbatim for `dev/backup`'s own build (files present, flag on).
///
/// **Review concern #1:** the one instance stored property these methods touch, `history`, was
/// already widened `private`->`internal` in `AppModel.swift` by the eating-nudge/HealthKit carve
/// above (it needed it too). `buildPrivacyExport` reads the delivery ledger via the new
/// `privacyExportLedgerSnapshot` read-only seam declared next to `deliveryLedgerCoordinator` in
/// `AppModel.swift`, NOT by widening the coordinator itself — `deliveryLedgerCoordinator` is
/// dose-adjacent (it owns `runLedgeredDelivery`/the global delivery-block gate) and stays `private`.
/// `Self.trackerSourceID` is a `static let`, which Swift allows a separate-file extension to declare
/// directly, so it moves here with zero access change. None of the 6 methods below has any caller
/// elsewhere in `AppModel.swift` — their only production callers (`BackupRestoreView.createBackup()`/
/// `RestoreSheet`) were themselves `git rm`'d in 06-02 (see `BackupRemovalBoundaryTests`) — so no
/// function-level access change was needed for the move itself.
extension AppModel {

    // MARK: WR-01 — SiteAtlas ⇄ unified backup
#if FABOLUS_BACKUP

    /// Snapshot every logged SiteAtlas placement for the unified backup (schema 2+). Reads the SAME
    /// shared store the UI writes and the export reads, so a `.faBolus` backup reflects exactly the
    /// placements on screen. Called by `BackupRestoreView.createBackup()`.
    func siteAtlasBackup() -> SiteAtlasBackup {
        let sites = history?.allSites() ?? []
        return SiteAtlasBackup(entries: sites.map {
            SiteAtlasEntryBackup(siteID: $0.siteID, kind: $0.kind, bodySide: $0.bodySide,
                                 normalizedX: $0.normalizedX, normalizedY: $0.normalizedY,
                                 note: $0.note, date: $0.date)
        })
    }

    /// Rehydrate SiteAtlas placements from a restored backup into the shared store, preserving each
    /// original stable `siteID`/`date` so a restored placement is identical to the backed-up one.
    /// Additive (existing rows untouched), mirroring the other restore sections. Called by `RestoreSheet`.
    func restoreSiteAtlas(_ backup: SiteAtlasBackup) {
        guard let history else { return }
        for e in backup.entries {
            history.ingestSite(siteID: e.siteID, kind: e.kind, bodySide: e.bodySide,
                               normalizedX: e.normalizedX, normalizedY: e.normalizedY,
                               note: e.note, date: e.date, sourceID: SiteAtlasStore.sourceID)
        }
    }
#endif

    // MARK: 09.18d-02 — caffeine/alcohol benign trackers ⇄ unified backup (D-14/D-17)
#if FABOLUS_BACKUP

    /// `sourceID` stamped on tracker entries so they are attributable in export/backup (mirrors
    /// `SiteAtlasStore.sourceID`). Benign log data only. IN-02: aliases the single shared constant on
    /// `GlucoseHistoryStore` so the literal lives in exactly one place.
    static let trackerSourceID = GlucoseHistoryStore.loopInsightsTrackerSourceID

    /// Snapshot every logged caffeine + alcohol entry for the unified backup (schema 3+). Reads the
    /// SAME shared store the tracker log views write and the export reads. Benign fields only — no
    /// risk inference (D-14). Called by `BackupRestoreView.createBackup()`.
    func trackersBackup() -> TrackerBackup {
        let wide = Date(timeIntervalSince1970: 0)...Date().addingTimeInterval(86400)
        let caffeine = history?.caffeine(in: wide) ?? []
        let alcohol = history?.alcohol(in: wide) ?? []
        return TrackerBackup(
            caffeine: caffeine.map { CaffeineEntryBackup(entryID: $0.entryID, milligrams: $0.milligrams,
                                                         source: $0.source, date: $0.date) },
            alcohol: alcohol.map { AlcoholEntryBackup(entryID: $0.entryID, standardDrinks: $0.standardDrinks,
                                                      source: $0.source, date: $0.date) })
    }

    /// Rehydrate caffeine + alcohol tracker entries from a restored backup into the shared store,
    /// preserving each original stable `entryID`/`date`. L-02: upsert (delete-by-`entryID` then insert)
    /// rather than blind-append — SwiftData does not enforce `entryID` uniqueness, so a double restore of
    /// the same backup would otherwise create duplicate rows sharing an id (visible in the log list until
    /// a predicate-delete removes both). Keying on the stable `entryID` makes restore idempotent.
    func restoreTrackers(_ backup: TrackerBackup) {
        guard let history else { return }
        for e in backup.caffeine {
            history.deleteCaffeine(id: e.entryID)
            history.ingestCaffeine(entryID: e.entryID, milligrams: e.milligrams, source: e.source,
                                   date: e.date, sourceID: Self.trackerSourceID)
        }
        for e in backup.alcohol {
            history.deleteAlcohol(id: e.entryID)
            history.ingestAlcohol(entryID: e.entryID, standardDrinks: e.standardDrinks, source: e.source,
                                  date: e.date, sourceID: Self.trackerSourceID)
        }
    }
#endif

    // MARK: F1 (§13) — unified export of on-device health data
#if FABOLUS_BACKUP

    /// Assemble the unified on-device health-data export: glucose/insulin/carb history + the setting-change
    /// provenance log + the remote-bolus ledger audit trail. Pure read; safe to call any time.
    /// (`internal`, not `public`: `PrivacyDataExport` is an app-module type.)
    func buildPrivacyExport(now: Date = Date()) -> PrivacyDataExport {
        // A window wide enough to capture the entire persisted history.
        let all = Date(timeIntervalSince1970: 0)...now.addingTimeInterval(86400)
        let g = history?.glucose(in: all) ?? []
        let b = history?.boluses(in: all) ?? []
        let c = history?.carbs(in: all) ?? []
        let s = history?.sites(in: all) ?? []
        let caf = history?.caffeine(in: all) ?? []
        let alc = history?.alcohol(in: all) ?? []
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        return PrivacyDataExport(
            meta: .init(createdAt: now, appVersion: version, schemaVersion: PrivacyDataExport.currentSchema),
            glucose: g.map { .init(date: $0.date, mgdl: $0.mgdl) },
            boluses: b.map { .init(date: $0.date, units: $0.units) },
            carbs: c.map { .init(date: $0.date, grams: $0.grams) },
            sites: s.map { .init(siteID: $0.siteID, kind: $0.kind, bodySide: $0.bodySide,
                                 normalizedX: $0.normalizedX, normalizedY: $0.normalizedY,
                                 note: $0.note, date: $0.date) },
            caffeine: caf.map { .init(date: $0.date, milligrams: $0.milligrams, source: $0.source) },
            alcohol: alc.map { .init(date: $0.date, standardDrinks: $0.standardDrinks, source: $0.source) },
            settingChangeLog: settingChangeStore.load(),
            remoteBolusLedger: privacyExportLedgerSnapshot)
    }

    /// Encode the unified export as one shareable JSON payload (for the Privacy & data → Export action).
    func exportPrivacyDataJSON(now: Date = Date()) throws -> Data {
        try buildPrivacyExport(now: now).encoded()
    }
#endif
}
