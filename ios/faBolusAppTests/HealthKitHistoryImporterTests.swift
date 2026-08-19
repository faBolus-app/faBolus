import Testing
import Foundation
import HealthKit
import faBolusCore
@testable import faBolus

/// Phase 09.23-02 (D-05/D-08/D-11/D-14): pure-logic proof for the full multi-type importer —
/// insulin/bolus (delivery-reason filter), heart rate (fail-safe finite/>0 mapping), glucose
/// gap-fill (never-double-count dedup + the existing out-of-[40,400] gate), and per-type
/// authorization (the requested read set equals exactly the enabled-type subset). Every function
/// under test is `nonisolated static` and PURE — these tests construct plain in-memory
/// `HKQuantitySample`/`HKQuantity` objects (never touches `HKHealthStore.execute`/`.save`, so no
/// entitlement/authorization is needed) and run under the default `FABOLUS_HEALTHKIT` OFF build
/// (D-13 — `HealthKitHistoryImporter` is NOT `#if`-gated; only the pre-existing HealthKit CGM/HR
/// call sites are), mirroring `HealthKitTracerTests`' shape from the 09.23-01 tracer.
@MainActor
struct HealthKitHistoryImporterTests {
    private let insulinType = HKQuantityType(.insulinDelivery)
    private let heartRateType = HKQuantityType(.heartRate)
    private let glucoseType = HKQuantityType(.bloodGlucose)
    private let unitsUnit = HKUnit.internationalUnit()
    private let bpmUnit = HKUnit(from: "count/min")
    private let mgdlUnit = HKUnit(from: "mg/dL")

    /// `reason` is required (not optional) — HealthKit's own runtime validation REJECTS
    /// constructing an `.insulinDelivery` `HKQuantitySample` with no `HKMetadataKeyInsulinDeliveryReason`
    /// at all (`_HKObjectValidationFailureException`, confirmed by an isolated crash before this test
    /// file's final form), so "delivery with no reason metadata" isn't a real-world constructible
    /// object to test against; `.basal` alone proves the bolus-only filter excludes non-bolus reasons.
    private func insulinSample(units: Double, reason: HKInsulinDeliveryReason, date: Date = Date(),
                               origin: Bool? = nil) -> HKQuantitySample {
        var metadata: [String: Any] = [HKMetadataKeyInsulinDeliveryReason: reason.rawValue]
        if let origin { metadata[HealthKitOriginTag.key] = origin }
        let quantity = HKQuantity(unit: unitsUnit, doubleValue: units)
        return HKQuantitySample(type: insulinType, quantity: quantity, start: date, end: date, metadata: metadata)
    }

    private func heartRateSample(bpm: Double, date: Date = Date(), origin: Bool? = nil) -> HKQuantitySample {
        let metadata: [String: Any]? = origin.map { [HealthKitOriginTag.key: $0] }
        let quantity = HKQuantity(unit: bpmUnit, doubleValue: bpm)
        return HKQuantitySample(type: heartRateType, quantity: quantity, start: date, end: date, metadata: metadata)
    }

    private func glucoseSample(mgdl: Double, date: Date = Date(), origin: Bool? = nil) -> HKQuantitySample {
        let metadata: [String: Any]? = origin.map { [HealthKitOriginTag.key: $0] }
        let quantity = HKQuantity(unit: mgdlUnit, doubleValue: mgdl)
        return HKQuantitySample(type: glucoseType, quantity: quantity, start: date, end: date, metadata: metadata)
    }

    // MARK: - Behavior 1: insulin import keeps ONLY bolus-reason samples

    @Test func insulinImportKeepsOnlyBolusReasonSamples() {
        let bolus = insulinSample(units: 3.2, reason: .bolus)
        let basal = insulinSample(units: 0.8, reason: .basal)

        let kept = HealthKitHistoryImporter.filterBolusReason([bolus, basal])

        #expect(kept.count == 1)
        #expect(kept.contains { $0 === bolus })
        #expect(!kept.contains { $0 === basal })
    }

    @Test func insulinBolusSampleMapsToDateUnitsTuple() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = insulinSample(units: 4.5, reason: .bolus, date: date)

        let mapped = HealthKitHistoryImporter.mapInsulinSamples([sample], unit: unitsUnit)

        #expect(mapped.count == 1)
        #expect(mapped[0].date == date)
        #expect(mapped[0].units == 4.5)
    }

    // MARK: - Behavior 2: heart-rate mapping drops non-finite/<=0 bpm (fail-safe)

    @Test func heartRateMappingKeepsFinitePositiveBpm() {
        let good = heartRateSample(bpm: 72)
        let mapped = HealthKitHistoryImporter.mapHeartRateSamples([good], unit: bpmUnit)
        #expect(mapped.count == 1)
        #expect(mapped[0].bpm == 72)
    }

    @Test func heartRateMappingDropsZeroNegativeAndNonFiniteBpm() {
        let zero = heartRateSample(bpm: 0)
        let negative = heartRateSample(bpm: -5)
        let nan = heartRateSample(bpm: .nan)
        let good = heartRateSample(bpm: 81)

        let mapped = HealthKitHistoryImporter.mapHeartRateSamples([zero, negative, nan, good], unit: bpmUnit)

        #expect(mapped.count == 1)
        #expect(mapped[0].bpm == 81)
    }

    // MARK: - Behavior 3: glucose gap-fill selector never double-counts an already-occupied slot

    @Test func gapFillSelectorDropsCandidatesInAlreadyOccupiedSlots() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let occupiedSlot = Int(t0.timeIntervalSince1970 / 300)
        let emptySlotDate = t0.addingTimeInterval(3600)   // a different, unoccupied 5-min slot

        let candidateInOccupiedSlot = glucoseSample(mgdl: 130, date: t0)
        let candidateInEmptySlot = glucoseSample(mgdl: 145, date: emptySlotDate)

        let kept = HealthKitHistoryImporter.selectGapFillSamples(
            [candidateInOccupiedSlot, candidateInEmptySlot], occupiedSlots: [occupiedSlot])

        #expect(kept.count == 1)
        #expect(kept.contains { $0 === candidateInEmptySlot })
        #expect(!kept.contains { $0 === candidateInOccupiedSlot },
                "a candidate whose 5-min slot is already occupied by another sourceID must never be selected")
    }

    // MARK: - Behavior 4: out-of-[40,400] glucose is dropped via the existing gated GlucoseSample init

    @Test func gapFillMappingDropsOutOfRangeGlucose() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let tooLow = glucoseSample(mgdl: 20, date: date)                       // < 40
        let tooHigh = glucoseSample(mgdl: 450, date: date.addingTimeInterval(600))  // > 400
        let plausible = glucoseSample(mgdl: 130, date: date.addingTimeInterval(1200))

        let mapped = HealthKitHistoryImporter.mapGapFillGlucoseSamples(
            [tooLow, tooHigh, plausible], unit: mgdlUnit, sourceID: "healthkit-import")

        #expect(mapped.count == 1, "out-of-[40,400] values must never be charted, even raw")
        #expect(mapped[0].mgdl == 130)
    }

    // MARK: - Behavior 5: per-type authorization requests exactly the enabled-type subset

    @Test func perTypeAuthorizationRequestsExactlyTheEnabledSubset() {
        let enabledCarbsOnly = HealthKitHistoryImporter.readTypes(for: [.carbs])
        #expect(enabledCarbsOnly == [HKQuantityType(.dietaryCarbohydrates)])
        #expect(!enabledCarbsOnly.contains(HKQuantityType(.insulinDelivery)),
                "a disabled type must be absent from the read request")
        #expect(!enabledCarbsOnly.contains(HKQuantityType(.heartRate)))
        #expect(!enabledCarbsOnly.contains(HKQuantityType(.bloodGlucose)))

        let allFour = HealthKitHistoryImporter.readTypes(for: [.carbs, .insulin, .heartRate, .glucose])
        #expect(allFour == [HKQuantityType(.dietaryCarbohydrates), HKQuantityType(.insulinDelivery),
                            HKQuantityType(.heartRate), HKQuantityType(.bloodGlucose)])

        #expect(HealthKitHistoryImporter.readTypes(for: []).isEmpty)
    }

    // MARK: - WR-02: the query timeout race's double-resume guard allows exactly one winner, no
    // matter how many concurrent callers race it (`HKSampleQuery`'s completion handler and the
    // timeout `Task` in `HealthKitHistoryImporter.query` are the two real racers; a real stuck
    // `HKSampleQuery`/timing race isn't reproducible in a unit test without an entitlement, so this
    // proves the underlying concurrency primitive the fix depends on instead — see the doc comment
    // on `query(store:type:since:timeoutSeconds:)` for why the full end-to-end hang scenario is not
    // unit-testable here).

    @Test func queryResumeGuardAllowsExactlyOneWinnerUnderConcurrentAccess() async {
        let resumeGuard = HealthKitQueryResumeGuard()

        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<50 {
                group.addTask { resumeGuard.tryResume() }
            }
            var collected: [Bool] = []
            for await result in group { collected.append(result) }
            return collected
        }

        #expect(winners.filter { $0 }.count == 1,
                "exactly one of any number of concurrent callers must win the resume race")
        #expect(winners.filter { !$0 }.count == 49)
    }

    @Test func queryResumeGuardSecondSequentialCallLoses() {
        let resumeGuard = HealthKitQueryResumeGuard()
        #expect(resumeGuard.tryResume() == true, "first caller (e.g. the real HKSampleQuery completion) wins")
        #expect(resumeGuard.tryResume() == false, "second caller (e.g. the timeout) must lose — no double-resume")
    }

    // MARK: - Behavior 6: the shared echo-guard filter holds for every import type, not just carbs

    @Test func echoGuardFilterHoldsAcrossAllFourTypes() {
        let taggedInsulin = insulinSample(units: 1, reason: .bolus, origin: true)
        let taggedHeartRate = heartRateSample(bpm: 70, origin: true)
        let taggedGlucose = glucoseSample(mgdl: 120, origin: true)
        let untaggedInsulin = insulinSample(units: 2, reason: .bolus)

        let kept = HealthKitHistoryImporter.filterOutOwnWrites(
            [taggedInsulin, taggedHeartRate, taggedGlucose, untaggedInsulin])

        #expect(kept.count == 1)
        #expect(kept.contains { $0 === untaggedInsulin })
    }
}
