import Foundation
import HealthKit

/// Phase 09.18b (D-07): an **on-demand** heart-rate reader for the GraphDetailView chart-context HR
/// row. Unlike `HealthKitGlucoseSource` this has NO observer / anchored / background-delivery machinery
/// — HR is queried exactly at scrub time (`heartRate(at:)`) for the sample nearest the scrubbed `Date`,
/// so it costs nothing when the chart isn't being scrubbed. HR is display-only CHART CONTEXT: it never
/// feeds eating inference and is never a dose/meal-detection input (D-07).
///
/// The `.heartRate` read authorization is **additive** — requested independently of (and alongside)
/// the existing `.bloodGlucose` read in `HealthKitGlucoseSource`, never removing or gating it. When
/// Health is unavailable or the read is denied, `heartRate(at:)` returns `nil` and the HR row simply
/// hides (fail-safe, T-09.18b-05). Cross-platform like the glucose source: compiles for iOS and
/// watchOS (the watch reads Health synced from the phone).
@MainActor
final class HealthKitHeartRateSource {
    private let store = HKHealthStore()
    private let type = HKQuantityType(.heartRate)
    private let unit = HKUnit(from: "count/min")
    /// One-shot authorization guard — request read access at most once per instance (HealthKit itself
    /// won't re-prompt once the user has decided, but this avoids redundant async hops on every scrub).
    private var requestedAuthorization = false

    /// Additively request READ access to `.heartRate` (never a share/write type, never touching the
    /// glucose auth). Safe to call repeatedly; the actual system prompt appears at most once ever.
    func requestAuthorizationIfNeeded() async {
        guard !requestedAuthorization, HKHealthStore.isHealthDataAvailable() else { return }
        requestedAuthorization = true
        do {
            try await store.requestAuthorization(toShare: [], read: [type])
        } catch {
            // Denied / unavailable → heartRate(at:) returns nil and the HR row hides. Never fatal.
        }
    }

    /// The heart-rate sample (bpm) nearest the scrubbed `date`, read on demand over a short ±5-min
    /// window, newest-first, limit 1. Returns `nil` when Health is unavailable, access is denied, or
    /// there is no sample in the window (→ the HR row hides — never a fabricated value). Mirrors the
    /// continuation idiom in `HealthKitGlucoseSource.runAnchoredQuery`: the off-actor completion only
    /// resumes with the samples; the bpm is read back on the main actor.
    func heartRate(at date: Date) async -> Double? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: date.addingTimeInterval(-300),
                                                    end: date.addingTimeInterval(300), options: [])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        let samples: [HKQuantitySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: 1, sortDescriptors: sort) { _, samples, _ in
                cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
        guard let sample = samples.first else { return nil }
        let bpm = sample.quantity.doubleValue(for: unit)   // read on the main actor, after the query
        return (bpm.isFinite && bpm > 0) ? bpm : nil
    }
}
