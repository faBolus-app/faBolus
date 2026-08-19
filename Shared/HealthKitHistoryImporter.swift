import Foundation
import HealthKit
import faBolusCore

/// Phase 09.23 (D-05/D-08/D-11/D-12/D-14): retrospective HISTORY import from Apple Health into
/// faBolus's logbook — NEVER a live dosing input (D-05; the boundary is test-enforced by
/// `HealthKitImportDosePathGuardTests`). Wave 1 (09.23-01) shipped the tracer's ONE read type
/// (Carbs, `.dietaryCarbohydrates`); this file (09.23-02) extends the same shape to the full D-14
/// set — Insulin/bolus (`.insulinDelivery`, filtered to the bolus delivery-reason), Heart rate
/// (`.heartRate`, persisted to the new `StoredHeartRate` table), and Glucose (`.bloodGlucose`,
/// GAP-FILL ONLY — never double-counts against faBolus's own CGM history).
///
/// Authorization mirrors `HealthKitHeartRateSource`'s one-shot fail-safe guard (arm only on
/// success, so a transient failure can retry), now parameterized on the per-type-enabled subset
/// (D-14) so declining one type's read never blocks the others via a single combined prompt
/// outcome. The ranged query mirrors `HealthKitGlucoseSource.runAnchoredQuery`'s
/// `HKSampleQuery`/continuation idiom, widened from a scrub window to an explicit
/// `[since, Date()]` range for manual/backfill import (D-11a). Every mapping/filter/gap-fill
/// function is `nonisolated static` and PURE — unit-testable without the entitlement
/// (`HealthKitTracerTests`/`HealthKitHistoryImporterTests`), and NOT gated behind
/// `#if FABOLUS_HEALTHKIT` (only the pre-existing HealthKit CGM/HR call sites are — D-13).
@MainActor
final class HealthKitHistoryImporter {
    private let store = HKHealthStore()
    private let carbType = HKQuantityType(.dietaryCarbohydrates)
    private let insulinType = HKQuantityType(.insulinDelivery)
    private let heartRateType = HKQuantityType(.heartRate)
    private let glucoseType = HKQuantityType(.bloodGlucose)
    private let gramUnit = HKUnit.gram()
    private let unitsUnit = HKUnit.internationalUnit()
    private let bpmUnit = HKUnit(from: "count/min")
    private let mgdlUnit = HKUnit(from: "mg/dL")
    /// One-shot authorization guard — mirrors `HealthKitHeartRateSource.requestedAuthorization`.
    private var requestedAuthorization = false

    init() {}

    /// D-14: the four persistable import types, each individually user-selectable.
    enum HealthKitImportType: Hashable, CaseIterable {
        case carbs, insulin, heartRate, glucose
    }

    /// Additively request READ access to ONLY the per-type-enabled subset (D-14) — never an
    /// unconditional superset, so declining one type doesn't block the others. Never a share/write
    /// type. Safe to call repeatedly; the system prompt appears at most once per type.
    func requestAuthorizationIfNeeded(enabledTypes: Set<HealthKitImportType>) async {
        guard !requestedAuthorization, HKHealthStore.isHealthDataAvailable() else { return }
        let types = Self.readTypes(for: enabledTypes)
        guard !types.isEmpty else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: types)
            // Arm the guard only on SUCCESS — a transient throw (not a user denial) can retry on
            // the next call; a real denial doesn't re-prompt anyway (HealthKit itself won't).
            requestedAuthorization = true
        } catch {
            // Transient error → leave the guard unset so a later call can retry. Denied/unavailable
            // → the import* methods return [] and the caller sees no data. Never fatal.
        }
    }

    /// Manual/backfill carbs import (D-11a) over an explicit `[since, Date()]` range. Returns `[]`
    /// on denied/unavailable/no-data — never throws (mirrors `HealthKitHeartRateSource.heartRate(at:)`).
    /// The caller feeds the result into `GlucoseHistoryStore.ingestCarbs` — never `GlucoseArbiter`/
    /// `BolusMath` (D-05).
    func importCarbHistory(since: Date) async -> [(date: Date, grams: Double)] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let samples: [HKQuantitySample] = await Self.query(store: store, type: carbType, since: since)
        return Self.mapCarbSamples(Self.filterOutOwnWrites(samples), unit: gramUnit)
    }

    /// Manual/backfill insulin/bolus import (D-14) over `[since, Date()]`. Keeps ONLY samples whose
    /// `HKMetadataKeyInsulinDeliveryReason` is `.bolus` — basal/automated delivery is excluded. The
    /// caller feeds the result into `GlucoseHistoryStore.ingestBoluses` — never `GlucoseArbiter`/
    /// `BolusMath` (D-05).
    func importInsulinHistory(since: Date) async -> [(date: Date, units: Double)] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let samples: [HKQuantitySample] = await Self.query(store: store, type: insulinType, since: since)
        let unowned = Self.filterOutOwnWrites(samples)
        return Self.mapInsulinSamples(Self.filterBolusReason(unowned), unit: unitsUnit)
    }

    /// Manual/backfill heart-rate import (D-14) over `[since, Date()]`. Fail-safe: drops any
    /// non-finite/<=0 bpm reading before it ever reaches `StoredHeartRate`. The caller feeds the
    /// result into `GlucoseHistoryStore.ingestHeartRate` — never the dose path.
    func importHeartRateHistory(since: Date) async -> [(date: Date, bpm: Double)] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let samples: [HKQuantitySample] = await Self.query(store: store, type: heartRateType, since: since)
        return Self.mapHeartRateSamples(Self.filterOutOwnWrites(samples), unit: bpmUnit)
    }

    /// Manual/backfill GAP-FILL-ONLY glucose import (D-14) over `[since, Date()]`. `existingSlots`
    /// is the caller-supplied set of 5-min slot keys (`Int(date.timeIntervalSince1970/300)`)
    /// currently occupied by faBolus's OWN CGM history from another `sourceID` — mirroring
    /// `GlucoseHistoryStore.glucose(in:)`'s own bucket rule. A Health glucose sample is imported
    /// ONLY into a slot that set does not already cover, so it never double-counts against the
    /// app's own CGM readings. `sourceID` is stamped on every kept reading (defaults to
    /// `Self.glucoseImportSourceID`, distinct from the live `HealthKitGlucoseSource.id` = "healthkit"
    /// failover feed, so the two paths remain distinguishable in history).
    func importGlucoseGapFill(since: Date, existingSlots: Set<Int>,
                              sourceID: String = HealthKitHistoryImporter.glucoseImportSourceID) async -> [GlucoseReading] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let samples: [HKQuantitySample] = await Self.query(store: store, type: glucoseType, since: since)
        let unowned = Self.filterOutOwnWrites(samples)
        let gapFilled = Self.selectGapFillSamples(unowned, occupiedSlots: existingSlots)
        return Self.mapGapFillGlucoseSamples(gapFilled, unit: mgdlUnit, sourceID: sourceID)
    }

    /// The `sourceID` stamped on gap-fill-imported glucose — distinct from the live
    /// `HealthKitGlucoseSource.id` ("healthkit" failover feed) so retrospective imports and the
    /// live on-device feed remain distinguishable in `GlucoseHistoryStore` history.
    static let glucoseImportSourceID = "healthkit-import"

    // MARK: - Shared ranged query (D-11a manual/backfill shape, one HKSampleQuery per type)

    /// `HKSampleQuery` over an explicit `[since, Date()]` range — the manual/backfill import shape
    /// (D-11a), widened from `HealthKitHeartRateSource`'s ±5-min scrub window. Shared by every
    /// `import*History` method so each adds only its own type-specific filter/mapping.
    private static func query(store: HKHealthStore, type: HKQuantityType, since: Date) async -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: Date(), options: [])
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, _ in
                cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
    }

    // MARK: - Pure functions (D-12 echo-guard + per-type filter/mapping) — unit-testable without
    // the entitlement (HealthKitTracerTests / HealthKitHistoryImporterTests)

    /// D-12 echo-guard: drop every sample carrying faBolus's own origin tag (written by
    /// `HealthKitExporter`) so faBolus never re-imports its own exported writes. Generic across
    /// every import type — the metadata key check doesn't care which `HKQuantityType` it's on.
    nonisolated static func filterOutOwnWrites(_ samples: [HKQuantitySample]) -> [HKQuantitySample] {
        samples.filter { $0.metadata?[HealthKitOriginTag.key] == nil }
    }

    /// Maps kept samples to `(date, grams)` tuples — the shape `GlucoseHistoryStore.ingestCarbs` takes.
    nonisolated static func mapCarbSamples(_ samples: [HKQuantitySample], unit: HKUnit) -> [(date: Date, grams: Double)] {
        samples.map { (date: $0.startDate, grams: $0.quantity.doubleValue(for: unit)) }
    }

    /// D-14 insulin filter: keep ONLY samples whose `HKMetadataKeyInsulinDeliveryReason` equals
    /// `.bolus` — basal/automated delivery (or samples missing the metadata entirely) are excluded.
    nonisolated static func filterBolusReason(_ samples: [HKQuantitySample]) -> [HKQuantitySample] {
        samples.filter { ($0.metadata?[HKMetadataKeyInsulinDeliveryReason] as? Int) == HKInsulinDeliveryReason.bolus.rawValue }
    }

    /// Maps kept bolus-reason samples to `(date, units)` tuples — the shape
    /// `GlucoseHistoryStore.ingestBoluses` takes (via `BolusMarker`).
    nonisolated static func mapInsulinSamples(_ samples: [HKQuantitySample], unit: HKUnit) -> [(date: Date, units: Double)] {
        samples.map { (date: $0.startDate, units: $0.quantity.doubleValue(for: unit)) }
    }

    /// Maps heart-rate samples to `(date, bpm)` tuples, FAIL-SAFE dropping any non-finite/<=0 bpm
    /// (a malformed/zero reading is silently excluded rather than persisted as a fabricated value).
    nonisolated static func mapHeartRateSamples(_ samples: [HKQuantitySample], unit: HKUnit) -> [(date: Date, bpm: Double)] {
        samples.compactMap { s in
            let bpm = s.quantity.doubleValue(for: unit)
            guard bpm.isFinite, bpm > 0 else { return nil }
            return (date: s.startDate, bpm: bpm)
        }
    }

    /// D-14 gap-fill dedup: keep only candidate Health glucose samples whose 5-min slot key
    /// (`Int(date.timeIntervalSince1970/300)`, mirroring `GlucoseHistoryStore.glucose(in:)`'s own
    /// bucket rule) is NOT already present in `occupiedSlots` — the caller-supplied set of slot
    /// keys currently held by faBolus's OWN CGM history from another `sourceID`. A pure filter; it
    /// never recomputes `occupiedSlots` itself.
    nonisolated static func selectGapFillSamples(_ candidates: [HKQuantitySample], occupiedSlots: Set<Int>) -> [HKQuantitySample] {
        candidates.filter { !occupiedSlots.contains(Int($0.startDate.timeIntervalSince1970 / 300)) }
    }

    /// Maps gap-fill-selected glucose samples to `GlucoseReading`s, routed through the existing
    /// gated `GlucoseSample` initializer (mirrors `HealthKitGlucoseSource.runAnchoredQuery`) so a
    /// value outside `[GlucosePlausibility.minimum, .maximum]` (`[40, 400]`) is DROPPED — never
    /// charted raw, even from an on-device import.
    nonisolated static func mapGapFillGlucoseSamples(_ samples: [HKQuantitySample], unit: HKUnit,
                                                     sourceID: String) -> [GlucoseReading] {
        samples.compactMap { s in
            let mgdl = Int(s.quantity.doubleValue(for: unit).rounded())
            return GlucoseSample(mgdl: mgdl, date: s.startDate, sourceID: sourceID)?.reading
        }
    }

    /// D-14 per-type authorization: maps the enabled-type subset to the exact `HKObjectType` read
    /// set — a disabled type contributes nothing, so `store.requestAuthorization`'s `read:` set
    /// never includes a type the user hasn't opted into.
    nonisolated static func readTypes(for enabled: Set<HealthKitImportType>) -> Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if enabled.contains(.carbs) { types.insert(HKQuantityType(.dietaryCarbohydrates)) }
        if enabled.contains(.insulin) { types.insert(HKQuantityType(.insulinDelivery)) }
        if enabled.contains(.heartRate) { types.insert(HKQuantityType(.heartRate)) }
        if enabled.contains(.glucose) { types.insert(HKQuantityType(.bloodGlucose)) }
        return types
    }
}
