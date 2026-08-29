import Foundation
import faBolusCore

/// Apple Health import/export methods. Stored properties stay on `AppModel`. The whole hook compiles
/// out of the free/CI build (`#if FABOLUS_HEALTHKIT`).
#if FABOLUS_HEALTHKIT

/// Seam `AppModel`'s export hook calls through — lets a test
/// substitute a fake (never touching real `HKHealthStore`) to verify enabled-type routing, mirroring
/// `HealthKitImportSource`'s role on the import side (`Shared/HealthKitHistoryImporter.swift`).
/// `HealthKitExporter` conforms below; `AppModel`'s `#if FABOLUS_HEALTHKIT` property is typed as
/// this protocol, swappable via `setHealthKitExportDestinationForTesting`.
@MainActor
protocol HealthKitExportDestination {
    func exportNewCarbs(_ candidates: [(date: Date, grams: Double)]) async
    func exportNewInsulin(_ candidates: [BolusMarker]) async
    func exportNewGlucose(_ candidates: [GlucoseReading]) async
    func exportHistoricalCarbs(_ entries: [(date: Date, grams: Double)]) async
    func exportHistoricalInsulin(_ markers: [BolusMarker]) async
    func exportHistoricalGlucose(_ readings: [GlucoseReading]) async
}

extension HealthKitExporter: HealthKitExportDestination {}

#endif

extension AppModel {

    #if FABOLUS_HEALTHKIT

    #if DEBUG
    /// Test seam: substitute the HealthKit import source (a fake) so a test can assert
    /// `importFromAppleHealth()`'s routing without touching real HealthKit. Mirrors
    /// `setHistoryStoreForTesting`. Production never calls this.
    func setHealthKitImportSourceForTesting(_ source: HealthKitImportSource) {
        healthKitImportSource = source
    }
    #endif

    /// Manual on-demand "Import from Apple Health" — ALWAYS available regardless of the
    /// automatic toggle below. Imports exactly the per-type-enabled subset over a
    /// 30-day lookback, routing results ONLY into `GlucoseHistoryStore.ingest*` — never
    /// `GlucoseArbiter`/`BolusMath`. Awaitable (unlike the fire-and-forget automatic path)
    /// so a caller — or a test — observes completion.
    public func importFromAppleHealth() async {
        await runHealthKitImport(since: Date().addingTimeInterval(-30 * 86400))
    }

    /// Throttled (hourly), best-effort automatic import — fire-and-forget from `refresh()`,
    /// mirroring `maybeBackfillNightscout`'s shape. Runs ONLY when
    /// `healthKitAutoImportEnabled` is true (default OFF); the manual path above always runs
    /// regardless of this gate. Still called from `AppModel.refresh()`.
    func maybeAutoImportAppleHealth() {
        guard AppSettings.shared.healthKitAutoImportEnabled,
            Date().timeIntervalSince(lastHealthKitAutoImport) > 3600
        else { return }
        lastHealthKitAutoImport = Date()
        Task { [weak self] in await self?.runHealthKitImport(since: Date().addingTimeInterval(-30 * 86400)) }
    }

    /// Shared import routine: imports exactly the per-type-enabled subset over
    /// `[since, Date()]` and routes results ONLY into `GlucoseHistoryStore.ingest*`. Never
    /// registers `healthKitImportSource` with `GlucoseArbiter`/`GlucoseSourceRegistry`'s live set —
    /// this is history ingest only. Glucose gap-fill's `existingSlots` comes from the store's own
    /// merged `glucose(in:)` (already occupied by ANY existing source, live or imported) so an
    /// imported Health reading never double-counts against faBolus's own CGM history.
    private func runHealthKitImport(since: Date) async {
        let settings = AppSettings.shared
        var enabled: Set<HealthKitHistoryImporter.HealthKitImportType> = []
        if settings.healthKitImportCarbsEnabled { enabled.insert(.carbs) }
        if settings.healthKitImportInsulinEnabled { enabled.insert(.insulin) }
        if settings.healthKitImportHeartRateEnabled { enabled.insert(.heartRate) }
        if settings.healthKitImportGlucoseEnabled { enabled.insert(.glucose) }
        guard !enabled.isEmpty else { return }
        let source = healthKitImportSource
        await source.requestAuthorizationIfNeeded(enabledTypes: enabled)
        if enabled.contains(.carbs) {
            let carbs = await source.importCarbHistory(since: since)
            history?.ingestCarbs(carbs, sourceID: "healthkit-import")
        }
        if enabled.contains(.insulin) {
            let insulin = await source.importInsulinHistory(since: since)
            history?.ingestBoluses(
                insulin.map { BolusMarker(date: $0.date, units: $0.units) },
                sourceID: "healthkit-import")
        }
        if enabled.contains(.heartRate) {
            let hr = await source.importHeartRateHistory(since: since)
            history?.ingestHeartRate(hr, sourceID: "healthkit")
        }
        if enabled.contains(.glucose) {
            let existingSlots = Set(
                (history?.glucose(in: since...Date()) ?? [])
                    .map { Int($0.date.timeIntervalSince1970 / 300) })
            let glucose = await source.importGlucoseGapFill(
                since: since, existingSlots: existingSlots,
                sourceID: HealthKitHistoryImporter.glucoseImportSourceID)
            history?.ingestGlucose(glucose, sourceID: HealthKitHistoryImporter.glucoseImportSourceID, priority: 10)
        }
    }

    /// The `sourceID`s `runHealthKitImport` stamps on ingested rows (`"healthkit-import"` for
    /// carbs/insulin/glucose-gap-fill — see `HealthKitHistoryImporter.glucoseImportSourceID` and the
    /// literal ingest calls above; `"healthkit"` for the heart-rate importer, which is never exported
    /// anyway). Passed as `excludingSourceIDs` to EVERY HealthKit *export* read path below —
    /// `HealthKitOriginTag`/`filterOutOwnWrites` already stop faBolus from re-*importing* its own
    /// exported writes; this is the missing other half of the echo-guard, stopping faBolus from
    /// re-*exporting* an entry that was itself just imported FROM Apple Health (which would create a
    /// second, duplicate Health sample rather than update the original — a clinical-confusion risk).
    /// Deliberately NOT applied to `runHealthKitImport`'s `existingSlots` computation above — that
    /// read is for import-side gap-fill dedup, not export, and must keep seeing every source.
    static let healthKitImportSourceIDs: Set<String> = ["healthkit-import", "healthkit"]

    #if DEBUG
    /// Test seam: substitute the HealthKit export destination (a fake) so a test can assert the
    /// go-forward hook's enabled-type routing without touching real HealthKit. Mirrors
    /// `setHealthKitImportSourceForTesting`. Production never calls this.
    func setHealthKitExportDestinationForTesting(_ destination: HealthKitExportDestination) {
        healthKitExportDestination = destination
    }
    #endif

    /// Manual on-demand "Export to Apple Health" backfill over an explicit historical
    /// `[since, Date()]` range — ALWAYS available regardless of the automatic toggle below.
    /// Exports exactly the per-type-enabled subset, reusing `HealthKitExporter`'s historical
    /// write methods (independent of the go-forward high-water marks). Awaitable so a caller — or a
    /// test — observes completion.
    public func exportToAppleHealth(since: Date) async {
        let settings = AppSettings.shared
        let range = since...Date()
        let destination = healthKitExportDestination
        if settings.healthKitExportCarbsEnabled {
            await destination.exportHistoricalCarbs(
                history?.carbs(in: range, excludingSourceIDs: Self.healthKitImportSourceIDs) ?? [])
        }
        if settings.healthKitExportInsulinEnabled {
            await destination.exportHistoricalInsulin(
                history?.boluses(in: range, excludingSourceIDs: Self.healthKitImportSourceIDs) ?? [])
        }
        if settings.healthKitExportGlucoseEnabled {
            await destination.exportHistoricalGlucose(
                history?.glucose(in: range, excludingSourceIDs: Self.healthKitImportSourceIDs) ?? [])
        }
    }

    /// Throttled (mirrors `NightscoutUploader`'s 60 s cadence — this is a near-real-time
    /// "as logged" export, unlike the hourly import backfill), best-effort automatic go-forward
    /// export — fire-and-forget from `refresh()`. Runs ONLY when `healthKitAutoExportEnabled` is
    /// true (default OFF); the manual backfill above always runs regardless of this gate.
    /// Still called from `AppModel.refresh()`.
    func maybeAutoExportAppleHealth() {
        guard AppSettings.shared.healthKitAutoExportEnabled,
            Date().timeIntervalSince(lastHealthKitAutoExport) >= 60
        else { return }
        lastHealthKitAutoExport = Date()
        Task { [weak self] in await self?.runHealthKitAutoExport() }
    }

    /// Shared go-forward export routine: for each enabled export type, hands the CURRENTLY
    /// KNOWN faBolus values (mirrors the `NightscoutUploader.shared.sync(...)` call site's shape —
    /// passing the live in-memory `glucoseHistory`/`bolusMarkers`, plus a wide `history?.carbs(in:)`
    /// window) to `HealthKitExporter`'s `exportNew*` methods, which internally filter to entries
    /// newer than that type's persisted high-water mark and advance it on success — so a relaunch
    /// never re-sends an already-written entry. The carbs window is deliberately WIDE (not a short
    /// recent scrub) because — unlike `glucoseHistory`/`bolusMarkers`, which AppModel already keeps
    /// live in memory — carbs have no equivalent in-memory list; `HealthKitExporter`'s own high-water
    /// mark (not this window) is what does the actual dedup, so passing a superset here is safe and
    /// correct (mirrors `NightscoutUploader.sync`'s own "pass everything, let the mark filter" shape).
    /// Test-observable via `setHealthKitExportDestinationForTesting`; production only reaches this
    /// through the throttled `maybeAutoExportAppleHealth()` fire-and-forget wrapper above.
    func runHealthKitAutoExport() async {
        let settings = AppSettings.shared
        let destination = healthKitExportDestination
        if settings.healthKitExportCarbsEnabled {
            // Exclude HealthKit-imported carbs — this window is the app's ENTIRE carb
            // history (unbounded), so without the exclusion a carb imported from Health on the
            // last import cycle would look "never exported" and get written straight back out.
            let carbs =
                history?.carbs(
                    in: Date.distantPast...Date(),
                    excludingSourceIDs: Self.healthKitImportSourceIDs) ?? []
            await destination.exportNewCarbs(carbs)
        }
        if settings.healthKitExportInsulinEnabled {
            await destination.exportNewInsulin(bolusMarkers)
        }
        if settings.healthKitExportGlucoseEnabled {
            await destination.exportNewGlucose(glucoseHistory)
        }
    }

    #endif
}
