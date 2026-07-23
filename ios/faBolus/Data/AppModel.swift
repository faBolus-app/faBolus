import Foundation
import faBolusCore
import HistoryStore
import DosingSafetyKit
import GlucoseIntelligenceKit
import TherapyInsightsKit
import AlertIntelligenceKit
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

    // Persistent history (SwiftData) — write-through target for long-term glucose/bolus history; powers
    // time-in-range / future plotting and feeds the advisory tools. Optional so a store-init failure
    // never breaks the app. See MIGRATION.md (Phase 2).
    private let history: GlucoseHistoryStore? = try? GlucoseHistoryStore()
    private var lastGlucoseIngest = Date.distantPast
    private var lastBolusIngest = Date.distantPast

    // Predictive-low (GlucoseIntelligenceKit) — advisory, gated by AppSettings.hypoAlertsEnabled.
    private let hypoEngine = SmartAssist.makeHypoEngine()
    private var lastHypoIngest = Date.distantPast
    private(set) var hypoWarning: HypoAlert?

    // Eating nudge (multi-signal fusion) — advisory, gated by AppSettings.eatingNudgesEnabled.
    @ObservationIgnored private var eatingEngine = EatingTriggerEngine(config: AppSettings.shared.eatingTriggerConfig)
    @ObservationIgnored private var lastEatingConfig: Data?
    @ObservationIgnored private let mealDetector = MealDetector()
    /// Latest accel p(eating) from the Garmin/watch path (nil if no wrist signal available).
    @ObservationIgnored public var latestAccelProb: Double?
    @ObservationIgnored private var lastAccelWindowAt = Date.distantPast
    @ObservationIgnored private let accelPipeline = EatingAccelPipeline()
    /// Set by the Garmin/watch bridge — the phone calls this to start/stop wrist sensing on demand
    /// (battery: for cgmThenAccel, only escalate when the CGM hints a meal).
    @ObservationIgnored public var onWantAccelSensing: ((Bool) -> Void)?
    @ObservationIgnored private var lastWantAccel = false
    private(set) var eatingNudge: EatingAlert?

    private func setWantAccelSensing(_ on: Bool) {
        guard on != lastWantAccel else { return }
        lastWantAccel = on
        onWantAccelSensing?(on)
    }

    /// Feed a raw IMU window from the Garmin watch (imu_window message) → phone-side p(eating).
    public func ingestGarminIMUWindow(rawWindow raw: [Float]) {
        guard let p = accelPipeline.predict(rawWindow: raw) else { return }
        latestAccelProb = p
        lastAccelWindowAt = Date()
    }
    /// Decoded history-log events for the Logbook (B2), newest first.
    public private(set) var historyEvents: [HistoryEvent] = []
    public private(set) var alertDebug: String = ""
    public var lastError: String?

    /// Where the currently-shown live glucose came from (pump vs a failover source). Drives the
    /// small "via <source>" badge; `.pump` means nothing extra is shown (keeps the UI clean).
    public private(set) var glucoseProvenance: GlucoseProvenance = .pump

    /// A short source name + human reason when the live glucose is coming from a **failover** source
    /// instead of the pump; `nil` when the pump feed is live. The UI only shows a badge when non-nil.
    public var failoverBadge: (name: String, reason: String)? {
        guard case let .failover(sourceID, reason) = glucoseProvenance else { return nil }
        let full = GlucoseSourceRegistry.descriptor(id: sourceID)?.name ?? sourceID
        let name = Self.shortSourceName(full)
        switch reason {
        case .pumpMissing: return (name, "Showing \(full) — the pump has no CGM reading.")
        case .pumpStale:   return (name, "Showing \(full) — the pump's CGM reading went stale.")
        }
    }

    /// A compact source name for the small "via …" failover badge — drops the parenthetical/qualifier
    /// so no source name overruns the ring (e.g. "Dexcom Share (cloud, last resort)" → "Dexcom Share",
    /// "Dexcom G7 / ONE+ (direct BLE)" → "Dexcom G7").
    static func shortSourceName(_ full: String) -> String {
        var s = full
        for sep in [" (", " — ", " / "] {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// The active backend's capabilities, so the UI can hide unsupported features.
    public var capabilities: PumpCapabilities { source.capabilities }

    /// Fired whenever the active pump-alert set changes, so a notifier can post/clear iOS
    /// notifications the user can act on.
    public var onNotificationsChange: (@MainActor ([PumpAlert]) -> Void)?

    // MARK: Child (locked) mode gate

    /// Whether `feature` is permitted right now. In child mode, blocked actions no-op with a message.
    /// This is the single enforcement point for the phone, the widget, **and** every remote (they all
    /// route through the gated methods below), so a locked device can't be driven from a watch/Garmin.
    private func childAllows(_ feature: ChildFeature) -> Bool { AppSettings.shared.childAllows(feature) }
    private func childBlocked(_ feature: ChildFeature) -> Bool {
        guard !childAllows(feature) else { return false }
        lastError = "Locked (child mode): \(feature.label.lowercased()) is disabled."
        return true
    }
    /// True when read-only mode is on (this phone is a safe viewer): blocks bolusing + pump control.
    private func readOnlyBlocked(_ what: String = "This action") -> Bool {
        guard AppSettings.shared.phoneReadOnly else { return false }
        lastError = "\(what) is disabled — the app is in read-only mode."
        return true
    }

    /// Clear a pump alert/alarm from the app (signed dismiss on the pump).
    public func dismissNotification(_ n: PumpAlert, enforceChildLock: Bool = true) async {
        if enforceChildLock, childBlocked(.dismissAlerts) { return }
        await source.dismissNotification(n); refresh()
    }

    /// Build the full status a remote (Apple Watch / Garmin) shows. Shared so every remote gets
    /// the same fields (trend, staleness, reservoir, last bolus, alerts, and optionally history).
    public func statusCommand(includeHistory: Bool) -> RemoteCommand {
        let s = snapshot
        let age = s.glucoseDate.map { max(0, Date().timeIntervalSince($0)) }
        let alertList = activeNotifications.map {
            RemoteCommand.RemoteAlert(id: $0.id, kind: $0.kind.rawValue, title: $0.title)
        }
        let recent = includeHistory ? Array(glucoseHistory.suffix(288)) : []
        let history = includeHistory ? recent.map { $0.mgdl } : nil
        let historyEpochs = includeHistory ? recent.map { Int($0.date.timeIntervalSince1970) } : nil
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
                             basalRate: s.basalRateUnitsPerHour,
                             glucoseAgeSec: age,
                             history: (history?.isEmpty ?? true) ? nil : history,
                             historyEpochs: (historyEpochs?.isEmpty ?? true) ? nil : historyEpochs,
                             alerts: alertList,
                             bolusMode: AppSettings.shared.watchDefaultBolusMode.rawValue,
                             bolusIncrement: AppSettings.shared.watchBolusIncrement,
                             carbIncrement: AppSettings.shared.watchCarbIncrement,
                             screenOrder: AppSettings.shared.garminScreenOrder,
                             defaultScreen: AppSettings.shared.garminDefaultScreen,
                             glucoseStaleMinutes: AppSettings.shared.glucoseStaleMinutes,
                             glucoseHideDelayMinutes: AppSettings.shared.glucoseHideDelayMinutes,
                             detailsOrder: AppSettings.shared.watchDetailsOrder,   // remotes use the watch-specific order
                             watchChartRanges: AppSettings.shared.watchChartRanges,
                             garminComplicationDisplay: AppSettings.shared.garminComplicationDisplay,
                             remotesReadOnly: AppSettings.shared.remotesReadOnly)
    }

    /// Clear a pump alert by id + kind (used by remotes' dismiss commands).
    public func dismissAlert(id: Int, kind: Int, enforceChildLock: Bool = true) async {
        // In read-only mode the phone's own alert-clearing is off unless the sub-option allows it.
        // (`enforceChildLock` marks the phone's own path; remote dismisses pass false.)
        if enforceChildLock, AppSettings.shared.phoneReadOnly, !AppSettings.shared.readOnlyAllowAlertClear {
            lastError = "Clearing alerts is disabled in read-only mode."
            return
        }
        guard let n = activeNotifications.first(where: { $0.id == id && $0.kind.rawValue == kind }) else { return }
        await dismissNotification(n, enforceChildLock: enforceChildLock)
    }

    /// A bolus requested by a remote (watch/Garmin) awaiting the phone's confirmation.
    public struct PendingRemoteBolus: Equatable, Sendable {
        public let requestId: String; public let units: Double
        /// False when an authorized peer (parent remote) originated it — child lock is bypassed for them.
        public var enforceChildLock: Bool = true
    }
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
    private var lastPushedConnection: PumpConnectionState?
    /// Push status to remotes right now, ignoring the throttle (used for alert changes + right after
    /// a control action so the watch reflects it instantly).
    func forceStatusPush() {
        lastStatusPush = Date(); lastPushedGlucose = snapshot.glucose; lastPushedConnection = snapshot.connection
        for h in statusListeners { h(snapshot) }
    }
    private func pushStatusIfNeeded() {
        guard !statusListeners.isEmpty else { return }
        // Push immediately (bypassing the 15 s throttle) on a glucose change and — the time-sensitive
        // cases — whenever the connection state changes (so the watch sees the bolus start and the
        // "delivered"/back-to-connected transition instantly) and continuously while a bolus is in
        // progress. Otherwise at most once every 15 s to spare phone + watch battery.
        let glucoseChanged = snapshot.glucose != lastPushedGlucose
        let connChanged = snapshot.connection != lastPushedConnection
        let bolusing = snapshot.connection == .bolusing
        guard glucoseChanged || connChanged || bolusing
                || Date().timeIntervalSince(lastStatusPush) > 15 else { return }
        lastStatusPush = Date(); lastPushedGlucose = snapshot.glucose; lastPushedConnection = snapshot.connection
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

    /// Weak reference to the live model, so headless App Intents (activity/sleep mode automation)
    /// can reach it when the app is running. nil when the app process isn't alive — the intent then
    /// falls back to a queued request + reminder (see `ModeAutomation`).
    public static weak var shared: AppModel?

    public init(source: PumpBackend) {
        self.source = source
        self.snapshot = source.snapshot
        self.glucoseHistory = source.glucoseHistory
        Self.shared = self
        source.onChange = { [weak self] in self?.refresh() }
        // Correct the pump clock immediately when the phone's time or time zone changes (travel / DST).
        for name in [NSNotification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.maybeAutoSyncPumpTime(force: true) }
            }
        }
        // Optional glucose failover source, with a crash-loop guard: if the selected source was armed
        // on the previous launch and never disarmed, it crashed during start — do NOT auto-start it
        // again (that would brick every launch). The user re-enables it by re-selecting it in
        // Settings (which clears the guard); by then any fix has shipped.
        let selId = GlucoseSourceRegistry.selectedId()
        if let selId, UserDefaults.standard.string(forKey: Self.sourceCrashGuardKey) == selId {
            UserDefaults.standard.removeObject(forKey: Self.sourceCrashGuardKey)
            self.glucoseSource = nil
            self.failoverAutoDisabled = selId
        } else if let gs = GlucoseSourceRegistry.makeSelected(), let selId {
            self.glucoseSource = gs
            gs.onChange = { [weak self] in self?.refresh() }
            UserDefaults.standard.set(selId, forKey: Self.sourceCrashGuardKey)   // arm
            Task { await gs.start() }
            // Disarm once it survives ~10s without crashing the launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if UserDefaults.standard.string(forKey: Self.sourceCrashGuardKey) == selId {
                    UserDefaults.standard.removeObject(forKey: Self.sourceCrashGuardKey)
                }
            }
            // Re-arbitrate on a timer too: onChange only fires on NEW data, so when the pump is
            // disconnected/quiet the failover would not otherwise take over (or a value would not age).
            arbiterTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    static let sourceCrashGuardKey = "glucoseSourceCrashGuard"
    /// Non-nil ⇒ the failover source (this id) was auto-disabled after a launch crash; re-select it
    /// in Settings to try again.
    public private(set) var failoverAutoDisabled: String?

    /// Set when a widget's tap-to-bolus deep link opens the app; the HUD observes it to present
    /// the bolus-entry sheet.
    public var openBolusRequested = false

    /// Write only NEW readings/boluses into the persistent store (never re-insert the rolling buffer).
    private func persistNewHistory(provenance: GlucoseProvenance) {
        guard let history else { return }
        let sourceID: String
        let priority: Int
        switch provenance {
        case .failover(let sid, _): sourceID = sid;    priority = 100   // independent source
        default:                    sourceID = "pump"; priority = 50    // pump-relayed
        }
        let newGlucose = glucoseHistory.filter { $0.date > lastGlucoseIngest }
        if !newGlucose.isEmpty {
            history.ingestGlucose(newGlucose, sourceID: sourceID, priority: priority)
            lastGlucoseIngest = newGlucose.map(\.date).max() ?? lastGlucoseIngest
        }
        let newBoluses = bolusMarkers.filter { $0.date > lastBolusIngest }
        if !newBoluses.isEmpty {
            history.ingestBoluses(newBoluses, sourceID: "pump")
            lastBolusIngest = newBoluses.map(\.date).max() ?? lastBolusIngest
        }
    }

    /// Time-in-range / GMI over the *persisted* history (default 90 days) — for stats / future plotting.
    public func storedStatistics(days: Int = 90) -> GlucoseStatistics? {
        guard let history else { return nil }
        let end = Date(); let start = end.addingTimeInterval(-Double(days) * 86400)
        return history.statistics(in: start...end)
    }

    /// Wipe all persisted history (Settings → data-minimization / "Clear history").
    public func clearStoredHistory() { history?.clear() }

    /// Advisory "Smart Assist" warnings for a bolus the user is about to give (predicted low / stacking /
    /// oversized). Empty when the feature is off or nothing's concerning. Advisory only — never blocks.
    public func smartAssistWarnings(units: Double, carbs: Double, recommendedUnits: Double?) -> [String] {
        guard AppSettings.shared.smartAssistEnabled else { return [] }
        return SmartAssist.warnings(units: units, carbs: carbs, recommendedUnits: recommendedUnits,
                                    snapshot: snapshot, glucoseHistory: glucoseHistory,
                                    bolusMarkers: bolusMarkers).map(\.message)
    }

    /// Approximate on-disk size of stored history, for a "history uses ~X MB" line.
    public func storedHistoryApproxBytes() -> Int { history?.approximateBytes() ?? 0 }

    /// Apply a retention window (days); 0 = keep everything. Safe to call any time (e.g. on launch and
    /// when the setting changes).
    public func applyRetention(days: Int) {
        guard days > 0, let history else { return }
        history.deleteGlucose(olderThan: Date().addingTimeInterval(-Double(days) * 86400))
    }

    private var hypoDelegateSet = false
    /// Feed new readings to the predictive-low engine; it publishes via the delegate below (advisory).
    private func updateHypoWarning() {
        guard AppSettings.shared.hypoAlertsEnabled else { hypoWarning = nil; return }
        if !hypoDelegateSet { hypoEngine.delegate = self; hypoDelegateSet = true }
        let fresh = glucoseHistory.filter { $0.date > lastHypoIngest }.sorted { $0.date < $1.date }
        for r in fresh {
            hypoEngine.ingest(GlucoseIntelligenceKit.CGMReading(mgdl: Double(r.mgdl), date: r.date))
        }
        lastHypoIngest = fresh.last?.date ?? lastHypoIngest
        if let w = hypoWarning, Date().timeIntervalSince(w.at) > Double(w.horizonMinutes) * 60 {
            hypoWarning = nil   // expire past its horizon
        }
    }

    /// Record user-entered carbs (from a carb bolus) into the persistent store, so sensitivity/insights
    /// have carb context. Source = faBolus (its own entry).
    public func recordCarbs(grams: Double) {
        guard grams > 0 else { return }
        history?.ingestCarbs([(date: Date(), grams: grams)], sourceID: "fabolus")
    }

    /// Retrospective pattern insights over persisted history (dawn phenomenon, recurring lows, TIR).
    public func therapyInsights() -> [PatternInsights.Insight] {
        let range = Date().addingTimeInterval(-90 * 86400)...Date()
        let cgm = history?.glucose(in: range) ?? glucoseHistory
        return SmartAssist.insights(cgm: cgm, carbs: history?.carbs(in: range) ?? [])
    }

    /// Best available basal schedule (24 hourly U/hr) — external (Nightscout profile) or pump. nil if unknown.
    public func basalByHour() -> [Double]? {
        let s = AppSettings.shared.basalScheduleByHour
        return s.count == 24 ? s : nil
    }
    /// Human label for where the basal schedule came from ("" if none).
    public var basalScheduleSource: String { AppSettings.shared.basalScheduleSource }

    /// Insulin-sensitivity assessment (autosens-style) over the last ~14 days of stored data.
    public func sensitivityState() -> SensitivityMonitor.State? {
        guard let history, snapshot.isf > 0, snapshot.carbRatio > 0 else { return nil }
        let range = Date().addingTimeInterval(-14 * 86400)...Date()
        return SmartAssist.sensitivity(cgm: history.glucose(in: range), insulin: history.boluses(in: range),
                                       carbs: history.carbs(in: range), basalByHour: basalByHour() ?? [],
                                       isf: snapshot.isf, carbRatio: snapshot.carbRatio, targetBg: snapshot.targetBg)
    }

    /// Settings advice (ISF / carb-ratio, and basal drift once a basal schedule is available). Advisory;
    /// needs weeks of data for confidence.
    public func settingsAdvice() -> TherapyAdvice? {
        guard let history, snapshot.isf > 0, snapshot.carbRatio > 0 else { return nil }
        let range = Date().addingTimeInterval(-30 * 86400)...Date()
        return SmartAssist.settingsAdvice(cgm: history.glucose(in: range), insulin: history.boluses(in: range),
                                          carbs: history.carbs(in: range), basalByHour: basalByHour() ?? [],
                                          isf: snapshot.isf, carbRatio: snapshot.carbRatio, targetBg: snapshot.targetBg)
    }

    /// Run the REAL oref0 autotune over stored data (experimental; needs weeks of data). On-demand only
    /// (heavy: loads the oref JS bundle in JavaScriptCore) — runs off the main actor.
    public func autotuneSuggestions() async -> [String] {
        guard let history, let basal = basalByHour(), snapshot.isf > 0, snapshot.carbRatio > 0 else { return [] }
        let range = Date().addingTimeInterval(-30 * 86400)...Date()
        let cgm = history.glucose(in: range), bol = history.boluses(in: range)
        let isf = snapshot.isf, cr = snapshot.carbRatio, tgt = snapshot.targetBg
        return await Task.detached {
            AutotuneAdapter.suggestions(cgm: cgm, boluses: bol, basalByHour: basal, isf: isf,
                                        carbRatio: cr, targetBg: tgt, diaHours: 6) ?? []
        }.value
    }

    private var lastNSBackfill = Date.distantPast
    /// Pull Nightscout treatments (carbs/insulin, when NS is the primary source) + the profile's basal
    /// schedule into faBolus. Throttled hourly. Best-effort/background.
    private func maybeBackfillNightscout() {
        guard GlucoseSourceConfig.string("nightscout.url") != nil,
              Date().timeIntervalSince(lastNSBackfill) > 3600 else { return }
        lastNSBackfill = Date()
        let nsPrimary = GlucoseSourceRegistry.selectedId() == "nightscout"
        Task { [weak self] in
            guard let r = await NightscoutBackfill.fetch() else { return }
            await MainActor.run {
                guard let self else { return }
                if nsPrimary {   // else the pump already provides boluses/carbs — avoid double-counting
                    self.history?.ingestCarbs(r.carbs, sourceID: "nightscout")
                    self.history?.ingestBoluses(r.insulin.map { BolusMarker(date: $0.date, units: $0.units) },
                                                sourceID: "nightscout")
                }
                if let b = r.basalByHour, b.count == 24, AppSettings.shared.basalScheduleSource != "Pump" {
                    AppSettings.shared.basalScheduleByHour = b
                    AppSettings.shared.basalScheduleSource = "Nightscout"
                }
            }
        }
    }

    /// Capture the pump's active basal schedule (fallback when no external profile is available).
    public func captureBasalScheduleFromPump() async {
        guard snapshot.connection == .connected else { return }
        let backup = await readPumpSettingsForBackup()
        guard let active = backup.profiles.first(where: { $0.active }) ?? backup.profiles.first,
              !active.segments.isEmpty else { return }
        let segs = active.segments.sorted { $0.startTimeMinutes < $1.startTimeMinutes }
        let byHour: [Double] = (0..<24).map { hour in
            let m = hour * 60
            return (segs.last { $0.startTimeMinutes <= m } ?? segs[0]).basalRateUnitsPerHour
        }
        AppSettings.shared.basalScheduleByHour = byHour
        AppSettings.shared.basalScheduleSource = "Pump"
    }

    /// The learned alarm-fatigue layer for ADVISORY alerts (complements the pump-alert AlertRuleEngine).
    @ObservationIgnored private var alertIntel = AppModel.loadAlertIntel()
    private static func loadAlertIntel() -> AlertIntelligence {
        if let d = UserDefaults.standard.data(forKey: "alertIntel"),
           let a = try? JSONDecoder().decode(AlertIntelligence.self, from: d) { return a }
        return AlertIntelligence()
    }
    private func saveAlertIntel() {
        if let d = try? JSONEncoder().encode(alertIntel) { UserDefaults.standard.set(d, forKey: "alertIntel") }
    }
    /// User dismissed the predictive-low banner → teach the fatigue layer + clear it.
    public func dismissHypoWarning() {
        alertIntel.record("predicted_low", .dismissed); saveAlertIntel(); hypoWarning = nil
    }

    /// Multi-signal eating nudge: gather CGM-meal + accel + no-recent-bolus, run the trigger engine, and
    /// (if it fires and the fatigue layer allows) surface an advisory nudge. Advisory only, never doses.
    private func updateEatingNudge() {
        guard AppSettings.shared.eatingNudgesEnabled else { eatingNudge = nil; setWantAccelSensing(false); return }
        let cfg = AppSettings.shared.eatingTriggerConfig
        if let d = try? JSONEncoder().encode(cfg), d != lastEatingConfig { eatingEngine.setConfig(cfg); lastEatingConfig = d }
        guard let history else { return }

        let range = Date().addingTimeInterval(-2 * 3600)...Date()
        var meal: MealDetector.Result?
        if cfg.mode.usesCGM, snapshot.isf > 0, snapshot.carbRatio > 0 {
            meal = mealDetector.detect(
                glucose: history.glucose(in: range).map { (date: $0.date, mgdl: Double($0.mgdl)) },
                doses: history.boluses(in: range).map { (date: $0.date, units: $0.units) },
                announcedCarbs: history.carbs(in: range),
                carbRatio: snapshot.carbRatio, isf: Double(snapshot.isf))
        }
        // Battery: for cgmThenAccel, only spin up the wrist sensor once the CGM hints a possible meal;
        // other accel modes keep it on while enabled.
        let wantAccel = cfg.mode.usesAccel && (cfg.mode == .cgmThenAccel ? (meal?.score ?? 0) >= 0.3 : true)
        setWantAccelSensing(wantAccel)

        let minsSinceBolus = bolusMarkers.map(\.date).max()
            .map { Date().timeIntervalSince($0) / 60 } ?? .greatestFiniteMagnitude
        // Accel is only valid while the wrist is actively streaming (stale windows → treat as unavailable).
        let accelFresh = Date().timeIntervalSince(lastAccelWindowAt) < 120 ? latestAccelProb : nil
        let signals = EatingSignals(accelProb: cfg.mode.usesAccel ? accelFresh : nil,
                                    cgmMealScore: meal?.score, minutesSinceBolus: minsSinceBolus)

        if case .fire = eatingEngine.evaluate(signals) {
            if case .suppress = alertIntel.decide(AlertIntelligenceKit.Alert(kind: "eating", severity: 1)) { return }
            eatingNudge = EatingAlert(estimatedCarbs: meal?.estimatedCarbs ?? 0, at: Date())
        }
    }

    /// User dismissed the eating nudge → teach the eating fatigue layer + clear it.
    public func dismissEatingNudge() {
        alertIntel.record("eating", .dismissed); saveAlertIntel(); eatingNudge = nil
    }

    private func refresh() {
        // Primary = pump-relayed glucose; fail over to the independent source when the pump feed is
        // stale. A stale reading is never published as current (see GlucoseArbiter).
        // Tell the source whether the primary is healthy so cloud pollers throttle (battery-aware).
        let pumpFresh = source.snapshot.glucose != nil && !GlucoseFreshness.isStale(source.snapshot.glucoseDate)
        glucoseSource?.setPrimaryHealthy(pumpFresh)
        let (snap, hist, provenance) = GlucoseArbiter.merge(pumpSnapshot: source.snapshot,
                                                            pumpHistory: source.glucoseHistory,
                                                            source: glucoseSource)
        snapshot = snap
        glucoseHistory = hist
        glucoseProvenance = provenance
        iobHistory = source.iobHistory
        bolusMarkers = source.bolusMarkers
        historyEvents = source.historyEvents
        let alertsChanged = activeNotifications != source.activeNotifications
        activeNotifications = source.activeNotifications
        alertDebug = source.alertDebug
        WidgetPublisher.publish(snapshot, history: glucoseHistory, alerts: activeNotifications.map { $0.title })
        NightscoutUploader.shared.sync(snapshot: snapshot, glucose: glucoseHistory, boluses: bolusMarkers)
        persistNewHistory(provenance: provenance)
        updateHypoWarning()
        maybeBackfillNightscout()
        updateEatingNudge()
        evaluateSavePinOffer()
        maybeAutoSyncPumpTime()
        if canControlModes { ModeAutomation.applyPendingIfDue(using: self) }   // catch a queued mode switch
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
        if childBlocked(.bolus) { return }
        // Reverse approval (child-mode-only): when child mode is on and set to require a paired
        // remote (parent) to approve boluses, stage the request and wait rather than delivering now.
        if AppSettings.shared.childModeEnabled, AppSettings.shared.requireRemoteBolusApproval, hasPairedRemote {
            requestRemoteApproval(units: units)
            return
        }
        await performLocalBolus(units: units)
    }

    private func performLocalBolus(units: Double) async {
        if readOnlyBlocked("Bolus") { return }
        do { _ = try await source.deliverBolus(units: units); lastError = nil }
        catch { lastError = error.localizedDescription }
        refresh()
    }

    // MARK: Reverse approval (host bolus approved by a paired remote)

    /// A bolus this phone started that's awaiting a paired remote's approval.
    public struct PendingApproval: Equatable, Sendable { public let requestId: String; public let units: Double }
    public private(set) var pendingApproval: PendingApproval?
    private var hasPairedRemote: Bool { !MacPairingCoordinator.shared.pairedMacs.isEmpty }

    private func requestRemoteApproval(units: Double) {
        let id = UUID().uuidString
        pendingApproval = PendingApproval(requestId: id, units: units)
        lastError = nil
        echo(RemoteCommand(kind: .bolusApprovalRequest, requestId: id, units: units))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            guard let self, self.pendingApproval?.requestId == id else { return }
            self.resolveRemoteApproval(requestId: id, approved: false, reason: "No response from the remote")
        }
    }

    /// Called when a remote answers (via `PeerRemoteHost`) or the request times out.
    public func resolveRemoteApproval(requestId: String, approved: Bool, reason: String? = nil) {
        guard let p = pendingApproval, p.requestId == requestId else { return }
        pendingApproval = nil
        if approved {
            Task { await performLocalBolus(units: p.units) }
        } else {
            lastError = "Bolus not approved" + (reason.map { " — \($0)" } ?? "")
        }
    }

    /// Cancel a bolus that's waiting for remote approval (user backed out).
    public func cancelPendingApproval() { pendingApproval = nil }

    /// Deliver an extended (combo) bolus: `nowUnits` up front, the rest over `durationMinutes`.
    public func deliverExtendedBolus(totalUnits: Double, nowUnits: Double, durationMinutes: Int,
                                     enforceChildLock: Bool = true) async {
        if enforceChildLock, childBlocked(.bolus) { return }
        if enforceChildLock, readOnlyBlocked("Bolus") { return }   // phone's own bolus only; peers unaffected
        do { _ = try await source.deliverExtendedBolus(totalUnits: totalUnits, nowUnits: nowUnits, durationMinutes: durationMinutes); lastError = nil }
        catch { lastError = error.localizedDescription }
        refresh()
    }

    public func cancelBolus(enforceChildLock: Bool = true) async {
        if enforceChildLock, childBlocked(.cancelBolus) { return }
        await source.cancelBolus(); refresh()
    }

    // MARK: Advanced control (B3) — gated in the UI by `advancedControlAllowed`.

    /// The single gate the control UI uses: opt-in ON, pump is a Mobi, and the backend advertises
    /// at least one advanced-control capability.
    public var advancedControlAllowed: Bool {
        AppSettings.shared.advancedControlAllowed(isMobi: snapshot.isMobi)
            && capabilities.supportsAnyAdvancedControl
            && !AppSettings.shared.phoneReadOnly   // read-only hides the Pump Control entry entirely
    }

    /// True only while the pump is actively connected — the gate every pump-touching action + control
    /// screen uses so nothing that requires the pump is tappable when it isn't there.
    public var pumpReady: Bool { snapshot.connection == .connected }

    private func runControl(_ op: () async throws -> Void) async {
        if childBlocked(.advancedControl) { refresh(); return }
        if readOnlyBlocked("Pump control") { refresh(); return }
        do { try await op(); lastError = nil } catch { lastError = error.localizedDescription }
        refresh()
        // Control actions (suspend/resume, temp basal, modes…) are time-sensitive: push the new state
        // to the remotes immediately rather than waiting on the 15 s throttle.
        forceStatusPush()
    }
    public func suspendDelivery() async { await runControl { try await source.suspendDelivery() } }
    public func resumeDelivery() async { await runControl { try await source.resumeDelivery() } }
    public func setTempBasal(percent: Int, durationMinutes: Int) async {
        await runControl { try await source.setTempBasal(percent: percent, durationMinutes: durationMinutes) }
    }
    public func stopTempBasal() async { await runControl { try await source.stopTempBasal() } }
    public func setMode(bitmap: Int) async { await runControl { try await source.setMode(bitmap: bitmap) } }
    /// Pump user-mode toggles. The **command** bitmap (wire contract, see PumpX2
    /// `SetModesRequest.ModeCommand`) is `sleepOn=1, sleepOff=2, exerciseOn=3, exerciseOff=4` —
    /// distinct from the *reported* state `snapshot.controlIQMode` (0=normal, 1=sleep, 2=exercise).
    /// Mobi-only + Control-IQ-must-be-on; gated in the UI by `advancedControlAllowed`.
    public func setSleepMode(_ on: Bool) async { await setMode(bitmap: on ? 1 : 2) }
    public func setExerciseMode(_ on: Bool) async { await setMode(bitmap: on ? 3 : 4) }
    /// Return to normal by clearing whichever special mode is currently active.
    public func setNormalMode() async {
        switch snapshot.controlIQMode {
        case 1: await setSleepMode(false)
        case 2: await setExerciseMode(false)
        default: break
        }
    }
    /// Whether pump mode-switching is currently possible (advanced control on, Mobi, connected).
    public var canControlModes: Bool { advancedControlAllowed && capabilities.supportsModes && pumpReady }
    /// Apply an activity/sleep mode toggle (used by the Shortcuts automation via `ModeAutomation`).
    func applyMode(_ mode: ModeAutomation.Mode, on: Bool) async {
        switch mode {
        case .exercise: await setExerciseMode(on)
        case .sleep: await setSleepMode(on)
        }
    }
    public func playFindMyPump() async { await runControl { try await source.playFindMyPump() } }
    /// Read the G6 transmitter ID from the pump (CGM-failover auto-fill). nil if unavailable.
    public func readG6TransmitterId() async -> String? { await source.readG6TransmitterId() }

    // MARK: Mobi workflows (A4)
    public func startG6Session(transmitterId: String, sensorCode: Int) async {
        await runControl { try await source.startG6Session(transmitterId: transmitterId, sensorCode: sensorCode) }
    }
    public func startG7Session(pairingCode: Int) async { await runControl { try await source.startG7Session(pairingCode: pairingCode) } }
    public func setSensorType(_ typeId: Int) async { await runControl { try await source.setSensorType(typeId) } }
    public func stopCgmSession() async { await runControl { try await source.stopCgmSession() } }
    public func refreshCgmSession() async { await source.refreshCgmSession(); refresh() }
    public func enterChangeCartridgeMode() async { await runControl { try await source.enterChangeCartridgeMode() } }
    public func exitChangeCartridgeMode() async { await runControl { try await source.exitChangeCartridgeMode() } }
    public func enterFillTubingMode() async { await runControl { try await source.enterFillTubingMode() } }
    public func exitFillTubingMode() async { await runControl { try await source.exitFillTubingMode() } }
    public func fillCannula(milliunits: Int) async { await runControl { try await source.fillCannula(milliunits: milliunits) } }
    public func refreshLoadStatus() async { await source.refreshLoadStatus(); refresh() }
    public func setMaxBolus(units: Double) async { await runControl { try await source.setMaxBolus(units: units) } }
    public func setMaxBasal(unitsPerHour: Double) async { await runControl { try await source.setMaxBasal(unitsPerHour: unitsPerHour) } }
    public func syncTimeToNow() async { await runControl { try await source.syncTimeToNow() } }

    private var timeSyncInFlight = false
    private static let lastTimeSyncKey = "lastPumpTimeSyncEpoch"
    /// Auto-sync the pump clock to the phone (opt-in via `autoSyncPumpTime`, default on). Runs at most
    /// once a day on the refresh cadence, and immediately when `force` (a clock/time-zone change).
    /// No-op unless a time-sync-capable pump is connected and idle; best-effort (retries next cycle).
    func maybeAutoSyncPumpTime(force: Bool = false) {
        guard AppSettings.shared.autoSyncPumpTime, capabilities.supportsTimeSync else { return }
        guard snapshot.connection == .connected, !timeSyncInFlight else { return }
        let lastEpoch = UserDefaults.standard.double(forKey: Self.lastTimeSyncKey)
        let due = force || lastEpoch == 0
            || Date().timeIntervalSince1970 - lastEpoch > 24 * 60 * 60
        guard due else { return }
        timeSyncInFlight = true
        Task { @MainActor in
            defer { timeSyncInFlight = false }
            await runControl { try await source.syncTimeToNow() }
            if lastError == nil { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastTimeSyncKey) }
        }
    }
    /// Whether clearing active notifications is required before entering cartridge mode (controlX2
    /// precondition). Exposed for the wizard's guard.
    public var hasActiveNotifications: Bool { !activeNotifications.isEmpty }

    // MARK: Config wizards (A4 continued)
    public func setControlIQ(enabled: Bool, weightLbs: Int, totalDailyInsulinUnits: Int) async {
        await runControl { try await source.setControlIQ(enabled: enabled, weightLbs: weightLbs, totalDailyInsulinUnits: totalDailyInsulinUnits) }
    }
    public func refreshControlIQSettings() async { await source.refreshControlIQSettings(); refresh() }
    public func refreshProfiles() async { await source.refreshProfiles(); refresh() }
    public func setActiveProfile(idpId: Int) async { await runControl { try await source.setActiveProfile(idpId: idpId) } }
    public func renameProfile(idpId: Int, name: String) async { await runControl { try await source.renameProfile(idpId: idpId, name: name) } }
    public func deleteProfile(idpId: Int) async { await runControl { try await source.deleteProfile(idpId: idpId) } }
    public func createProfile(name: String, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int, insulinDurationMinutes: Int) async {
        await runControl { try await source.createProfile(name: name, basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf, targetBg: targetBg, insulinDurationMinutes: insulinDurationMinutes) }
    }
    public func refreshProfileSegments(idpId: Int) async { await source.refreshProfileSegments(idpId: idpId); refresh() }
    public func addProfileSegment(idpId: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async {
        await runControl { try await source.addProfileSegment(idpId: idpId, startTimeMinutes: startTimeMinutes, basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf, targetBg: targetBg) }
    }
    public func modifyProfileSegment(idpId: Int, segmentIndex: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async {
        await runControl { try await source.modifyProfileSegment(idpId: idpId, segmentIndex: segmentIndex, startTimeMinutes: startTimeMinutes, basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf, targetBg: targetBg) }
    }
    public func deleteProfileSegment(idpId: Int, segmentIndex: Int) async { await runControl { try await source.deleteProfileSegment(idpId: idpId, segmentIndex: segmentIndex) } }
    // MARK: Backup / reconfigure

    /// Read the pump's therapy settings for a backup. Works on **t:slim X2 and Mobi** (all reads are
    /// `SupportedDevices.ALL`). Reads each profile's segments sequentially.
    func readPumpSettingsForBackup() async -> PumpSettingsBackup {
        await refreshProfiles()
        var profs: [PumpSettingsBackup.ProfileBackup] = []
        for p in snapshot.profiles {
            await refreshProfileSegments(idpId: p.idpId)
            let segs = snapshot.viewedProfileSegments
                .filter { $0.idpId == p.idpId }
                .sorted { $0.startTimeMinutes < $1.startTimeMinutes }
                .map { PumpSettingsBackup.SegmentBackup(startTimeMinutes: $0.startTimeMinutes,
                        basalRateUnitsPerHour: $0.basalRateUnitsPerHour,
                        carbRatioGramsPerUnit: $0.carbRatioGramsPerUnit, isf: $0.isf, targetBg: $0.targetBg) }
            profs.append(.init(name: p.name, active: p.active,
                               insulinDurationMinutes: p.insulinDurationMinutes, segments: segs))
        }
        await refreshControlIQSettings()
        let s = snapshot
        return PumpSettingsBackup(profiles: profs,
                                  maxBolusUnits: s.maxBolusUnits > 0 ? s.maxBolusUnits : nil,
                                  maxBasalUnitsPerHour: s.maxBasalUnitsPerHour > 0 ? s.maxBasalUnitsPerHour : nil,
                                  controlIQEnabled: s.controlIQEnabled,
                                  controlIQWeightLbs: s.controlIQWeightLbs > 0 ? s.controlIQWeightLbs : nil,
                                  controlIQTotalDailyInsulin: s.controlIQTotalDailyInsulin > 0 ? s.controlIQTotalDailyInsulin : nil)
    }

    /// Whether backed-up pump settings can be auto-applied to the CURRENT pump (Mobi + Advanced control
    /// on + not read-only). On t:slim the caller shows them for manual re-entry instead.
    public var canApplyPumpSettings: Bool { advancedControlAllowed && pumpReady }

    /// Auto-apply backed-up therapy settings to the current pump — **Mobi only**, after the caller's
    /// review + confirmation. **Creates** each profile (with its segments), then sets Control-IQ + max
    /// bolus. Experimental/unvalidated; therapy-defining, so it's fully gated + confirmed upstream.
    /// Returns false (and sets `lastError`) on the first failure.
    func applyPumpSettings(_ p: PumpSettingsBackup) async -> Bool {
        guard advancedControlAllowed else {
            lastError = "Reconfiguring the pump needs a Tandem Mobi with Advanced control enabled."
            return false
        }
        for prof in p.profiles {
            guard let first = prof.segments.first else { continue }
            let before = Set(snapshot.profiles.map(\.idpId))
            await createProfile(name: prof.name, basalRateUnitsPerHour: first.basalRateUnitsPerHour,
                                carbRatioGramsPerUnit: first.carbRatioGramsPerUnit, isf: first.isf,
                                targetBg: first.targetBg,
                                insulinDurationMinutes: prof.insulinDurationMinutes > 0 ? prof.insulinDurationMinutes : 300)
            if lastError != nil { return false }
            await refreshProfiles()
            guard let newId = snapshot.profiles.map(\.idpId).first(where: { !before.contains($0) }) else { continue }
            for seg in prof.segments.dropFirst() {
                await addProfileSegment(idpId: newId, startTimeMinutes: seg.startTimeMinutes,
                                        basalRateUnitsPerHour: seg.basalRateUnitsPerHour,
                                        carbRatioGramsPerUnit: seg.carbRatioGramsPerUnit, isf: seg.isf, targetBg: seg.targetBg)
                if lastError != nil { return false }
            }
        }
        if let mb = p.maxBolusUnits { await setMaxBolus(units: mb); if lastError != nil { return false } }
        if let mbasal = p.maxBasalUnitsPerHour { await setMaxBasal(unitsPerHour: mbasal); if lastError != nil { return false } }
        if let ciq = p.controlIQEnabled {
            await setControlIQ(enabled: ciq, weightLbs: p.controlIQWeightLbs ?? snapshot.controlIQWeightLbs,
                               totalDailyInsulinUnits: p.controlIQTotalDailyInsulin ?? snapshot.controlIQTotalDailyInsulin)
            if lastError != nil { return false }
        }
        return true
    }

    public func setLowInsulinAlert(thresholdUnits: Int) async { await runControl { try await source.setLowInsulinAlert(thresholdUnits: thresholdUnits) } }
    public func setAutoOffAlert(enabled: Bool, durationMinutes: Int) async { await runControl { try await source.setAutoOffAlert(enabled: enabled, durationMinutes: durationMinutes) } }
    public func setSiteChangeReminder(enabled: Bool, days: Int, timeOfDayMinutes: Int) async { await runControl { try await source.setSiteChangeReminder(enabled: enabled, days: days, timeOfDayMinutes: timeOfDayMinutes) } }
    public func setAlertSnooze(enabled: Bool, durationMinutes: Int) async { await runControl { try await source.setAlertSnooze(enabled: enabled, durationMinutes: durationMinutes) } }
    public func setCgmHighLowAlert(alertType: Int, thresholdMgdl: Int, repeatMinutes: Int, enabled: Bool) async { await runControl { try await source.setCgmHighLowAlert(alertType: alertType, thresholdMgdl: thresholdMgdl, repeatMinutes: repeatMinutes, enabled: enabled) } }
    public func setCgmOutOfRangeAlert(enabled: Bool, delayMinutes: Int) async { await runControl { try await source.setCgmOutOfRangeAlert(enabled: enabled, delayMinutes: delayMinutes) } }
    public func setCgmRiseFallAlert(alertType: Int, enabled: Bool, mgdlPerMin: Int) async { await runControl { try await source.setCgmRiseFallAlert(alertType: alertType, enabled: enabled, mgdlPerMin: mgdlPerMin) } }

    // MARK: Remote (watch/Garmin) double-confirmation

    public func presentRemoteBolus(requestId: String, units: Double, enforceChildLock: Bool = true) {
        pendingRemoteBolus = PendingRemoteBolus(requestId: requestId, units: units, enforceChildLock: enforceChildLock)
    }

    /// The phone user's confirmation (second confirm) — delivers and echoes status to the remote.
    public func confirmRemoteBolus() async {
        guard let pending = pendingRemoteBolus else { return }
        pendingRemoteBolus = nil
        if pending.enforceChildLock, childBlocked(.bolus) {
            echo(RemoteCommand(kind: .bolusStatus, requestId: pending.requestId,
                               status: .failed, message: "Locked (child mode)"))
            return
        }
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
    public func remoteDeliver(requestId: String, units: Double, enforceChildLock: Bool = true) async {
        if enforceChildLock, childBlocked(.bolus) {
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: "Locked (child mode)"))
            return
        }
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
        if childBlocked(.bolus) {
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: "Locked (child mode)"))
            return (0, false, "Locked (child mode)")
        }
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

// Predictive-low engine callback (advisory). `ingest` is only ever called on the main actor (from
// refresh), so the delegate fires on main — assumeIsolated publishes synchronously without a cross-actor send.
extension AppModel: GlucoseIntelligenceDelegate {
    nonisolated public func glucoseIntelligence(_ g: GlucoseIntelligence, didPredictLow warning: HypoWarning) {
        let alert = HypoAlert(horizonMinutes: warning.horizonMinutes, probability: warning.probability,
                              projectedLowMgdl: warning.projectedLowMgdl, at: warning.at,
                              nocturnal: warning.nocturnal)
        Task { @MainActor in
            // Learned fatigue layer: rate-limit / quiet-hours / auto-quiet a kind the user keeps dismissing.
            let decision = self.alertIntel.decide(AlertIntelligenceKit.Alert(kind: "predicted_low", severity: 2))
            if case .suppress = decision { return }
            self.hypoWarning = alert
        }
    }
}
