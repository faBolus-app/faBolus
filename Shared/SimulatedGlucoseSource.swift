import Foundation
import faBolusCore

/// A **credential-free, hardware-free** glucose source for exercising the failover path end-to-end
/// — arbiter promotion, the "via <source>" badge, chart backfill/merge, trend arrows, and staleness
/// — without a real sensor or a cloud login. The other failover sources can only be tested with real
/// credentials (cloud) or real hardware (Dexcom BLE / xDrip / HealthKit); this one lets you validate
/// the whole pipeline on the Simulator or any device.
///
/// It emits a smooth synthetic sine that sweeps ~55–255 mg/dL over ~24 min, so a short session crosses
/// urgent-low, in-range, and high — enough to see color coding and alert conditions react. It is a
/// diagnostic feed only (like a demo mode) and is hidden from the picker unless the user turns on the
/// "Simulated CGM" testing toggle; **its readings are fake and must never be treated as real glucose.**
@MainActor
public final class SimulatedGlucoseSource: GlucoseSource {
    public let id = "simulated"
    public let priority = 100          // treat like a local BLE feed so it wins failover during tests
    public private(set) var latest: GlucoseSample?
    public private(set) var history: [GlucoseReading] = []
    public private(set) var status: GlucoseSourceStatus = .idle
    public var onChange: (@MainActor () -> Void)?

    private var task: Task<Void, Never>?
    private let start0 = Date()
    private let periodSec = 24.0 * 60  // one full low→high→low sweep

    public init() {}

    /// Synthetic value at a given time: a sine centered at 155 with amplitude 100 → 55…255 mg/dL.
    private func value(at t: Date) -> Int {
        let phase = t.timeIntervalSince(start0) / periodSec * 2 * .pi
        return Int((155 + 100 * sin(phase)).rounded())
    }

    /// Derive a plausible trend arrow from the change since the previous reading.
    private func trend(now: Int, prev: Int?) -> GlucoseTrend {
        guard let prev else { return .flat }
        switch now - prev {
        case 15...:       return .upUp
        case 6...14:      return .up
        case 2...5:       return .rising
        case -1...1:      return .flat
        case -5 ... -2:   return .falling
        case -14 ... -6:  return .down
        default:          return .downDown
        }
    }

    public func start() async {
        status = .searching
        // Backfill ~3 h at 5-min spacing so the chart has a curve the instant we fail over.
        let now = Date()
        history = stride(from: 36, through: 1, by: -1).map { i -> GlucoseReading in
            let d = now.addingTimeInterval(-Double(i) * 5 * 60)
            return GlucoseReading(date: d, mgdl: value(at: d))
        }
        emit(at: now)
        status = .connected
        // Tick every 30 s with a current timestamp so `latest` stays fresh and drives failover.
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.emit(at: Date())
            }
        }
    }

    public func stop() {
        task?.cancel(); task = nil
        status = .idle
    }

    private func emit(at t: Date) {
        let v = value(at: t)
        latest = GlucoseSample(mgdl: v, date: t, trend: trend(now: v, prev: latest?.mgdl), sourceID: id)
        history.append(GlucoseReading(date: t, mgdl: v))
        if history.count > 288 { history.removeFirst(history.count - 288) }
        onChange?()
    }
}
