import Testing
import Foundation
import HealthKit
import faBolusCore
import HistoryStore
@testable import faBolus

/// Phase 09.23-03 (Task 1, D-08/D-12/D-14): pure-logic proof for the full multi-type exporter —
/// carbs + glucose write shapes (extending the Wave 1 tracer's bolus-only exporter), the per-type
/// high-water-mark dedup selector, the echo-guard round-trip closing the D-12 loop, and D-08's
/// hard "no heart-rate export" guarantee. Every asserted function is `nonisolated static` and
/// PURE — these tests construct plain in-memory metadata dictionaries / `HKQuantitySample`s (never
/// touch `HKHealthStore.execute`/`.save`), so no entitlement/authorization is needed, and they run
/// under the default `FABOLUS_HEALTHKIT` OFF build (D-13 — `HealthKitExporter` is NOT `#if`-gated;
/// only the pre-existing HealthKit CGM/HR call sites are).
@MainActor
struct HealthKitExporterTests {

    // MARK: - Behavior 1: carb write shape — sync-identifier + origin key, NO delivery-reason

    @Test func carbMetadataCarriesSyncIdentifierAndOriginTagButNoDeliveryReason() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let metadataA = HealthKitExporter.carbMetadata(date: date, grams: 30)
        let metadataB = HealthKitExporter.carbMetadata(date: date, grams: 30)   // same (date, grams) again

        #expect(metadataA[HealthKitOriginTag.key] as? Bool == true)
        #expect(metadataA[HKMetadataKeySyncVersion] != nil)
        #expect(metadataA[HKMetadataKeyInsulinDeliveryReason] == nil,
                "carbs are not insulin deliveries — no delivery-reason metadata")

        let idA = metadataA[HKMetadataKeySyncIdentifier] as? String
        let idB = metadataB[HKMetadataKeySyncIdentifier] as? String
        #expect(idA != nil)
        #expect(idA == idB)   // stable per (date, grams)

        let differentGrams = HealthKitExporter.carbMetadata(date: date, grams: 45)
        #expect((differentGrams[HKMetadataKeySyncIdentifier] as? String) != idA)
    }

    // MARK: - Behavior 2: glucose write shape — sync-identifier + origin key

    @Test func glucoseMetadataCarriesSyncIdentifierAndOriginTag() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let metadataA = HealthKitExporter.glucoseMetadata(date: date, mgdl: 120)
        let metadataB = HealthKitExporter.glucoseMetadata(date: date, mgdl: 120)   // same (date, mgdl) again

        #expect(metadataA[HealthKitOriginTag.key] as? Bool == true)
        #expect(metadataA[HKMetadataKeySyncVersion] != nil)

        let idA = metadataA[HKMetadataKeySyncIdentifier] as? String
        let idB = metadataB[HKMetadataKeySyncIdentifier] as? String
        #expect(idA != nil)
        #expect(idA == idB)   // stable per (date, mgdl)

        let differentMgdl = HealthKitExporter.glucoseMetadata(date: date, mgdl: 180)
        #expect((differentMgdl[HKMetadataKeySyncIdentifier] as? String) != idA)
    }

    // MARK: - Behavior 3: per-type high-water dedup — returns only entries newer than the mark,
    // advances the mark to the newest kept entry

    @Test func highWaterMarkSelectorKeepsOnlyEntriesNewerThanTheMarkAndAdvancesToTheNewest() {
        struct Candidate { let epoch: Double }
        let mark: Double = 1_000
        let candidates = [
            Candidate(epoch: 500),    // older than the mark — dropped
            Candidate(epoch: 1_000),  // exactly at the mark — dropped (not STRICTLY newer)
            Candidate(epoch: 1_500),  // newer — kept
            Candidate(epoch: 2_000),  // newer, and the newest — kept, becomes the new mark
        ]

        let (kept, newMark) = HealthKitExporter.newerThanMark(candidates, mark: mark) { $0.epoch }

        #expect(kept.map(\.epoch) == [1_500, 2_000])
        #expect(newMark == 2_000)
    }

    @Test func highWaterMarkSelectorLeavesMarkUnchangedWhenNothingQualifies() {
        struct Candidate { let epoch: Double }
        let mark: Double = 1_000
        let candidates = [Candidate(epoch: 200), Candidate(epoch: 999)]

        let (kept, newMark) = HealthKitExporter.newerThanMark(candidates, mark: mark) { $0.epoch }

        #expect(kept.isEmpty)
        #expect(newMark == mark)
    }

    // MARK: - Behavior 4: echo closure — an exporter-built carb/glucose sample is dropped by the
    // importer's echo-guard filter (uses the same shared origin constant)

    @Test func exporterBuiltCarbSampleIsDroppedByImporterEchoGuard() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = HealthKitExporter.carbMetadata(date: date, grams: 30)
        let quantity = HKQuantity(unit: .gram(), doubleValue: 30)
        let exported = HKQuantitySample(type: HKQuantityType(.dietaryCarbohydrates), quantity: quantity,
                                        start: date, end: date, metadata: metadata)

        let kept = HealthKitHistoryImporter.filterOutOwnWrites([exported])

        #expect(kept.isEmpty)
    }

    @Test func exporterBuiltGlucoseSampleIsDroppedByImporterEchoGuard() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = HealthKitExporter.glucoseMetadata(date: date, mgdl: 120)
        let quantity = HKQuantity(unit: HKUnit(from: "mg/dL"), doubleValue: 120)
        let exported = HKQuantitySample(type: HKQuantityType(.bloodGlucose), quantity: quantity,
                                        start: date, end: date, metadata: metadata)

        let kept = HealthKitHistoryImporter.filterOutOwnWrites([exported])

        #expect(kept.isEmpty)
    }

    // MARK: - Behavior 5 (D-08): the exporter exposes NO heart-rate export path whatsoever — a
    // source-scan scope-guard (mirrors HealthKitImportDosePathGuardTests' #filePath-rooted scan) so
    // a future edit can't silently add HR export without this guard turning red.

    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("Shared/HealthKitExporter.swift")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    @Test func exporterSourceContainsNoHeartRateExportPath() throws {
        let root = try #require(Self.repoRootURL(),
                                "could not resolve the repo root from #filePath=\(#filePath)")
        let url = root.appendingPathComponent("Shared/HealthKitExporter.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "could not resolve Shared/HealthKitExporter.swift — path resolution likely broke")
        #expect(source.count > 200, "resolved source implausibly short — path resolution likely broke")
        #expect(!source.lowercased().contains("heartrate"),
                "D-08 violated — HealthKitExporter must never expose a heart-rate export method/type; HR is read-only")
    }

    // MARK: - Task 2 Behavior 1: AppSettings per-type export toggles default to false, no HR toggle

    @Test func healthKitExportTogglesDefaultToFalseAndNoHeartRateToggleExists() {
        let suiteName = "HealthKitExporterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        #expect(settings.healthKitExportCarbsEnabled == false)
        #expect(settings.healthKitExportInsulinEnabled == false)
        #expect(settings.healthKitExportGlucoseEnabled == false)
        #expect(settings.healthKitAutoExportEnabled == false, "D-12: automatic export defaults OFF")
    }

    @Test func healthKitExportTogglesPersistThroughUserDefaultsAcrossInstances() {
        let suiteName = "HealthKitExporterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = AppSettings(defaults: defaults)
        first.healthKitExportCarbsEnabled = true
        first.healthKitAutoExportEnabled = true

        let second = AppSettings(defaults: defaults)   // simulates a relaunch reading the same suite
        #expect(second.healthKitExportCarbsEnabled == true)
        #expect(second.healthKitExportInsulinEnabled == false)
        #expect(second.healthKitAutoExportEnabled == true)
    }

    /// Source-scan companion to `exporterSourceContainsNoHeartRateExportPath` — AppSettings itself
    /// must never grow a `healthKitExportHeartRate*` toggle either (D-08).
    @Test func appSettingsSourceContainsNoHeartRateExportToggle() throws {
        let root = try #require(Self.repoRootURL(),
                                "could not resolve the repo root from #filePath=\(#filePath)")
        let url = root.appendingPathComponent("ios/faBolus/Data/AppSettings.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "could not resolve ios/faBolus/Data/AppSettings.swift — path resolution likely broke")
        #expect(!source.contains("healthKitExportHeartRate"),
                "D-08 violated — AppSettings must never expose a healthKitExportHeartRate* toggle; HR is read-only")
    }

    // MARK: - Task 2 Behavior 2 (FABOLUS_HEALTHKIT only): go-forward export hook routes only
    // enabled types' CURRENT values to HealthKitExporter, and never re-sends already-marked
    // entries (proved via the exporter's own high-water-mark selector — Task 1's `newerThanMark`).

    #if FABOLUS_HEALTHKIT
    private func makeModel() -> (AppModel, MockBackend) {
        let backend = MockBackend()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        return (AppModel(source: backend, ledgerStoreURL: url), backend)
    }

    /// A fake `HealthKitExportDestination` — never touches real `HKHealthStore`. Records exactly
    /// which per-type methods were called and with what candidates, proving the enabled-only subset
    /// (and ONLY the enabled-only subset) reaches the seam (D-14), and that a never-called method
    /// received nothing (a disabled type's data never reaches the exporter at all).
    private final class FakeHealthKitExportDestination: HealthKitExportDestination {
        private(set) var newCarbsCalls: [[(date: Date, grams: Double)]] = []
        private(set) var newInsulinCalls: [[BolusMarker]] = []
        private(set) var newGlucoseCalls: [[GlucoseReading]] = []
        private(set) var historicalCarbsCalls: [[(date: Date, grams: Double)]] = []
        private(set) var historicalInsulinCalls: [[BolusMarker]] = []
        private(set) var historicalGlucoseCalls: [[GlucoseReading]] = []

        func exportNewCarbs(_ candidates: [(date: Date, grams: Double)]) async { newCarbsCalls.append(candidates) }
        func exportNewInsulin(_ candidates: [BolusMarker]) async { newInsulinCalls.append(candidates) }
        func exportNewGlucose(_ candidates: [GlucoseReading]) async { newGlucoseCalls.append(candidates) }
        func exportHistoricalCarbs(_ entries: [(date: Date, grams: Double)]) async { historicalCarbsCalls.append(entries) }
        func exportHistoricalInsulin(_ markers: [BolusMarker]) async { historicalInsulinCalls.append(markers) }
        func exportHistoricalGlucose(_ readings: [GlucoseReading]) async { historicalGlucoseCalls.append(readings) }
    }

    @Test func goForwardExportHookRoutesOnlyEnabledTypesToTheExporter() async throws {
        let (model, _) = makeModel()
        let store = try GlucoseHistoryStore(inMemory: true)
        model.setHistoryStoreForTesting(store)

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        store.ingestCarbs([(date: t0, grams: 30)], sourceID: "fabolus")

        AppSettings.shared.healthKitExportCarbsEnabled = true
        AppSettings.shared.healthKitExportInsulinEnabled = false
        AppSettings.shared.healthKitExportGlucoseEnabled = false
        defer { AppSettings.shared.healthKitExportCarbsEnabled = false }

        let fake = FakeHealthKitExportDestination()
        model.setHealthKitExportDestinationForTesting(fake)

        await model.runHealthKitAutoExport()

        #expect(fake.newCarbsCalls.count == 1, "carbs export is enabled — the exporter must be called exactly once")
        #expect(fake.newCarbsCalls.first?.map(\.grams) == [30])
        #expect(fake.newInsulinCalls.isEmpty, "insulin export is disabled — the exporter must never be called")
        #expect(fake.newGlucoseCalls.isEmpty, "glucose export is disabled — the exporter must never be called")
    }
    #endif
}
