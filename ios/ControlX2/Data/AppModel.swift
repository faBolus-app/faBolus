import Foundation
import Observation
import PumpX2Messages

/// Observable app state bridging a `PumpDataSource` to SwiftUI.
@MainActor
@Observable
public final class AppModel {
    public private(set) var snapshot = PumpSnapshot()
    public private(set) var glucoseHistory: [GlucoseReading] = []
    public private(set) var activeNotifications: [PumpNotification] = []
    public private(set) var alertDebug: String = ""
    public var lastError: String?

    /// Clear a pump alert/alarm from the app (signed dismiss on the pump).
    public func dismissNotification(_ n: PumpNotification) async { await source.dismissNotification(n); refresh() }

    /// A bolus requested by a remote (watch/Garmin) awaiting the phone's confirmation.
    public struct PendingRemoteBolus: Equatable, Sendable { public let requestId: String; public let units: Double }
    public var pendingRemoteBolus: PendingRemoteBolus?
    /// Status-echo handlers registered by remote bridges (watch / Garmin). Broadcasts to all;
    /// each remote ignores statuses for requestIds it didn't send.
    private var remoteEchoes: [@MainActor (RemoteCommand) -> Void] = []
    public func addRemoteEcho(_ handler: @escaping @MainActor (RemoteCommand) -> Void) {
        remoteEchoes.append(handler)
    }
    private func echo(_ cmd: RemoteCommand) { for h in remoteEchoes { h(cmd) } }

    /// Listeners (Garmin bridge) that push the latest status to a remote when pump data changes,
    /// so an open remote refreshes promptly instead of waiting for its own poll.
    private var statusListeners: [@MainActor (PumpSnapshot) -> Void] = []
    public func addStatusListener(_ handler: @escaping @MainActor (PumpSnapshot) -> Void) {
        statusListeners.append(handler)
    }
    private var lastStatusPush = Date.distantPast
    private var lastPushedGlucose: Int?
    private func pushStatusIfNeeded() {
        guard !statusListeners.isEmpty else { return }
        // Push on a glucose change, or at most once every 15 s otherwise.
        let changed = snapshot.glucose != lastPushedGlucose
        guard changed || Date().timeIntervalSince(lastStatusPush) > 15 else { return }
        lastStatusPush = Date(); lastPushedGlucose = snapshot.glucose
        for h in statusListeners { h(snapshot) }
    }

    private let source: PumpDataSource

    /// 6-digit JPAKE pairing code, entered before connecting to a real pump.
    public var pairingCode: String {
        get { source.pairingCode } set { source.pairingCode = newValue }
    }
    /// True when a saved pairing exists — Connect can resume without a code.
    public var hasStoredPairing: Bool { source.hasStoredPairing }
    public func forgetPairing() { source.forgetPairing() }

    /// Set by the Garmin bridge; presents Garmin device selection.
    public var setupGarmin: (@MainActor () -> Void)?
    /// Human-readable Garmin remote status (device name / selection result) for the HUD.
    public var garminStatus: String?

    public init(source: PumpDataSource) {
        self.source = source
        self.snapshot = source.snapshot
        self.glucoseHistory = source.glucoseHistory
        source.onChange = { [weak self] in self?.refresh() }
    }

    /// Set when a widget's tap-to-bolus deep link opens the app; the HUD observes it to present
    /// the bolus-entry sheet.
    public var openBolusRequested = false

    private func refresh() {
        snapshot = source.snapshot
        glucoseHistory = source.glucoseHistory
        activeNotifications = source.activeNotifications
        alertDebug = source.alertDebug
        WidgetPublisher.publish(snapshot, history: glucoseHistory)
        pushStatusIfNeeded()
    }

    public func connect() async { await source.connect(); refresh() }
    public func disconnect() { source.disconnect(); refresh() }

    public func recommendBolus(carbsGrams: Double, bgMgdl: Int?) async -> BolusRecommendation {
        await source.recommendBolus(carbsGrams: carbsGrams, bgMgdl: bgMgdl)
    }

    public func deliverBolus(units: Double) async {
        do { _ = try await source.deliverBolus(units: units); lastError = nil }
        catch { lastError = error.localizedDescription }
        refresh()
    }

    public func cancelBolus() async { await source.cancelBolus(); refresh() }

    // MARK: Remote (watch/Garmin) double-confirmation

    public func presentRemoteBolus(requestId: String, units: Double) {
        pendingRemoteBolus = PendingRemoteBolus(requestId: requestId, units: units)
    }

    /// The phone user's confirmation (second confirm) — delivers and echoes status to the remote.
    public func confirmRemoteBolus() async {
        guard let pending = pendingRemoteBolus else { return }
        pendingRemoteBolus = nil
        do {
            let delivered = try await source.deliverBolus(units: pending.units)
            echo(RemoteCommand(kind: .bolusStatus, requestId: pending.requestId,
                               status: .delivered, deliveredUnits: delivered))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            echo(RemoteCommand(kind: .bolusStatus, requestId: pending.requestId,
                               status: .failed, message: error.localizedDescription))
        }
        refresh()
    }

    /// Deliver a bolus already confirmed on the remote itself (e.g. Garmin hold-to-deliver) —
    /// no phone-side dialog. Echoes delivering → delivered/failed back to the remote.
    public func remoteDeliver(requestId: String, units: Double) async {
        echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .delivering))
        do {
            let delivered = try await source.deliverBolus(units: units)
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId,
                               status: .delivered, deliveredUnits: delivered))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId,
                               status: .failed, message: error.localizedDescription))
        }
        refresh()
    }

    public func rejectRemoteBolus() {
        if let pending = pendingRemoteBolus {
            echo(RemoteCommand(kind: .bolusStatus, requestId: pending.requestId, status: .cancelled))
        }
        pendingRemoteBolus = nil
    }
}
