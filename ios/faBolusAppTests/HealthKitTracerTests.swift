import Testing
import Foundation
import HealthKit
import faBolusCore
@testable import faBolus

/// Phase 09.23-01 (D-05/D-07/D-08/D-12, the phase TRACER): pure-logic + round-trip proof for the
/// carbs-import / bolus-export vertical slice. `HealthKitHistoryImporter`'s echo-guard filter and
/// carb-mapping, and `HealthKitExporter`'s bolus-metadata builder, are ALL `nonisolated static` pure
/// functions — these tests construct plain in-memory `HKQuantitySample`/`HKQuantity` objects (never
/// touches `HKHealthStore.execute`/`.save`, so no entitlement/authorization is needed) and run under
/// the default `FABOLUS_HEALTHKIT` OFF build (D-13 — these services are NOT `#if`-gated; only the
/// pre-existing HealthKit CGM/HR call sites are).
@MainActor
struct HealthKitTracerTests {
    private let carbType = HKQuantityType(.dietaryCarbohydrates)
    private let gramUnit = HKUnit.gram()

    private func carbSample(grams: Double, date: Date = Date(), origin: Bool? = nil) -> HKQuantitySample {
        let metadata: [String: Any]? = origin.map { [HealthKitOriginTag.key: $0] }
        let quantity = HKQuantity(unit: gramUnit, doubleValue: grams)
        return HKQuantitySample(type: carbType, quantity: quantity, start: date, end: date, metadata: metadata)
    }

    // MARK: - Behavior 1: echo-guard filter drops origin-tagged samples, keeps the rest

    @Test func echoGuardFilterDropsOriginTaggedSamplesAndKeepsTheRest() {
        let untaggedA = carbSample(grams: 30)
        let taggedFromExporter = carbSample(grams: 12, origin: true)
        let untaggedB = carbSample(grams: 45)

        let kept = HealthKitHistoryImporter.filterOutOwnWrites([untaggedA, taggedFromExporter, untaggedB])

        #expect(kept.count == 2)
        #expect(kept.contains { $0 === untaggedA })
        #expect(kept.contains { $0 === untaggedB })
        #expect(!kept.contains { $0 === taggedFromExporter })
    }

    // MARK: - Behavior 2: a kept carb sample maps to a (date, grams) tuple

    @Test func keptCarbSampleMapsToDateGramsTuple() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = carbSample(grams: 37.5, date: date)

        let mapped = HealthKitHistoryImporter.mapCarbSamples([sample], unit: gramUnit)

        #expect(mapped.count == 1)
        #expect(mapped[0].date == date)
        #expect(mapped[0].grams == 37.5)
    }

    // MARK: - Behavior 3: exporter's pure bolus-metadata builder

    @Test func exporterBolusMetadataCarriesDeliveryReasonSyncIdVersionAndOriginTag() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let metadataA = HealthKitExporter.bolusMetadata(date: date, units: 3.2)
        let metadataB = HealthKitExporter.bolusMetadata(date: date, units: 3.2)   // same (date, units) again

        #expect(metadataA[HKMetadataKeyInsulinDeliveryReason] as? Int == HKInsulinDeliveryReason.bolus.rawValue)
        #expect(metadataA[HealthKitOriginTag.key] as? Bool == true)
        #expect(metadataA[HKMetadataKeySyncVersion] != nil)

        let idA = metadataA[HKMetadataKeySyncIdentifier] as? String
        let idB = metadataB[HKMetadataKeySyncIdentifier] as? String
        #expect(idA != nil)
        #expect(idA == idB)   // stable per (date, units)

        let differentUnits = HealthKitExporter.bolusMetadata(date: date, units: 5.0)
        #expect((differentUnits[HKMetadataKeySyncIdentifier] as? String) != idA)
    }

    // MARK: - Behavior 4: round-trip echo — an exporter-built sample is dropped by the importer's filter

    @Test func exporterBuiltSampleIsDroppedByImporterEchoGuard() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = HealthKitExporter.bolusMetadata(date: date, units: 3.2)
        let quantity = HKQuantity(unit: .internationalUnit(), doubleValue: 3.2)
        let exported = HKQuantitySample(type: HKQuantityType(.insulinDelivery), quantity: quantity,
                                        start: date, end: date, metadata: metadata)

        let kept = HealthKitHistoryImporter.filterOutOwnWrites([exported])

        #expect(kept.isEmpty)
    }
}
