import Foundation
import faBolusCore

/// WR-07 (R2-13): ConnectIQ-free readiness state machine for Garmin outbound sends. The vendored SDK is
/// explicit (ConnectIQ.h:53-58,64-68) that `IQDeviceStatus_Connected` does NOT mean the device's services
/// and characteristics are discovered — the companion app must wait for `deviceCharacteristicsDiscovered:`
/// before it can communicate. This tiny helper encodes just the boolean readiness transitions so they get
/// unit-test coverage in the default (non-GARMIN) target, where the `#if GARMIN` bridge below is NOT
/// compiled. Callers still AND-in their ConnectIQ-typed preconditions (`app != nil`, `!sendInFlight`).
struct GarminMessageReadiness {
    private(set) var isReady = false
    /// Characteristics discovered → the device is ready for communication.
    mutating func characteristicsDiscovered() { isReady = true }
    /// Any non-connected device status clears readiness; a later discovery re-arms it. The `true`
    /// transition is owned solely by `characteristicsDiscovered()`, never by a bare `.connected`.
    mutating func deviceStatusChanged(isConnected: Bool) { if !isConnected { isReady = false } }
    /// Whether a send may proceed with respect to message readiness.
    var canSend: Bool { isReady }
}

#if GARMIN
import ConnectIQ

/// Bridges the Garmin venu3s (Connect IQ) remote to the iPhone host. Receives the watch app's
/// messages via the Connect IQ Mobile SDK, maps them to `RemoteCommand`, and routes them to `AppModel`.
/// Like the Apple Watch, the watch confirms on-device (hold-to-deliver) and the host delivers directly
/// — there is NO second human confirmation on the phone. The host still recomputes carbs→units, runs
/// the divergence guard, and enforces the max-bolus clamp + message signing. Status is echoed back to
/// the watch. Requires the Garmin Connect Mobile app installed + the watch paired to it.
@MainActor
final class GarminRemoteBridge: NSObject {
    /// Custom URL scheme for the SDK's device-selection callback (see Info.plist CFBundleURLTypes).
    static let urlScheme = "fabolusciq"
    /// The two published Garmin apps (garmin/manifest.xml + manifest-official.xml). The developer
    /// panel picks which the phone pairs with (UserDefaults "garminTargetApp": beta|official).
    ///
    /// The BETA id is configurable: a self-compiler who builds their OWN private beta (the Connect IQ
    /// store requires a unique app id per beta listing — see faBolusGarmin/scripts/beta-build.sh) sets
    /// `GARMIN_BETA_APP_ID` in LocalConfig.xcconfig (→ Info.plist `GarminBetaAppID`) to the id that
    /// script prints, so the phone targets their beta app. Falls back to the shared default.
    /// The shared/published beta id (used when no personal beta id was configured).
    static let sharedBetaAppUUID = UUID(uuidString: "A1B2C3D4-E5F6-0011-2233-445566778899")!
    static let betaAppUUID: UUID = {
        if let s = Bundle.main.object(forInfoDictionaryKey: "GarminBetaAppID") as? String,
           let id = UUID(uuidString: s.trimmingCharacters(in: .whitespaces)) { return id }
        return sharedBetaAppUUID
    }()
    static let officialAppUUID = UUID(uuidString: "DED131EC-B69D-4649-3650-153AEF623BE6")!
    /// The currently-targeted app UUID. Read from UserDefaults (not the MainActor AppSettings).
    /// **Default is BETA** — the official store listing is dormant for now, so beta is the live app
    /// (a personal beta id if one was configured, else the shared beta). Official is opt-in only, via
    /// the debug panel.
    static var watchAppUUID: UUID {
        UserDefaults.standard.string(forKey: "garminTargetApp") == "official" ? officialAppUUID : betaAppUUID
    }
    private static let deviceDefaultsKey = "garminSelectedDevice"

    /// 09.6-04 (Part C-4a, D-03.4): weak app-wide reference so `DebugMenuView` can read this bridge's
    /// already-tracked messaging state for `[Garmin CIQ]` diagnostics without threading a new
    /// parameter through `DebugMenuView`'s init (its declared call site in `SettingsView.swift` is
    /// out of this plan's scope, same constraint 09.6-03 documented for the Mac/remote-role side).
    /// Set once, in `init`, mirroring the app's other `.shared` singletons (e.g. `MacPairingCoordinator`).
    static weak var shared: GarminRemoteBridge?

    private weak var model: AppModel?
    private var device: IQDevice?
    private var app: IQApp?

    // Connect IQ's sendMessage is serial + asynchronous: firing another before the last completes
    // backs up a queue, so the watch replays stale status and a bolus's terminal echo gets stuck
    // behind it. We keep at most ONE send in flight, coalesce status pushes (only the latest matters),
    // and never drop command echoes (bolus outcome, etc.) — echoes are sent first.
    private var sendInFlight = false
    // WR-07 (R2-13): message-readiness gate. ConnectIQ `.connected` does NOT mean characteristics are
    // discovered; sending before `deviceCharacteristicsDiscovered:` silently loses messages. Gate pump()
    // on this and drain the queue when discovery lands (single-device bridge, so a scalar is enough).
    private var readiness = GarminMessageReadiness()
    private var pendingStatus: [String: Any]?     // latest coalesced statusRead payload
    private var echoQueue: [[String: Any]] = []   // ordered command echoes; never coalesced/dropped
    // A2 send-watchdog: ConnectIQ's `sendMessage` completion has NO timeout, so a lost/never-fired
    // completion (watch app died, out of range, Garmin Connect dropped it) would leave `sendInFlight`
    // true forever — the `guard !sendInFlight` below then makes every later status push AND every
    // bolus-outcome echo a permanent no-op with no recovery short of an app relaunch. Arm a timer with
    // each send; if the completion doesn't arrive within `sendTimeout`, recover — re-attempt the exact
    // in-flight payload (bounded), else drop + log. `sendGeneration` makes a completion that races the
    // watchdog a no-op so it can't double-drain. Mirrors PumpBLEClient's reconnect watchdog
    // (Timer + invalidate + `MainActor.assumeIsolated`).
    private var sendWatchdog: Timer?
    private var sendGeneration = 0
    private var inFlight: (payload: [String: Any], isEcho: Bool, attempts: Int)?
    private static let sendTimeout: TimeInterval = 8
    private static let maxSendAttempts = 3

    // 09.6-04 (Part C-4a, D-03.4): read-only, additive diagnostics state — no new send path. The
    // last completed send's outcome (mapped from ConnectIQ's `IQSendMessageResult` onto the
    // ConnectIQ-free `GarminDiagnostics.SendOutcome` vocabulary right here, at the one place this
    // file already imports ConnectIQ) and how many times the send-watchdog has fired this session.
    private(set) var lastSendOutcomeForDiagnostics: GarminDiagnostics.SendOutcome = .none
    private(set) var sendWatchdogFireCountForDiagnostics = 0

    init(model: AppModel) {
        self.model = model
        super.init()
        Self.shared = self
        ConnectIQ.sharedInstance().initialize(withUrlScheme: Self.urlScheme, uiOverrideDelegate: nil)
        model.addRemoteEcho { [weak self] cmd in self?.send(cmd) }
        // Proactively push status to the watch when pump data changes (prompt refresh while open).
        model.addStatusListener { [weak self] snap in self?.sendStatus(snap) }
        model.setupGarmin = { [weak self] in self?.selectDevice() }
        // Phone tells the watch when to run wrist eating-sensing (battery: only when wanted).
        model.onWantAccelSensing = { [weak self] on in
            self?.sendRaw(["v": 1, "type": "eating_sense", "on": on])
        }
        // Phase 09.18b (D-07/D-09): phone tells the watch when to read+append ambient HR to its
        // out-of-band envelope (battery: only while the in-app HR-context toggle is on). An out-of-band
        // control dict, NOT a RemoteCommand — carries no dose logic and never enters the signed schema.
        model.onWantHeartRate = { [weak self] on in
            self?.sendRaw(["v": 1, "type": "hr_ctl", "on": on])
        }
        restoreDevice()
    }

    var hasDevice: Bool { device != nil }

    /// 09.6-04: total outstanding messages this bridge is holding (the in-flight send, if any, plus
    /// the queued command echoes plus a pending coalesced status push) — read directly from the
    /// already-tracked queue state, never recomputed or re-derived.
    var queueDepthForDiagnostics: Int {
        echoQueue.count + (pendingStatus == nil ? 0 : 1) + (inFlight == nil ? 0 : 1)
    }

    /// 09.6-04: this bridge's paired device's live ConnectIQ connection status, or `false` when no
    /// device is paired at all (callers should check `hasDevice` first to distinguish "never paired"
    /// from "paired but disconnected").
    var deviceConnectedForDiagnostics: Bool {
        guard let device else { return false }
        return ConnectIQ.sharedInstance().getDeviceStatus(device) == .connected
    }

    /// 09.6-04: the paired device's raw name, if known — redaction happens at `GarminDiagnostics`'s
    /// rendering boundary, never here; this accessor exists only to hand that raw value across.
    var deviceNameForDiagnostics: String? { device?.friendlyName ?? device?.modelName }

    /// Opens Garmin Connect Mobile so the user can pick which paired device runs the remote.
    func selectDevice() {
        model?.garminStatus = "Opening Garmin Connect — pick your venu3s, then return to faBolus…"
        ConnectIQ.sharedInstance().showDeviceSelection()
    }

    /// Handle the SDK's device-selection callback URL (from `.onOpenURL`).
    func handleOpenURL(_ url: URL) {
        let devices = ConnectIQ.sharedInstance().parseDeviceSelectionResponse(from: url) as? [IQDevice]
        guard let first = devices?.first else {
            model?.garminStatus = "Garmin returned no device (callback URL had no devices)."
            return
        }
        UserDefaults.standard.set([first.uuid.uuidString, first.modelName ?? "", first.friendlyName ?? ""],
                                  forKey: Self.deviceDefaultsKey)
        device = first
        registerApp()
        model?.garminStatus = "Garmin remote: \(first.friendlyName ?? first.modelName ?? "device") ✓"
    }

    private func restoreDevice() {
        guard let parts = UserDefaults.standard.array(forKey: Self.deviceDefaultsKey) as? [String],
              parts.count == 3, let uuid = UUID(uuidString: parts[0]) else { return }
        device = IQDevice(id: uuid, modelName: parts[1], friendlyName: parts[2])
        registerApp()
        model?.garminStatus = "Garmin remote: \(parts[2].isEmpty ? parts[1] : parts[2])"
    }

    private func registerApp() {
        guard let device else { return }
        // Sideloaded app: store UUID == app UUID.
        let app = IQApp(uuid: Self.watchAppUUID, store: Self.watchAppUUID, device: device)
        self.app = app
        ConnectIQ.sharedInstance().register(forDeviceEvents: device, delegate: self)
        ConnectIQ.sharedInstance().register(forAppMessages: app, delegate: self)
        // WR-07 already-connected-at-registration edge case (ConnectIQ.h:58): if the device was already
        // connected before we registered, `deviceCharacteristicsDiscovered:` may not re-fire, leaving
        // readiness stuck false. Probe the app's status; a reachable, installed IQAppStatus means the
        // device is communicable → arm readiness and drain. (Fail-safe: nil/not-installed keeps it false.)
        ConnectIQ.sharedInstance().getAppStatus(app) { [weak self] appStatus in
            Task { @MainActor in
                guard let self, appStatus?.isInstalled == true else { return }
                self.readiness.characteristicsDiscovered()
                self.pump()
            }
        }
    }

    /// Enqueue a command for the watch. Status pushes are coalesced (latest wins); everything else
    /// (bolus echoes, etc.) is queued in order and sent first, so a stale backlog can't delay a
    /// bolus's "delivered"/"cancelled" outcome or make the CGM lag behind the phone.
    private func send(_ cmd: RemoteCommand) {
        guard let dict = try? cmd.asDictionary() else { return }
        if cmd.kind == .statusRead {
            pendingStatus = dict
        } else {
            echoQueue.append(dict)
        }
        pump()
    }

    /// Send an out-of-band control dict (e.g. eating_sense) to the watch — queued like an echo so it
    /// respects the single-in-flight discipline. Not a RemoteCommand (no safety-critical schema).
    private func sendRaw(_ dict: [String: Any]) {
        echoQueue.append(dict)
        pump()
    }

    private func pump() {
        // WR-07: also gate on message-readiness — a send before characteristics discovery is silently
        // lost. Enqueue-before-pump means gating here only DEFERS the transmit; discovery drains it.
        guard let app, readiness.canSend, !sendInFlight else { return }
        let next: [String: Any]; let isEcho: Bool; let attempts: Int
        if let f = inFlight {                       // re-attempt of a payload whose completion was lost
            next = f.payload; isEcho = f.isEcho; attempts = f.attempts
        } else if !echoQueue.isEmpty {
            next = echoQueue.removeFirst(); isEcho = true; attempts = 0
        } else if let status = pendingStatus {
            next = status; pendingStatus = nil; isEcho = false; attempts = 0
        } else {
            return
        }
        inFlight = (next, isEcho, attempts)
        sendInFlight = true
        sendGeneration &+= 1
        let gen = sendGeneration
        armSendWatchdog(generation: gen)
        ConnectIQ.sharedInstance().sendMessage(next, to: app, progress: nil) { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.sendGeneration else { return }   // watchdog already superseded this send
                self.sendWatchdog?.invalidate(); self.sendWatchdog = nil
                // 09.6-04: decode ConnectIQ's raw result onto the neutral, ConnectIQ-free
                // GarminDiagnostics.SendOutcome vocabulary right at this boundary — no raw
                // IQSendMessageResult ever crosses into GarminDiagnostics.
                self.lastSendOutcomeForDiagnostics = (result == .success) ? .delivered : .failed
                self.inFlight = nil
                self.sendInFlight = false
                self.pump()   // drain the next queued message (echo first, else the latest status)
            }
        }
    }

    /// Arm (replacing any prior) the send-watchdog for the current in-flight send.
    private func armSendWatchdog(generation gen: Int) {
        sendWatchdog?.invalidate()
        sendWatchdog = Timer.scheduledTimer(withTimeInterval: Self.sendTimeout, repeats: false) { [weak self] _ in
            // Fires on the main run loop (scheduled from the @MainActor pump()), so we're really on the
            // main actor — hop in explicitly, matching PumpBLEClient's watchdog.
            MainActor.assumeIsolated { self?.sendWatchdogFired(generation: gen) }
        }
    }

    /// The ConnectIQ completion never arrived within `sendTimeout`. Recover instead of wedging the queue:
    /// re-attempt the same payload (bounded), else drop it and move on. Bumping `sendGeneration` makes any
    /// late completion for this send a no-op, so it can't double-drain.
    private func sendWatchdogFired(generation gen: Int) {
        guard gen == sendGeneration else { return }   // a completion already advanced us; stale timer
        sendGeneration &+= 1
        sendWatchdog = nil
        sendInFlight = false
        lastSendOutcomeForDiagnostics = .timedOut
        sendWatchdogFireCountForDiagnostics += 1
        if var f = inFlight {
            f.attempts += 1
            inFlight = f.attempts < Self.maxSendAttempts ? f : nil   // bounded re-attempt; else drop
        }
        pump()
    }

    private func handle(_ cmd: RemoteCommand) {
        guard let model else { return }
        // Group B (P11): refuse a delivery-authorizing command that arrived too long after it was composed —
        // a bolus applied minutes late is a double-dose hazard. Only insulin-INCREASING kinds are gated
        // (RemoteCommandFreshness); a late cancel is still honored. (A current faBolusGarmin remote stamps
        // `sentAt` on these kinds, so freshness IS enforced; a legacy Garmin app that omits the stamp is
        // not gated — the check is additive / backward-compatible.)
        if RemoteCommandFreshness.isStale(cmd) {
            send(RemoteCommand(kind: .bolusStatus, requestId: cmd.requestId,
                               status: .failed, message: RemoteCommandFreshness.rejectionMessage))
            return
        }
        switch cmd.kind {
        case .bolusRequest:
            // The watch already confirmed via hold-to-deliver — deliver directly, no phone
            // dialog. The pump still enforces max + signing. Blocked when Garmin is read-only.
            guard !AppSettings.shared.remotesReadOnly else {
                send(RemoteCommand(kind: .bolusStatus, requestId: cmd.requestId, status: .failed, message: "Read-only mode"))
                return
            }
            // Units mode sends `units`; carbs mode sends `carbsGrams` (+ bgMgdl + the Garmin's own
            // estimate). The host recomputes carbs→units, runs the divergence guard, records carbs.
            guard cmd.units != nil || (cmd.carbsGrams ?? 0) > 0 else { return }
            // C2 §2.3: forward the entered bolus passcode (if any) so the host verifies it against the
            // salted hash. When a passcode is required and this is absent/wrong, `remoteDeliver` denies and
            // echoes `.failed` — the watch never verifies or stores it.
            Task { await model.remoteDeliver(requestId: cmd.requestId, units: cmd.units,
                                             carbsGrams: cmd.carbsGrams, bgMgdl: cmd.bgMgdl.map(Int.init),
                                             remoteEstimate: cmd.remoteEstimateUnits, passcode: cmd.bolusPasscode,
                                             includeStaleBG: cmd.includeStaleBG ?? false,
                                             from: .garmin, peerId: "garmin") }
        case .cancelBolus:
            // Just request the cancel; the in-flight delivery loop echoes the single final
            // status (cancelled · partial, or delivered if it finished first). No echo here, or
            // the watch would flip cancelled → delivered.
            Task { await model.cancelBolus(from: .garmin, peerId: "garmin") }
        case .dismissAlert:
            if let id = cmd.alertId, let k = cmd.alertKind {
                Task { await model.dismissAlert(id: id, kind: k, from: .garmin, peerId: "garmin"); send(model.statusCommand(includeHistory: true)) }
            }
        case .statusRead:
            if cmd.forceGlucose == true {
                Task { await model.refreshGlucoseNow(); self.send(model.statusCommand(includeHistory: true)) }
            } else {
                send(model.statusCommand(includeHistory: true))
            }
        default: break
        }
    }

    /// Send the full status (reply or proactive push). History included for the watch plot.
    private func sendStatus(_ s: PumpSnapshot) {
        if let model { send(model.statusCommand(includeHistory: true)) }
    }
}

// Connect IQ delegate callbacks (Obj-C, nonisolated) — hop onto the main actor.
extension GarminRemoteBridge: IQAppMessageDelegate, IQDeviceEventDelegate {
    nonisolated func receivedMessage(_ message: Any!, from app: IQApp!) {
        guard let dict = message as? [String: Any] else { return }
        // Eating-detection IMU windows ride an out-of-band envelope (not the safety-critical
        // RemoteCommand schema) — route them to phone-side inference before RemoteCommand parsing.
        if dict["type"] as? String == "imu_window" {
            let raw = (dict["data"] as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue } ?? []
            Task { @MainActor in self.model?.ingestGarminIMUWindow(rawWindow: raw) }
            return
        }
        // Phase 09.18b (D-07): ambient heart-rate rides its OWN out-of-band envelope (chart context
        // only), routed to the display-only HR store BEFORE RemoteCommand parsing — HR NEVER enters the
        // signed command schema (keeps HeartRateSchemaAbsenceGuardTests + check-schema-drift.sh green).
        // Fail-safe: a malformed/oversized envelope parses to nil → the HR row simply hides (never a
        // dose input, T-09.18b-05).
        if dict["type"] as? String == "hr_window" {
            if let sample = Self.newestHeartRate(in: dict) {
                Task { @MainActor in self.model?.ingestGarminHeartRate(bpm: sample.bpm, at: sample.date) }
            }
            return
        }
        guard let cmd = try? RemoteCommand.fromValidated(dict) else { return }   // audit A-07
        Task { @MainActor in self.handle(cmd) }
    }
    nonisolated func deviceStatusChanged(_ device: IQDevice!, status: IQDeviceStatus) {
        // WR-07: clear readiness whenever the device is not connected; the `true` transition is owned
        // solely by deviceCharacteristicsDiscovered (a bare `.connected` is NOT message-ready). Hop to
        // the main actor like the other ConnectIQ callbacks.
        Task { @MainActor in self.readiness.deviceStatusChanged(isConnected: status == .connected) }
    }

    /// WR-07: characteristics discovered → messaging is ready. Set readiness and drain anything that
    /// queued during the post-connect / pre-discovery window (echoes, coalesced status).
    nonisolated func deviceCharacteristicsDiscovered(_ device: IQDevice!) {
        Task { @MainActor in
            self.readiness.characteristicsDiscovered()
            self.pump()
        }
    }

    /// Strict, fail-safe parse of the out-of-band `hr_window` envelope (T-09.18b-05). Pulls the newest
    /// `[bpm, epoch]` pair from `samples` (mirroring the `imu_window` `data`-array idiom), or a single
    /// `bpm`(+`ts`) fallback. Rejects non-finite / non-physiologic bpm (≤0 or ≥300) → nil, so a garbled
    /// or spoofed envelope hides the HR row rather than surfacing a bad number. Pure/`nonisolated` so it
    /// runs inside the nonisolated ConnectIQ callback without hopping actors; it never touches the
    /// signed `RemoteCommand` path.
    nonisolated static func newestHeartRate(in dict: [String: Any]) -> (bpm: Double, date: Date)? {
        func valid(_ bpm: Double) -> Bool { bpm.isFinite && bpm > 0 && bpm < 300 }
        if let pairs = dict["samples"] as? [[Any]] {
            var best: (bpm: Double, epoch: Double)?
            for pair in pairs where pair.count >= 2 {
                guard let bpm = (pair[0] as? NSNumber)?.doubleValue,
                      let epoch = (pair[1] as? NSNumber)?.doubleValue, valid(bpm) else { continue }
                if best == nil || epoch > best!.epoch { best = (bpm, epoch) }
            }
            if let b = best { return (b.bpm, Date(timeIntervalSince1970: b.epoch)) }
        }
        if let bpm = (dict["bpm"] as? NSNumber)?.doubleValue, valid(bpm) {
            let epoch = (dict["ts"] as? NSNumber)?.doubleValue
            return (bpm, epoch.map { Date(timeIntervalSince1970: $0) } ?? Date())
        }
        return nil
    }
}

#else

/// Stub used when the app is built **without** the Garmin Connect IQ SDK (the `GARMIN` compile flag is
/// off because the SDK wasn't present at build time — see `scripts/generate-project.sh`). The Garmin
/// remote is unavailable; the Remotes & devices screen shows why. Keeps the same surface `App` uses
/// (`init(model:)` + `handleOpenURL(_:)`) so nothing else changes.
@MainActor
final class GarminRemoteBridge {
    /// 09.6-04: mirrors the `#if GARMIN` variant's `.shared` + diagnostics read surface so
    /// `GarminDiagnostics`/`DebugMenuView` compile and behave sensibly (unreachable empty state)
    /// in a build without the Connect IQ SDK.
    static weak var shared: GarminRemoteBridge?

    init(model: AppModel) { model.garminStatus = nil; Self.shared = self }
    func handleOpenURL(_ url: URL) {}

    var hasDevice: Bool { false }
    var queueDepthForDiagnostics: Int { 0 }
    var lastSendOutcomeForDiagnostics: GarminDiagnostics.SendOutcome { .none }
    var sendWatchdogFireCountForDiagnostics: Int { 0 }
    var deviceConnectedForDiagnostics: Bool { false }
    var deviceNameForDiagnostics: String? { nil }
}

#endif
