import Foundation
import Observation

/// Observable app state bridging a `PumpDataSource` to SwiftUI.
@MainActor
@Observable
public final class AppModel {
    public private(set) var snapshot = PumpSnapshot()
    public private(set) var glucoseHistory: [GlucoseReading] = []
    public var lastError: String?

    /// A bolus requested by a remote (watch/Garmin) awaiting the phone's confirmation.
    public struct PendingRemoteBolus: Equatable, Sendable { public let requestId: String; public let units: Double }
    public var pendingRemoteBolus: PendingRemoteBolus?
    /// Set by PhoneRemoteHost to echo status back to the remote.
    public var remoteStatusEcho: (@MainActor (RemoteCommand) -> Void)?

    private let source: PumpDataSource

    /// 6-digit JPAKE pairing code, entered before connecting to a real pump.
    public var pairingCode: String {
        get { source.pairingCode } set { source.pairingCode = newValue }
    }
    /// True when a saved pairing exists — Connect can resume without a code.
    public var hasStoredPairing: Bool { source.hasStoredPairing }
    public func forgetPairing() { source.forgetPairing() }

    public init(source: PumpDataSource) {
        self.source = source
        self.snapshot = source.snapshot
        self.glucoseHistory = source.glucoseHistory
        source.onChange = { [weak self] in self?.refresh() }
    }

    private func refresh() {
        snapshot = source.snapshot
        glucoseHistory = source.glucoseHistory
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
            remoteStatusEcho?(RemoteCommand(kind: .bolusStatus, requestId: pending.requestId,
                                            status: .delivered, deliveredUnits: delivered))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            remoteStatusEcho?(RemoteCommand(kind: .bolusStatus, requestId: pending.requestId,
                                            status: .failed, message: error.localizedDescription))
        }
        refresh()
    }

    public func rejectRemoteBolus() {
        if let pending = pendingRemoteBolus {
            remoteStatusEcho?(RemoteCommand(kind: .bolusStatus, requestId: pending.requestId,
                                            status: .cancelled))
        }
        pendingRemoteBolus = nil
    }
}
