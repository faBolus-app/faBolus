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
    /// Decoded history-log events for the Logbook (B2), newest first.
    public private(set) var historyEvents: [HistoryEvent] = []
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

    /// A suspend/resume requested by a remote, awaiting the phone's on-device confirmation (B5).
    public struct PendingRemoteControl: Equatable, Sendable {
        public enum Action: String, Sendable { case suspend, resume }
        public let requestId: String; public let action: Action
    }
    public var pendingRemoteControl: PendingRemoteControl?

    /// Called by a remote bridge when the watch/Garmin requests suspend/resume. Only honored when
    /// advanced control is enabled for a Mobi; otherwise rejected back to the remote. Never executes
    /// directly — it stages a phone-side confirmation (RootTabView presents the alert).
    public func requestRemoteControl(requestId: String, action: PendingRemoteControl.Action) {
        guard advancedControlAllowed else {
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed,
                                          message: "Advanced control is off"))
            return
        }
        pendingRemoteControl = PendingRemoteControl(requestId: requestId, action: action)
    }
    public func confirmRemoteControl() async {
        guard let p = pendingRemoteControl else { return }
        pendingRemoteControl = nil
        switch p.action {
        case .suspend: await suspendDelivery()
        case .resume: await resumeDelivery()
        }
        let ok = lastError == nil
        echo(RemoteCommand(kind: .bolusStatus, requestId: p.requestId,
                                      status: ok ? .delivered : .failed,
                                      message: ok ? (p.action == .suspend ? "Suspended" : "Resumed") : (lastError ?? "Failed")))
    }
    public func rejectRemoteControl() {
        if let p = pendingRemoteControl {
            echo(RemoteCommand(kind: .bolusStatus, requestId: p.requestId, status: .cancelled, message: "Rejected on phone"))
        }
        pendingRemoteControl = nil
    }
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
    /// Periodic re-arbitration so failover stays live when the pump is quiet (see init).
    private var arbiterTimer: Timer?

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

    // MARK: - Mobi PIN saving
    // The Tandem Mobi's 6-digit PIN is fixed. After a full pairing (a typed code) completes on a
    // pump detected as a Mobi, offer to save that PIN so re-pairing skips re-typing. Users can pair
    // a different device with a different PIN anytime by editing the code or clearing the saved one.

    /// The saved Mobi PIN, if any (prefilled into the pairing screen). Editable/clearable there.
    public var savedPin: String? { PairingStore.loadPin() }
    public func clearSavedPin() { PairingStore.clearPin() }

    /// Non-nil ⇒ the app should ask the user whether to save this just-used PIN (a Mobi was
    /// recognized). Holds the PIN to save.
    public var savePinPrompt: String?
    public func saveOfferedPin() { if let c = savePinPrompt { PairingStore.savePin(c) }; savePinPrompt = nil }
    public func dismissSavePinPrompt() { savePinPrompt = nil }

    /// The code the user just typed for a full pairing (nil once consumed / on a resume connect),
    /// so we can offer to save it once the pairing succeeds and we know it's a Mobi.
    private var enteredPairCode: String?

    /// Connect using a freshly-typed pairing code (full pairing). Remembers the code so a Mobi
    /// save-PIN offer can fire on success.
    public func connectWithCode(_ code: String) async {
        enteredPairCode = code
        pairingCode = code
        await connect()
    }

    /// After a full pairing completes on a Mobi, raise the save-PIN offer (once).
    private func evaluateSavePinOffer() {
        switch snapshot.connection {
        case .connected, .bolusing:
            guard enteredPairCode != nil else { return }
            // Wait until the pump model is known — it comes from ApiVersionResponse (authoritative),
            // which arrives shortly after connect, not at discovery. pumpModelName is empty until then.
            guard !snapshot.pumpModelName.isEmpty else { return }
            let code = enteredPairCode!
            enteredPairCode = nil
            if snapshot.isMobi, code != PairingStore.loadPin() { savePinPrompt = code }
        case .disconnected, .error:
            enteredPairCode = nil   // pairing didn't complete — drop the pending offer
        default:
            break
        }
    }

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
        // Re-arbitrate on a timer too: onChange only fires on NEW data, so when the pump is
        // disconnected/quiet the failover wouldn't otherwise take over (or a value wouldn't age).
        // This keeps the pump-vs-source freshness re-evaluated so failover stays live regardless.
        if gs != nil {
            arbiterTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
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
        historyEvents = source.historyEvents
        let alertsChanged = activeNotifications != source.activeNotifications
        activeNotifications = source.activeNotifications
        alertDebug = source.alertDebug
        WidgetPublisher.publish(snapshot, history: glucoseHistory, alerts: activeNotifications.map { $0.title })
        evaluateSavePinOffer()
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

    // MARK: Advanced control (B3) — gated in the UI by `advancedControlAllowed`.

    /// The single gate the control UI uses: opt-in ON, pump is a Mobi, and the backend advertises
    /// at least one advanced-control capability.
    public var advancedControlAllowed: Bool {
        AppSettings.shared.advancedControlAllowed(isMobi: snapshot.isMobi)
            && capabilities.supportsAnyAdvancedControl
    }

    private func runControl(_ op: () async throws -> Void) async {
        do { try await op(); lastError = nil } catch { lastError = error.localizedDescription }
        refresh()
    }
    public func suspendDelivery() async { await runControl { try await source.suspendDelivery() } }
    public func resumeDelivery() async { await runControl { try await source.resumeDelivery() } }
    public func setTempBasal(percent: Int, durationMinutes: Int) async {
        await runControl { try await source.setTempBasal(percent: percent, durationMinutes: durationMinutes) }
    }
    public func stopTempBasal() async { await runControl { try await source.stopTempBasal() } }
    public func setMode(bitmap: Int) async { await runControl { try await source.setMode(bitmap: bitmap) } }
    public func playFindMyPump() async { await runControl { try await source.playFindMyPump() } }

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
