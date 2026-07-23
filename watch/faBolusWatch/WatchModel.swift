import Foundation
import faBolusCore

/// Watch-side remote state. A thin subclass of the shared `RemoteClientModel` (which owns the
/// phone↔remote command handling over `RemoteLink`) that adds the watch's direct-CGM failover:
/// when the iPhone is out of range the watch reads glucose itself, phone-independent — a Dexcom
/// G7/ONE+ over BLE, and/or xDrip4iOS via Apple Health (synced from the phone). The watch never
/// touches the pump (PumpX2Kit runs on the phone).
@MainActor
final class WatchModel: RemoteClientModel {
    /// Direct sources reuse the shared implementations; started only while unreachable, to save power.
    private let directSources: [any GlucoseSource] = [DexcomG7BLESource(), HealthKitGlucoseSource()]

    #if FABOLUS_ONWATCH_EATING
    /// On-device eating detector (flag-gated; needs the paid HealthKit entitlement). Relays p(eating)
    /// to the phone, which owns the fusion + nudge. See WatchEatingSensor.swift.
    private var eatingSensor: WatchEatingSensor?
    #endif

    init() {
        super.init(link: RemoteLink())
        for s in directSources { s.onChange = { [weak self] in self?.applyDirect() } }
        if !reachable { startDirect() }
        #if FABOLUS_ONWATCH_EATING
        eatingSensor = WatchEatingSensor { [weak self] prob in
            guard let self else { return }
            var c = RemoteCommand(kind: .eatingEvent); c.eatingProb = prob
            self.link.send(c)
        }
        #endif
    }

    #if FABOLUS_ONWATCH_EATING
    /// The phone drives when the watch senses (battery): the routine status push carries
    /// `eatingSensingOn`. Start/stop the on-device detector accordingly.
    override func handle(_ cmd: RemoteCommand) {
        super.handle(cmd)
        if cmd.kind == .statusRead, let on = cmd.eatingSensingOn {
            if on { eatingSensor?.start() } else { eatingSensor?.stop() }
        }
    }
    #endif

    override func reachabilityDidChange(_ r: Bool) {
        super.reachabilityDidChange(r)
        if r { stopDirect() } else { startDirect() }
    }

    private func startDirect() { for s in directSources { Task { await s.start() } } }
    private func stopDirect() { for s in directSources { s.stop() } }

    /// Apply the freshest direct reading when the phone can't supply a fresher one (out of range, or
    /// the relayed value is older). Never overrides a fresher phone reading. Scans the sources (no
    /// per-source capture) to avoid a retain cycle on their `onChange`.
    private func applyDirect() {
        guard let s = directSources.compactMap({ $0.latest }).max(by: { $0.date < $1.date }) else { return }
        let fresher = glucoseDate.map { s.date > $0 } ?? true
        guard !reachable || fresher else { return }
        glucose = s.mgdl
        glucoseDate = s.date
        trend = s.trend.rawValue
        publishSnapshot()
    }

    /// modern band color for a glucose value (kept for the watch views' call sites).
    static func color(_ mgdl: Int) -> Int { RemoteClientModel.band(mgdl) }
}

/// Shared glucose banding so the watch views color consistently.
enum RemoteGlucose {
    static func band(_ mgdl: Int) -> Int { RemoteClientModel.band(mgdl) }
}
