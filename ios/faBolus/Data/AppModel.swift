import Foundation
import faBolusCore
import Observation

/// Observable app state bridging a `PumpBackend` to SwiftUI.
@MainActor
@Observable
public final class AppModel {
    public private(set) var snapshot = PumpSnapshot()
    public private(set) var glucoseHistory: [GlucoseReading] = []
    public private(set) var iobHistory: [IOBSample] = []
    public private(set) var bolusMarkers: [BolusMarker] = []
    public private(set) var activeNotifications: [PumpAlert] = []
    public private(set) var alertDebug: String = ""
    public var lastError: String?

    /// The active backend's capabilities, so the UI can hide unsupported features.
    public var capabilities: PumpCapabilities { source.capabilities }

    /// Fired whenever the active pump-alert set changes, so a notifier can post/clear iOS
    /// notifications the user can act on.
    public var onNotificationsChange: (@MainActor ([PumpAlert]) -> Void)?

    /// Clear a pump alert/alarm from the app (signed dismiss on the pump).
    public func dismissNotification(_ n: PumpAlert) async { await source.dismissNotification(n); refresh() }

    /// Build the full status a remote (Apple Watch / Garmin) shows. Shared so every remote gets
    /// the same fields (trend, staleness, reservoir, last bolus, alerts, and optionally history).
    public func statusCommand(includeHistory: Bool) -> RemoteCommand {
        let s = snapshot
        let age = s.glucoseDate.map { max(0, Date().timeIntervalSince($0)) }
        let alertList = activeNotifications.map {
            RemoteCommand.RemoteAlert(id: $0.id, kind: $0.kind.rawValue, title: $0.title)
        }
        let history = includeHistory ? Array(glucoseHistory.suffix(288).map { $0.mgdl }) : nil
        return RemoteCommand(kind: .statusRead, units: s.iobUnits,
                             bgMgdl: s.glucose.map(Double.init), message: s.connection.rawValue,
                             trend: GlucoseTrend.token(from: s.trend),
                             carbRatio: s.carbRatio > 0 ? s.carbRatio : nil,
                             isf: s.isf > 0 ? Double(s.isf) : nil,
                             targetBg: s.targetBg > 0 ? Double(s.targetBg) : nil,
                             maxBolusUnits: s.maxBolusUnits,
                             reservoirUnits: s.reservoirUnits,
                             batteryPercent: Double(s.batteryPercent),
                             lastBolusUnits: s.lastBolusUnits,
                             glucoseAgeSec: age,
                             history: (history?.isEmpty ?? true) ? nil : history,
                             alerts: alertList,
                             bolusMode: AppSettings.shared.defaultBolusMode.rawValue,
                             bolusIncrement: AppSettings.shared.watchBolusIncrement,
                             carbIncrement: AppSettings.shared.watchCarbIncrement,
                             screenOrder: AppSettings.shared.garminScreenOrder,
                             defaultScreen: AppSettings.shared.garminDefaultScreen,
                             glucoseStaleMinutes: AppSettings.shared.glucoseStaleMinutes,
                             glucoseHideDelayMinutes: AppSettings.shared.glucoseHideDelayMinutes)
    }

    /// Clear a pump alert by id + kind (used by remotes' dismiss commands).
    public func dismissAlert(id: Int, kind: Int) async {
        guard let n = activeNotifications.first(where: { $0.id == id && $0.kind.rawValue == kind }) else { return }
        await dismissNotification(n)
    }

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
    /// Push status to remotes right now, ignoring the throttle (used for alert changes).
    private func forceStatusPush() {
        lastStatusPush = Date()
        for h in statusListeners { h(snapshot) }
    }
    private func pushStatusIfNeeded() {
        guard !statusListeners.isEmpty else { return }
        // Push on a glucose change, or at most once every 15 s otherwise.
        let changed = snapshot.glucose != lastPushedGlucose
        guard changed || Date().timeIntervalSince(lastStatusPush) > 15 else { return }
        lastStatusPush = Date(); lastPushedGlucose = snapshot.glucose
        for h in statusListeners { h(snapshot) }
    }

    private let source: PumpBackend

    /// Optional independent CGM feed used as a **failover** when the pump-relayed glucose goes stale.
    /// nil = pump-relayed glucose only. Selected via `GlucoseSourceRegistry`.
    private var glucoseSource: GlucoseSource?

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

    public init(source: PumpBackend) {
        self.source = source
        self.snapshot = source.snapshot
        self.glucoseHistory = source.glucoseHistory
        source.onChange = { [weak self] in self?.refresh() }
        // Optional glucose failover source: re-arbitrate whenever it has new data, and start it.
        let gs = GlucoseSourceRegistry.makeSelected()
        self.glucoseSource = gs
        gs?.onChange = { [weak self] in self?.refresh() }
        if let gs { Task { await gs.start() } }
    }

    /// Set when a widget's tap-to-bolus deep link opens the app; the HUD observes it to present
    /// the bolus-entry sheet.
    public var openBolusRequested = false

    private func refresh() {
        // Primary = pump-relayed glucose; fail over to the independent source when the pump feed is
        // stale. A stale reading is never published as current (see GlucoseArbiter).
        // Tell the source whether the primary is healthy so cloud pollers throttle (battery-aware).
        let pumpFresh = source.snapshot.glucose != nil && !GlucoseFreshness.isStale(source.snapshot.glucoseDate)
        glucoseSource?.setPrimaryHealthy(pumpFresh)
        let (snap, hist) = GlucoseArbiter.merge(pumpSnapshot: source.snapshot,
                                                pumpHistory: source.glucoseHistory,
                                                source: glucoseSource)
        snapshot = snap
        glucoseHistory = hist
        iobHistory = source.iobHistory
        bolusMarkers = source.bolusMarkers
        let alertsChanged = activeNotifications != source.activeNotifications
        activeNotifications = source.activeNotifications
        alertDebug = source.alertDebug
        WidgetPublisher.publish(snapshot, history: glucoseHistory, alerts: activeNotifications.map { $0.title })
        pushStatusIfNeeded()
        if alertsChanged {
            onNotificationsChange?(activeNotifications)
            forceStatusPush()   // get alert changes to the watch immediately (bypass throttle)
        }
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
            echo(bolusOutcome(requestId: pending.requestId, delivered: delivered))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            echo(RemoteCommand(kind: .bolusStatus, requestId: pending.requestId,
                               status: .failed, message: error.localizedDescription))
        }
        refresh()
    }

    /// Build the final bolus-status echo, distinguishing a full delivery from a cancelled
    /// (partial) one so the remote can tell the user exactly what happened.
    private func bolusOutcome(requestId: String, delivered: Double) -> RemoteCommand {
        if source.lastBolusCancelled {
            return RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .cancelled,
                                 deliveredUnits: delivered,
                                 message: String(format: "Cancelled · %.2f U delivered", delivered))
        }
        return RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .delivered,
                             deliveredUnits: delivered)
    }

    /// Deliver a bolus already confirmed on the remote itself (e.g. Garmin hold-to-deliver) —
    /// no phone-side dialog. Echoes delivering → delivered/failed back to the remote.
    public func remoteDeliver(requestId: String, units: Double) async {
        echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .delivering))
        do {
            let delivered = try await source.deliverBolus(units: units)
            echo(bolusOutcome(requestId: requestId, delivered: delivered))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId,
                               status: .failed, message: error.localizedDescription))
        }
        refresh()
    }

    /// Deliver a bolus confirmed on the Quick-Bolus widget (its 1-2-3 tap is the confirmation).
    /// Same validated signed path as a remote bolus; returns the outcome so the widget can show
    /// delivered/cancelled/failed in place.
    public func deliverWidgetBolus(requestId: String, units: Double) async -> (delivered: Double, cancelled: Bool, error: String?) {
        echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .delivering))
        do {
            let delivered = try await source.deliverBolus(units: units)
            echo(bolusOutcome(requestId: requestId, delivered: delivered))
            lastError = nil
            refresh()
            return (delivered, source.lastBolusCancelled, nil)
        } catch {
            lastError = error.localizedDescription
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: error.localizedDescription))
            refresh()
            return (0, false, error.localizedDescription)
        }
    }

    public func rejectRemoteBolus() {
        if let pending = pendingRemoteBolus {
            echo(RemoteCommand(kind: .bolusStatus, requestId: pending.requestId, status: .cancelled))
        }
        pendingRemoteBolus = nil
    }
}
