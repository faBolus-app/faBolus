import Testing
import Foundation
import HealthKit
import faBolusCore
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
}
