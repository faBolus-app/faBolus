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
/// Carries a non-Sendable completion handler across an isolation hop (its only use: run it once).
private struct SendableBox: @unchecked Sendable {
    private let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    func run() { closure() }
}

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
    // Main-actor-isolated: the anchor is read before a query and written only after it completes, on
    // the main actor (audit A-09) — the query's off-actor result handler no longer mutates it directly.
    private var anchor: HKQueryAnchor?
    private var observer: HKObserverQuery?
    // Single-flight serialization (audit A-09): only one anchored query runs at a time; observer re-fires
    // that land mid-fetch coalesce into one follow-up run instead of racing concurrent queries + anchors.
    private var fetching = false
    private var refetchQueued = false

    func start() async {
        guard HKHealthStore.isHealthDataAvailable() else { status = .error("Health unavailable"); onChange?(); return }
        status = .searching; onChange?()
        do {
            try await store.requestAuthorization(toShare: [], read: [type])
        } catch {
            status = .needsSetup; onChange?(); return
        }
        let observer = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
            // Call completion() only AFTER the fetch finishes (audit A-09) so HealthKit knows the
            // background delivery was actually processed and doesn't consider it lost. The handler isn't
            // Sendable, so cross into the MainActor Task through a small sendable box.
            let done = SendableBox(completion)
            Task { @MainActor in await self?.fetchNew(); done.run() }
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

    /// Pull samples since the last anchor and update latest/history. Serialized (audit A-09): a re-fire
    /// while a query is in flight coalesces into a single follow-up run, so two queries never race the
    /// anchor.
    private func fetchNew() async {
        if fetching { refetchQueued = true; return }
        fetching = true
        defer { fetching = false }
        repeat {
            refetchQueued = false
            await runAnchoredQuery()
        } while refetchQueued
    }

    private func runAnchoredQuery() async {
        let currentAnchor = anchor
        let result: ([HKQuantitySample], HKQueryAnchor?) = await withCheckedContinuation { cont in
            let q = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: currentAnchor,
                                          limit: HKObjectQueryNoLimit) { _, newSamples, _, newAnchor, _ in
                cont.resume(returning: ((newSamples as? [HKQuantitySample]) ?? [], newAnchor))
            }
            store.execute(q)
        }
        anchor = result.1   // set on the main actor, after the query completes
        let samples = result.0
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
