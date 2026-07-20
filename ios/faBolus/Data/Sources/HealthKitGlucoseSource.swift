import Foundation
import HealthKit
import faBolusCore

/// Reads glucose from **Apple Health** as a failover feed. Wired for **Eversense**, whose official
/// app writes to Health (Dexcom writes on a 3-hour delay and US LibreLink doesn't write to Health, so
/// they are served by BLE/cloud sources instead). Uses an observer + anchored query with background
/// delivery so new samples arrive as the writer flushes them. Read-only; no trend from Health.
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
    private var anchor: HKQueryAnchor?
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
