import Alerts
import Foundation
import PumpSession
import RemoteProtocol
import faBolusCore

/// The host's services from the app's own parts: the pump session, the ledger and the alert pipeline,
/// plus the backup CGM source and the glucose history, which the app owns.
public struct SessionRemoteServices: RemoteHostServices {
    let session: PumpSession
    let ledger: DurableBolusLedger
    let alerts: AlertCoordinator
    let peerId: String
    let backupGlucose: @Sendable () async -> GlucoseSourceState?
    let history: @Sendable (Date) async -> [faBolusCore.GlucoseReading]
    let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - backupGlucose: the selected backup source's state, or `nil` when there is none.
    ///   - history: glucose since a time, oldest first (the app's `GlucoseHistoryStore`).
    public init(
        session: PumpSession, ledger: DurableBolusLedger, alerts: AlertCoordinator, peerId: String = "garmin",
        backupGlucose: @escaping @Sendable () async -> GlucoseSourceState?,
        history: @escaping @Sendable (Date) async -> [faBolusCore.GlucoseReading],
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.ledger = ledger
        self.alerts = alerts
        self.peerId = peerId
        self.backupGlucose = backupGlucose
        self.history = history
        self.clock = clock
    }

    public func pump() async -> (PumpState, GlucoseProvenance) {
        await merge(await session.state, freshness: await session.freshness)
    }

    public func bolusBlock() async -> BolusBlock? { await ledger.block }

    public func ledgerEntry(_ key: RemoteBolusLedger.Key) async -> RemoteBolusLedger.Entry? {
        await ledger.ledger.entry(key)
    }

    public func compose(
        _ request: RemoteDoseRequest, access: AccessPolicy.AccessContext, remoteSizeLimitUnits: Double?
    ) async -> RemoteDoseDecision {
        let preparation = await session.prepareDose()
        let (pump, _) = await merge(preparation.pump, freshness: preparation.freshness)
        return DoseComposer.composeRemote(
            request, ledger: preparation.ledger,
            context: preparation.context(pump: pump, access: access, remoteSizeLimitUnits: remoteSizeLimitUnits))
    }

    public func deliver(_ dose: ComposedDose) async -> DeliveryResult { await session.deliver(dose) }

    public func cancelBolus() async -> CancelResult { await session.cancelBolus() }

    public func dismiss(_ alert: PumpAlert) async -> DismissOutcome { await session.dismiss(alert) }

    public func refreshGlucose() async { await session.refreshGlucose() }

    public func glucoseHistory(since: Date) async -> [faBolusCore.GlucoseReading] { await history(since) }

    /// From the logbook projection the session keeps (newest first). It is in memory, so after a relaunch
    /// there is none until history shows one again: "none known", never a wrong time.
    public func lastAutoCorrection() async -> Date? {
        await session.historyEvents.first { $0.category == .autoCorrection }?.date
    }

    public func ledgerRefusal(_ key: RemoteBolusLedger.Key) async -> RemoteBolusLedger.RemoteRefusal? {
        await ledger.ledger.remoteRefusal(key)
    }

    /// A failed save keeps it in memory and blocks new boluses until a save succeeds (the ledger's rule), so
    /// there's nothing more to do here.
    public func recordRefusal(_ key: RemoteBolusLedger.Key, reason: String) async {
        _ = try? await ledger.recordRemoteRefusal(key, reason: reason, now: clock())
    }

    public func remoteBolusRefused(requestId: String, reason: String) async {
        await alerts.remoteBolusRefused(peerId: peerId, requestId: requestId, reason: reason)
    }

    private func merge(_ state: PumpState, freshness: FreshnessThresholds) async -> (PumpState, GlucoseProvenance) {
        let (merged, _, provenance) = GlucoseArbiter.merge(
            pumpState: state, pumpHistory: [], source: await backupGlucose(), thresholds: freshness, now: clock())
        return (merged, provenance)
    }
}
