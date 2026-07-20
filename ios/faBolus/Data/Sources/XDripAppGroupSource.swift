import Foundation
import faBolusCore

/// Reads glucose from xDrip4iOS's shared **"Share to Loop" App Group** — the lowest-latency, fully
/// local xDrip path (no cloud, no pump/phone link needed). xDrip's `LoopManager.share()` writes the
/// recent readings as JSON under the key `latestReadings` in `group.com.<TEAM>.loopkit.LoopGroup`.
///
/// Requires faBolus **and** xDrip to be built/signed under the **same Apple Developer Team ID** with
/// the matching app-group entitlement (App Groups are team-scoped) — i.e. self-compile both. In
/// xDrip: Settings → "Share to Loop" with share type **Loop**. Ported from
/// JohanDegraeve/xdrip-client-swift. Read-only.
///
/// Payload dicts are Dexcom-Share-style: `Value` mg/dL, `DT`/`ST` = "/Date(ms)/", `Trend` slope
/// ordinal (1=DoubleUp…7=DoubleDown), optional `direction` name, `from` = "xDrip".
@MainActor
final class XDripAppGroupSource: GlucoseSource {
    let id = "xdrip-appgroup"
    let priority = 90              // local + near-instant; just below native G7 BLE, above cloud
    private(set) var latest: GlucoseSample?
    private(set) var history: [GlucoseReading] = []
    private(set) var status: GlucoseSourceStatus = .idle
    var onChange: (@MainActor () -> Void)?

    private var task: Task<Void, Never>?

    /// The Loop App Group suite name, resolved from Info.plist (the `$(DEVELOPMENT_TEAM)` placeholder
    /// is substituted with the signing team at build), so no team id is hard-coded here.
    private var suiteName: String? {
        (Bundle.main.object(forInfoDictionaryKey: "LoopAppGroupIdentifier") as? String)?
            .trimmingCharacters(in: .whitespaces)
    }

    func start() async {
        guard task == nil else { return }
        status = .searching; onChange?()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.read()
                // Local read is cheap; 30 s easily keeps up with xDrip's ~5-min readings.
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    func stop() { task?.cancel(); task = nil; status = .idle; onChange?() }

    private func read() async {
        guard let suite = suiteName, !suite.isEmpty, !suite.contains("DEVELOPMENT_TEAM"),
              let defaults = UserDefaults(suiteName: suite),
              let data = defaults.data(forKey: "latestReadings") else {
            status = .needsSetup; onChange?(); return
        }
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            status = .error("Unreadable xDrip payload"); onChange?(); return
        }
        let readings: [GlucoseReading] = arr.compactMap { reading(from: $0)?.reading }
        let samples: [GlucoseSample] = arr.compactMap { reading(from: $0) }
        guard let newest = samples.max(by: { $0.date < $1.date }) else {
            status = .stale; onChange?(); return
        }
        latest = newest
        var byBucket: [Int: GlucoseReading] = [:]
        for r in history + readings { byBucket[Int(r.date.timeIntervalSince1970 / 300)] = r }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        history = byBucket.values.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        status = newest.isStale ? .stale : .connected
        onChange?()
    }

    private func reading(from d: [String: Any]) -> GlucoseSample? {
        guard let value = (d["Value"] as? NSNumber)?.doubleValue, value > 0,
              let dateStr = (d["DT"] as? String) ?? (d["ST"] as? String),
              let date = CgmTrend.dotNetDate(dateStr) else { return nil }
        let trend: GlucoseTrend
        if let ordinal = (d["Trend"] as? NSNumber)?.intValue { trend = CgmTrend.dexcom(ordinal) }
        else if let dir = d["direction"] as? String { trend = CgmTrend.nightscout(dir) }
        else { trend = .flat }
        return GlucoseSample(mgdl: Int(value.rounded()), date: date, trend: trend, sourceID: id)
    }
}
