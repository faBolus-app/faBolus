import Foundation
import HealthKit
import faBolusCore

/// Phase 09.23 (D-05/D-08/D-11/D-12/D-14, the phase TRACER's read side): retrospective HISTORY
/// import from Apple Health into faBolus's logbook — NEVER a live dosing input (D-05; the boundary
/// is test-enforced by `HealthKitImportDosePathGuardTests`). This tracer ships ONE read type
/// (Carbs, `.dietaryCarbohydrates`); Waves 2-3 extend the same shape to Insulin/bolus, Heart rate,
/// and gap-fill-only Glucose (D-14).
///
/// Authorization mirrors `HealthKitHeartRateSource`'s one-shot fail-safe guard (arm only on
/// success, so a transient failure can retry). The ranged query mirrors
/// `HealthKitGlucoseSource.runAnchoredQuery`'s `HKSampleQuery`/continuation idiom, widened from a
/// scrub window to an explicit `[since, Date()]` range for manual/backfill import (D-11a). The
/// echo-guard filter + carb-mapping are `nonisolated static` PURE functions — unit-testable without
/// the entitlement (`HealthKitTracerTests`), and NOT gated behind `#if FABOLUS_HEALTHKIT` (only the
/// pre-existing HealthKit CGM/HR call sites are — D-13).
@MainActor
final class HealthKitHistoryImporter {
    private let store = HKHealthStore()
    private let carbType = HKQuantityType(.dietaryCarbohydrates)
    private let gramUnit = HKUnit.gram()
    /// One-shot authorization guard — mirrors `HealthKitHeartRateSource.requestedAuthorization`.
    private var requestedAuthorization = false

    init() {}

    /// Additively request READ access to the per-type-enabled subset only (this tracer: carbs).
    /// Never a share/write type. Safe to call repeatedly; the system prompt appears at most once.
    func requestAuthorizationIfNeeded() async {
        guard !requestedAuthorization, HKHealthStore.isHealthDataAvailable() else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: [carbType])
            // Arm the guard only on SUCCESS — a transient throw (not a user denial) can retry on
            // the next call; a real denial doesn't re-prompt anyway (HealthKit itself won't).
            requestedAuthorization = true
        } catch {
            // Transient error → leave the guard unset so a later call can retry. Denied/unavailable
            // → importCarbHistory returns [] and the caller sees no data. Never fatal.
        }
    }

    /// Manual/backfill carbs import (D-11a) over an explicit `[since, Date()]` range. Returns `[]`
    /// on denied/unavailable/no-data — never throws (mirrors `HealthKitHeartRateSource.heartRate(at:)`).
    /// The caller feeds the result into `GlucoseHistoryStore.ingestCarbs` — never `GlucoseArbiter`/
    /// `BolusMath` (D-05).
    func importCarbHistory(since: Date) async -> [(date: Date, grams: Double)] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: since, end: Date(), options: [])
        let samples: [HKQuantitySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: carbType, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, _ in
                cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
        return Self.mapCarbSamples(Self.filterOutOwnWrites(samples), unit: gramUnit)
    }

    // MARK: - Pure functions (D-12 echo-guard + carb mapping) — unit-testable without the entitlement

    /// D-12 echo-guard: drop every sample carrying faBolus's own origin tag (written by
    /// `HealthKitExporter`) so faBolus never re-imports its own exported writes.
    nonisolated static func filterOutOwnWrites(_ samples: [HKQuantitySample]) -> [HKQuantitySample] {
        samples.filter { $0.metadata?[HealthKitOriginTag.key] == nil }
    }

    /// Maps kept samples to `(date, grams)` tuples — the shape `GlucoseHistoryStore.ingestCarbs` takes.
    nonisolated static func mapCarbSamples(_ samples: [HKQuantitySample], unit: HKUnit) -> [(date: Date, grams: Double)] {
        samples.map { (date: $0.startDate, grams: $0.quantity.doubleValue(for: unit)) }
    }
}
