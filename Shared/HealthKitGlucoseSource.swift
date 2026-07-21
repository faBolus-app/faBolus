import Foundation
import HealthKit
import faBolusCore

/// Reads glucose from **Apple Health** as a failover feed — whatever app writes glucose there.
/// Primary use is **xDrip4iOS**, which writes each reading to Health in real time (≈5 min, or ≈1 min
/// with its frequent-readings toggle), giving near-real-time coverage of *any* xDrip-supported sensor
/// (Libre 1/2, Dexcom G5/G6/ONE, …). Also serves **Eversense**, whose app writes to Health. (The
/// official Dexcom app writes on a ~3-hour delay and US LibreLink doesn't write at all, so those are
/// served by the BLE/cloud sources instead.) Observer + anchored query with background delivery, so
/// samples arrive as the writer flushes them. Cross-platform: compiles for iOS and watchOS (the watch
/// reads Health synced from the phone). Read-only; Health carries no trend, so trend shows flat.
@MainActor
final class HealthKitGlucoseSource: GlucoseSource {
    let id = "healthkit"
    let priority = 15
    private(set) var latest: GlucoseSample?
    private(set) var history: [GlucoseReading] = []
    private(set) var status: GlucoseSourceStatus = .idle
    var onChange: (@MainActor () -> Void)?

    private let store = HKHealthStore()
    private let type = HKQuantityType(.bloodGlucose)
    private let unit = HKUnit(from: "mg/dL")
    // HealthKit hands the updated anchor back inside its query result handler (a Sendable closure
    // that runs off the main actor), so this can't be main-actor-isolated. Access is serial (one
    // fetchNew query at a time), so nonisolated(unsafe) is safe and satisfies Swift 6 strict
    // concurrency (Xcode 16.4 CI flags the main-actor mutation otherwise).
    nonisolated(unsafe) private var anchor: HKQueryAnchor?
    private var observer: HKObserverQuery?

    func start() async {
        guard HKHealthStore.isHealthDataAvailable() else { status = .error("Health unavailable"); onChange?(); return }
        status = .searching; onChange?()
        do {
            try await store.requestAuthorization(toShare: [], read: [type])
        } catch {
            status = .needsSetup; onChange?(); return
        }
        let observer = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
            Task { @MainActor in await self?.fetchNew() }
            completion()
        }
        self.observer = observer
        store.execute(observer)
        store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        await fetchNew()
    }

    func stop() {
        if let observer { store.stop(observer) }
        observer = nil
        status = .idle; onChange?()
    }

    /// Pull samples since the last anchor and update latest/history.
    private func fetchNew() async {
        let samples: [HKQuantitySample] = await withCheckedContinuation { cont in
            let q = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor,
                                          limit: HKObjectQueryNoLimit) { [weak self] _, newSamples, _, newAnchor, _ in
                self?.anchor = newAnchor
                cont.resume(returning: (newSamples as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
        guard !samples.isEmpty else { return }
        let readings = samples.map {
            GlucoseReading(date: $0.startDate, mgdl: Int($0.quantity.doubleValue(for: unit).rounded()))
        }
        var byBucket: [Int: GlucoseReading] = [:]
        for r in history + readings { byBucket[Int(r.date.timeIntervalSince1970 / 300)] = r }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        history = byBucket.values.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        if let newest = history.last {
            latest = GlucoseSample(mgdl: newest.mgdl, date: newest.date, trend: .flat, sourceID: id)
            status = latest?.isStale == true ? .stale : .connected
        }
        onChange?()
    }
}
