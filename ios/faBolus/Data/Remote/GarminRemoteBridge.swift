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

/// CR (R2-12): ConnectIQ-free classification of a Garmin outbound `sendMessage` result, so the durable
/// terminal-echo outbox policy gets unit coverage in the default (non-GARMIN) target — mirroring
/// `GarminMessageReadiness` above, which lives OUTSIDE `#if GARMIN` for the same reason.
///
/// A terminal command echo (bolus outcome, etc.; `isEcho == true`) must survive an EXPLICIT send-failure:
/// it is re-enqueued to the FRONT of the durable `echoQueue` (WR-07's readiness drain replays it on
/// reconnect/discovery) rather than dropped. Dropping a terminal `bolusStatus` echo permanently loses the
/// outcome and leaves the watch stuck "delivering…" forever (it makes the watch-side R2-02 stuck-terminal
/// permanent). A coalesced status snapshot (`isEcho == false`) MAY still be dropped on failure — a newer
/// status supersedes it, so it is coalescing-safe.
enum GarminSendDisposition: Equatable {
    /// Transport acknowledged the send (ConnectIQ `.success`) — clear it from the outbox.
    case ack
    /// Explicit failure of a durable echo — re-enqueue to the front of `echoQueue` (never drop).
    case reenqueueFront
    /// Explicit failure of a coalescing-safe status snapshot — safe to drop.
    case drop
    /// I-M3: an UNRECOVERABLE echo failure (`GarminSendResult.permanentFailure` — AppNotFound/
    /// UnsupportedType/InsufficientMemory, IQConstants.h:34-48). Retrying it forever busy-loops for
    /// nothing, so it is surfaced (to `GarminDiagnostics`, by the caller) and dropped from the
    /// in-memory outbox — UNLIKE `.reenqueueFront`, this is NOT retried. The durable
    /// `RemoteBolusLedger` launch re-seed (`seedTerminalEchoesFromLedger`) remains the terminal-outcome
    /// backstop, so a permanently-failed echo is not lost forever, only not retried THIS session.
    case surfaceAndDrop
}

/// success ⇒ `.ack`; failure of an echo ⇒ `.reenqueueFront`; failure of a non-echo status ⇒ `.drop`.
/// Both the `#if GARMIN` `sendMessage` completion AND the send-watchdog's `maxSendAttempts`-exhaustion
/// path route their keep/drop decision through this one helper.
///
/// Kept UNCHANGED (never widened/replaced) alongside the granular `GarminSendResult` overload below —
/// every existing call site and test that only has a boolean success/failure signal (the send-watchdog's
/// timeout exhaustion has no permanent/transient signal of its own; see `sendWatchdogFired`) still routes
/// through this exact seam.
func garminSendDisposition(success: Bool, isEcho: Bool) -> GarminSendDisposition {
    if success { return .ack }
    return isEcho ? .reenqueueFront : .drop
}

/// I-M3: ConnectIQ-free classification of a Garmin outbound `sendMessage` result with PERMANENT-vs-
/// TRANSIENT granularity — mirrors the `IQConstants.h` distinction (`AppNotFound`/`UnsupportedType`/
/// `InsufficientMemory` are permanent; every other failure, including ones we can't individually
/// characterize, is treated as transient) without any raw `IQSendMessageResult` crossing this boundary.
enum GarminSendResult: Equatable {
    case success
    case transientFailure
    case permanentFailure
}

/// success ⇒ `.ack`; TRANSIENT failure of an echo ⇒ `.reenqueueFront` (UNCHANGED never-drop invariant —
/// identical to the boolean seam above); PERMANENT failure of an echo ⇒ `.surfaceAndDrop` (a NEW
/// disposition — an unrecoverable error retried forever helps nobody, so surface it once and drop from
/// the in-memory outbox; the durable ledger re-seed is the backstop); ANY non-echo (coalescing-safe)
/// status failure ⇒ `.drop`, regardless of permanent/transient — a newer status supersedes it either way.
///
/// A SEPARATE overload from `garminSendDisposition(success:isEcho:)` above (different parameter label,
/// so both coexist without ambiguity) — the `#if GARMIN` `sendMessage` completion routes through THIS
/// one (it has the real `IQSendMessageResult` to classify); the send-watchdog's timeout-exhaustion path
/// has no such signal and stays on the plain boolean seam (a timeout is always treated as transient —
/// the safe default when the actual outcome is unknown).
func garminSendDisposition(result: GarminSendResult, isEcho: Bool) -> GarminSendDisposition {
    switch result {
    case .success: return .ack
    case .transientFailure: return isEcho ? .reenqueueFront : .drop
    case .permanentFailure: return isEcho ? .surfaceAndDrop : .drop
    }
}

/// I-M2: ConnectIQ-free classification of a `getAppStatus` result onto `GarminDiagnostics.AppInstallState`
/// — lives OUTSIDE `#if GARMIN` (mirrors `garminSendDisposition`/`GarminMessageReadiness`) so it compiles
/// and is unit-testable in the default (non-GARMIN) target; no `IQAppStatus` type crosses this boundary,
/// only the one `Bool?` bit the `#if GARMIN` completion already reduces it to (`nil` when the completion
/// itself never resolved a status — distinct from an explicit `false`, so a transient probe failure is
/// never confused with a genuinely-absent/mismatched watch app).
func garminClassifyAppInstallState(installed: Bool?) -> GarminDiagnostics.AppInstallState {
    guard let installed else { return .unknown }
    return installed ? .installed : .notInstalled
}

/// R2-12 (cross-restart echo persistence): a terminal outcome to re-enqueue as a `bolusStatus` echo on
/// launch. Pure/ConnectIQ-free (mirrors `garminSendDisposition`/`GarminMessageReadiness`) so the seeding
/// decision gets unit coverage in the default (non-GARMIN) target.
struct GarminEchoSeed: Equatable { let requestId: String; let status: String; let deliveredUnits: Double?; let message: String? }

/// R2-12: which of the ledger's durable terminal outcomes to re-enqueue as echoes on launch — those NOT
/// already confirmed-sent to the watch. `alreadyEchoed` is the durable set of requestIds whose echo was
/// previously acked. Pure/ConnectIQ-free (unit-testable in the default target).
func garminEchoesToSeed(terminalOutcomes: [(requestId: String, status: String, message: String?, deliveredUnits: Double?)],
                        alreadyEchoed: Set<String>) -> [GarminEchoSeed] {
    terminalOutcomes.filter { !alreadyEchoed.contains($0.requestId) }
                    .map { GarminEchoSeed(requestId: $0.requestId, status: $0.status, deliveredUnits: $0.deliveredUnits, message: $0.message) }
}

// MARK: - CX-G-08 (14-09) — ConnectIQ-free dismiss-ack decision + handler
//
// Lives OUTSIDE `#if GARMIN`, mirroring `garminEchoesToSeed`/`GarminMessageReadiness` above, precisely
// so `GarminDismissAckBridgeTests` exercises the REAL branching logic in the default (non-GARMIN) test
// target — no ConnectIQ import, no live `AppModel`/`GarminDismissReceiptStore` singleton required.

/// T-14-30/H2/HIGH-A — whether an incoming dismiss command should be answered by REPLAYING a stored
/// receipt rather than re-running the dismiss against the pump. A retry REUSES the same `requestId`, so
/// once CC-08 clears the alert (it drops out of `activeNotifications`), a same-requestId retry would hit
/// `AppModel.dismissAlert`'s missing-alert guard with no way to re-derive the outcome — this check runs
/// BEFORE that guard is ever reached.
func garminDismissShouldReplay(receipt: GarminDismissReceipt?, requestId: String) -> Bool {
    receipt?.requestId == requestId
}

/// Checkpoint #2 (absence-only) / checkpoint #4 (typed-outcome) — the ack decision for a FRESH
/// (non-replayed) dismiss attempt. `.authenticatedCleared` is the ONLY outcome that yields an ack; every
/// other outcome (rejected / noResponse / localSnoozeOnly / notAuthenticated) sends nothing — the
/// watch's fail-closed default (stay visible, keep retrying) is exactly right (T-14-25/T-14-28).
enum GarminDismissAckDecision: Equatable {
    case ack(requestId: String, alertId: Int, alertKind: Int)
    case noAck
}
func garminDismissAckDecision(outcome: DismissOutcome, requestId: String, alertId: Int,
                              alertKind: Int) -> GarminDismissAckDecision {
    guard outcome == .authenticatedCleared else { return .noAck }
    return .ack(requestId: requestId, alertId: alertId, alertKind: alertKind)
}

/// The ConnectIQ-free CORE of the dismiss-handling flow: given the incoming command's identity, a
/// receipt lookup, an async dismiss-performer, and injectable sinks for "persist a receipt" / "send a
/// command" / "send the statusRead backstop", runs the full replay-or-dismiss branch exactly once.
///
/// - On a receipt replay: sends the stored ack, then the statusRead backstop. Never re-runs the dismiss
///   (H2/HIGH-A — the alert may already be gone from `activeNotifications`).
/// - On a fresh dismiss returning `.authenticatedCleared`: persists the receipt SYNCHRONOUSLY (via
///   `persistReceipt`, before `sendAck` is called — H2's ordering requirement) then sends the ack, then
///   the statusRead backstop.
/// - On every other outcome: sends NO ack, only the statusRead backstop (unconditional, mirrors the
///   pre-14-09 behavior so a capability-absent/false watch's 14-08 fallback still gets a fresh list).
@MainActor
func garminHandleDismissAlert(
    requestId: String, alertId: Int, alertKind: Int,
    lookupReceipt: (String) -> GarminDismissReceipt?,
    performDismiss: () async -> DismissOutcome,
    persistReceipt: (String, Int, Int) -> Void,
    sendAck: (String, Int, Int) -> Void,
    sendStatusBackstop: () -> Void
) async {
    if let receipt = lookupReceipt(requestId), garminDismissShouldReplay(receipt: receipt, requestId: requestId) {
        sendAck(receipt.requestId, receipt.alertId, receipt.alertKind)
        sendStatusBackstop()
        return
    }
    let outcome = await performDismiss()
    switch garminDismissAckDecision(outcome: outcome, requestId: requestId, alertId: alertId, alertKind: alertKind) {
    case .ack(let rid, let aid, let akind):
        persistReceipt(rid, aid, akind)   // BEFORE sendAck — H2 ordering
        sendAck(rid, aid, akind)
    case .noAck:
        break
    }
    sendStatusBackstop()
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
    // R2-12 (cross-restart echo persistence): the in-memory `echoQueue` above replays terminal echoes
    // until transport-acked WITHIN a process. `seedTerminalEchoesFromLedger()` (called at launch) closes
    // the across-restart gap by re-seeding it from the durable RemoteBolusLedger's terminal Garmin
    // outcomes that were NOT already confirmed-sent (tracked in `alreadyEchoedKey`). `didSeedTerminalEchoes`
    // makes the seed idempotent per launch.
    private var didSeedTerminalEchoes = false
    // R2-12: durable set of requestIds whose terminal echo was already confirmed-sent to the watch, so the
    // launch-time re-seed does not re-echo an outcome the watch already received. Bounded (~256, oldest
    // dropped) in UserDefaults to avoid unbounded growth.
    private static let alreadyEchoedKey = "garminEchoedRequestIds"
    private static let alreadyEchoedCap = 256
    // CX-G-08 (14-09, T-14-32/MEDIUM-F): the durable dismiss-ack receipt outbox — a SEPARATE lane, its
    // own UserDefaults key ("garminDismissReceipts"), never touching `alreadyEchoedKey` above. A
    // dismissAck echo can therefore never evict (or be evicted by) a bolus outcome's 256-entry set.
    private static let dismissReceiptStore = GarminDismissReceiptStore.shared
    private var didSeedDismissReceipts = false
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
    // R2-12: after an EXPLICIT send-failure we deliberately do NOT re-pump synchronously (re-sending the
    // just-failed payload immediately is a busy tight-loop). A single bounded-backoff timer schedules one
    // deferred pump() so a transient failure still recovers even without a reconnect/discovery event; the
    // WR-07 readiness gate in pump() still defers the actual transmit until the device is message-ready.
    private var sendBackoff: Timer?
    private static let sendBackoffInterval: TimeInterval = 4

    // 09.6-04 (Part C-4a, D-03.4): read-only, additive diagnostics state — no new send path. The
    // last completed send's outcome (mapped from ConnectIQ's `IQSendMessageResult` onto the
    // ConnectIQ-free `GarminDiagnostics.SendOutcome` vocabulary right here, at the one place this
    // file already imports ConnectIQ) and how many times the send-watchdog has fired this session.
    private(set) var lastSendOutcomeForDiagnostics: GarminDiagnostics.SendOutcome = .none
    private(set) var sendWatchdogFireCountForDiagnostics = 0
    // I-M2: the watch-app install/version state from the most recent `getAppStatus` probe — read-only,
    // additive diagnostics state mirroring `lastSendOutcomeForDiagnostics` above. Defaults to
    // `.installed` (matches `GarminDiagnostics.BridgeState`'s own default) so a bridge that hasn't yet
    // completed its first `registerApp()` probe doesn't misreport a not-installed state it hasn't
    // actually observed.
    private(set) var appInstallStateForDiagnostics: GarminDiagnostics.AppInstallState = .installed

    init(model: AppModel) {
        self.model = model
        super.init()
        Self.shared = self
        // WR-08 (R2-14): opt into CoreBluetooth state restoration (ConnectIQ.h:133-135) so iOS can
        // relaunch us in the background on BLE activity — paired with early (launch-time) construction so
        // a background relaunch has a live bridge to answer a remote request. `restoreDevice()` below is
        // the intended reconnect-on-launch behavior (the SDK does not handle willRestoreState itself).
        ConnectIQ.sharedInstance().initialize(withUrlScheme: Self.urlScheme, uiOverrideDelegate: nil,
                                              stateRestorationIdentifier: "fabolus.connectiq")
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

    // I-M1: unregister on deallocation — mirrors `registerApp()`'s own unregister-before-register at
    // the top (below). Without this, a bridge instance that's replaced/deallocated (unlikely in normal
    // app life — `Self.shared`/`AppModel` hold it for the process lifetime — but real in tests/previews
    // that construct a fresh instance) would leave its delegate registered against the SDK's singleton
    // forever, a stale listener that never gets cleaned up.
    deinit {
        ConnectIQ.sharedInstance().unregisterForAllDeviceEvents(self)
        ConnectIQ.sharedInstance().unregisterForAllAppMessages(self)
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
        // I-M1: unregister any PRIOR registration for `self` BEFORE re-registering. `registerApp()` is
        // called from BOTH `restoreDevice()` (launch) and `handleOpenURL()` (re-select) — with no
        // unregister, a repeated call STACKS listeners (ConnectIQ.h:220-227/:264-272: "a device/app may
        // have multiple listeners if this method is called more than once"), causing duplicate
        // `handle(cmd)` (status flip-flop, duplicate cancel/dismiss) and a stale registration against
        // the PREVIOUS device on a device switch. `unregisterForAll…` is safe even on the very first
        // call — a no-op when nothing was registered yet.
        ConnectIQ.sharedInstance().unregisterForAllDeviceEvents(self)
        ConnectIQ.sharedInstance().unregisterForAllAppMessages(self)
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
            // Read the one Sendable bit (installed?) HERE, in the nonisolated completion, so only a
            // `Bool?` crosses to the main actor — capturing the non-Sendable `IQAppStatus` into the
            // @MainActor Task trips Swift 6 "Sending 'appStatus' risks causing data races". `nil` (the
            // completion itself never resolved a status) is preserved as its OWN tri-state bit — I-M2's
            // `garminClassifyAppInstallState` distinguishes it from an explicit `installed == false`.
            let installed: Bool? = appStatus?.isInstalled
            Task { @MainActor in
                guard let self else { return }
                let state = garminClassifyAppInstallState(installed: installed)
                self.appInstallStateForDiagnostics = state
                switch state {
                case .installed:
                    self.readiness.characteristicsDiscovered()
                    self.pump()
                case .notInstalled:
                    // I-M2: a VISIBLE, actionable state — corrects the "✓" `restoreDevice()`/
                    // `handleOpenURL()` already set SYNCHRONOUSLY (before this async probe resolves),
                    // instead of leaving it stand while readiness silently never arms.
                    // `openConnectIQAppStore()` is exposed below for a future UI "Install" action; never
                    // auto-invoked here — launching Garmin Connect Mobile unprompted on every cold
                    // start (registerApp() runs from restoreDevice() at EVERY launch) would be its own
                    // unwanted surprise, not a fix.
                    self.model?.garminStatus = state.statusText
                case .unknown:
                    break   // fail-safe: no status change, readiness stays false — matches prior behavior
                }
            }
        }
    }

    /// I-M2: launches Garmin Connect Mobile's Connect IQ Store page for the paired watch app — the
    /// store-link a not-installed/wrong-app-id `garminStatus` should OFFER. Exposed for a future UI
    /// action (out of this plan's file scope); a no-op if no app has been resolved yet.
    func openConnectIQAppStore() {
        guard let app else { return }
        ConnectIQ.sharedInstance().showConnectIQStoreForApp(app)
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

    /// R2-12: seed the durable terminal-echo outbox from the ledger at launch, so a bolus outcome recorded
    /// in the durable RemoteBolusLedger but never echoed to the watch (app killed/relaunched before the echo
    /// was transport-acked) is replayed once the watch is message-ready. Filters out outcomes already
    /// confirmed-sent (durable `alreadyEchoedKey` set). Idempotent per launch (`didSeedTerminalEchoes`).
    func seedTerminalEchoesFromLedger() {
        guard !didSeedTerminalEchoes, let model else { return }
        didSeedTerminalEchoes = true
        let outcomes = model.garminTerminalOutcomes()
        let seeds = garminEchoesToSeed(terminalOutcomes: outcomes, alreadyEchoed: Self.alreadyEchoedRequestIds())
        for seed in seeds {
            let cmd = RemoteCommand(kind: .bolusStatus, requestId: seed.requestId,
                                    status: RemoteCommand.Status(rawValue: seed.status),
                                    deliveredUnits: seed.deliveredUnits, message: seed.message)
            if let dict = try? cmd.asDictionary() { echoQueue.append(dict) }
        }
        pump()   // WR-07 readiness gate defers the actual transmit until the device is message-ready
    }

    /// CX-G-08 (14-09, T-14-30) — the launch-time analogue of `seedTerminalEchoesFromLedger()` for the
    /// dismiss-ack lane: any receipt persisted (an authenticated pump clear proven) but never actually
    /// sent (the phone died in the gap between persist and transport-confirmed send) is resent proactively
    /// — the watch's own bounded retry would eventually re-request it, but this closes the gap without
    /// waiting on that. Idempotent per launch (`didSeedDismissReceipts`). Never touches the bolus
    /// `alreadyEchoedKey` lane (T-14-32).
    func seedUnsentDismissAcksFromReceiptStore() {
        guard !didSeedDismissReceipts, let model else { return }
        didSeedDismissReceipts = true
        for receipt in Self.dismissReceiptStore.unackedReceipts() {
            send(model.dismissAckCommand(requestId: receipt.requestId, alertId: receipt.alertId, alertKind: receipt.alertKind))
        }
        pump()   // WR-07 readiness gate defers the actual transmit until the device is message-ready
    }

    // R2-12: durable already-echoed requestId set (UserDefaults, bounded).
    private static func alreadyEchoedRequestIds() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: alreadyEchoedKey) ?? [])
    }
    private static func markAlreadyEchoed(_ requestId: String) {
        var ids = UserDefaults.standard.stringArray(forKey: alreadyEchoedKey) ?? []
        guard !ids.contains(requestId) else { return }
        ids.append(requestId)
        if ids.count > alreadyEchoedCap { ids.removeFirst(ids.count - alreadyEchoedCap) }
        UserDefaults.standard.set(ids, forKey: alreadyEchoedKey)
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
        // I-L2 (optional, low-priority — SDK 1.8.0): mark coalescing-safe status snapshots
        // (`!isEcho`) as transient sends, so a busy/backgrounded watch may coalesce/drop a stale one
        // without holding up delivery of the NEXT (newer) status — a terminal echo (`isEcho == true`)
        // is NEVER marked transient (it must not be silently coalesced away by the transport itself,
        // independent of I-M3's own permanent/transient RESULT classification below, which is a
        // different axis: this `isTransient` flag describes the OUTBOUND send; I-M3 classifies the
        // INBOUND result).
        ConnectIQ.sharedInstance().sendMessage(next, to: app, progress: nil, completion: { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.sendGeneration else { return }   // watchdog already superseded this send
                self.sendWatchdog?.invalidate(); self.sendWatchdog = nil
                // I-M3: classify onto the neutral, ConnectIQ-free GarminSendResult vocabulary right at
                // this boundary — no raw IQSendMessageResult ever crosses into GarminDiagnostics or the
                // disposition helper. Permanent (IQConstants.h:34-48): the device/app itself rejects the
                // message outright — retrying it can never succeed. Everything else (including timeouts/
                // busy/internal errors) is transient — may well succeed on a later attempt.
                let sendResult: GarminSendResult
                switch result {
                case .success: sendResult = .success
                case .failureAppNotFound, .failureUnsupportedType, .failureInsufficientMemory:
                    sendResult = .permanentFailure
                default: sendResult = .transientFailure
                }
                // 09.6-04: decode onto the neutral, ConnectIQ-free GarminDiagnostics.SendOutcome
                // vocabulary right at this boundary — no raw IQSendMessageResult ever crosses into
                // GarminDiagnostics.
                switch sendResult {
                case .success: self.lastSendOutcomeForDiagnostics = .delivered
                case .transientFailure: self.lastSendOutcomeForDiagnostics = .failed
                case .permanentFailure: self.lastSendOutcomeForDiagnostics = .permanentlyFailed
                }
                let isEcho = self.inFlight?.isEcho ?? false
                // R2-12/I-M3: classify the result. A TRANSIENT failure of a terminal command echo must
                // NOT be dropped — durable-park it to the FRONT of echoQueue so WR-07's readiness-gated
                // reconnect/discovery drain replays it. A PERMANENT echo failure is surfaced above
                // (lastSendOutcomeForDiagnostics) and dropped — NOT re-parked (retrying an unrecoverable
                // error forever helps nobody); the durable RemoteBolusLedger re-seed remains the
                // terminal-outcome backstop. A coalesced status snapshot is safe to drop either way.
                switch garminSendDisposition(result: sendResult, isEcho: isEcho) {
                case .reenqueueFront:
                    if let f = self.inFlight { self.echoQueue.insert(f.payload, at: 0) }
                case .ack:
                    // R2-12: a terminal echo was confirmed sent — record its requestId durably so a
                    // launch-time re-seed from the ledger does not re-echo an outcome the watch already got.
                    // CX-G-08 (14-09, T-14-32): a dismissAck echo routes to its OWN durable lane
                    // (GarminDismissReceiptStore, keyed peer+requestId) — NEVER `markAlreadyEchoed`, which
                    // is the bolus-only 256-entry set. Distinguished by the payload's `kind`, mirroring how
                    // `handle()` dispatches inbound commands by kind.
                    if let f = self.inFlight, f.isEcho, let rid = f.payload["requestId"] as? String {
                        if (f.payload["kind"] as? String) == "dismissAck" {
                            Self.dismissReceiptStore.markAcked(peer: "garmin", requestId: rid)
                        } else {
                            Self.markAlreadyEchoed(rid)
                        }
                    }
                case .drop, .surfaceAndDrop:
                    break
                }
                self.inFlight = nil
                self.sendInFlight = false
                if sendResult == .success {
                    self.pump()   // drain the next queued message (echo first, else the latest status)
                } else {
                    // Do NOT synchronously re-pump on an explicit failure — re-sending the just-failed
                    // payload immediately busy-loops. Recovery rides WR-07's readiness-gated reconnect drain
                    // plus a bounded backoff (a permanent failure has nothing left to re-pump for THIS
                    // payload, but the backoff still drains whatever else is queued).
                    self.scheduleBackoffPump()
                }
            }
        }, isTransient: !isEcho)
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
            if f.attempts < Self.maxSendAttempts {
                inFlight = f   // bounded re-attempt
            } else {
                // R2-12/I-M3: attempts exhausted. A watchdog TIMEOUT carries no permanent/transient
                // signal of its own (no IQSendMessageResult was ever received) — stays on the plain
                // boolean seam, always treated as transient (the safe default absent better
                // information), so a terminal echo durable-parks to the FRONT of echoQueue (never
                // dropped) exactly like the completion path's transient case; a coalescing-safe status
                // snapshot is dropped.
                if garminSendDisposition(success: false, isEcho: f.isEcho) == .reenqueueFront {
                    echoQueue.insert(f.payload, at: 0)
                }
                inFlight = nil
            }
        }
        pump()
    }

    /// R2-12: schedule a single bounded-backoff pump() after an explicit send-failure. We do this instead
    /// of re-pumping synchronously so we don't busy-loop re-sending the just-failed payload; a transient
    /// failure still recovers even absent a reconnect/discovery event. Coalesced — one pending backoff is
    /// enough (a reconnect drain or a later send may beat it; both are harmless no-ops). The pump() it fires
    /// still honors the WR-07 readiness gate, so it only transmits when the device is message-ready.
    private func scheduleBackoffPump() {
        guard sendBackoff == nil else { return }
        sendBackoff = Timer.scheduledTimer(withTimeInterval: Self.sendBackoffInterval, repeats: false) { [weak self] _ in
            // Fires on the main run loop (scheduled from the @MainActor completion), so we're really on the
            // main actor — hop in explicitly, matching armSendWatchdog.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sendBackoff = nil
                self.pump()
            }
        }
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
                                             includeStaleBG: cmd.includeStaleBG ?? false, sentAt: cmd.sentAt,
                                             from: .garmin, peerId: "garmin") }
        case .cancelBolus:
            // Just request the cancel; the in-flight delivery loop echoes the single final
            // status (cancelled · partial, or delivered if it finished first). No echo here, or
            // the watch would flip cancelled → delivered.
            Task { await model.cancelBolus(from: .garmin, peerId: "garmin") }
        case .dismissAlert:
            // CX-G-08 (14-09): route through the ConnectIQ-free core handler so the receipt-replay /
            // authenticated-ack decision logic is identical to what GarminDismissAckBridgeTests exercises
            // in the default target — only the closures below (real AppModel call, real
            // GarminDismissReceiptStore, real send()) are GARMIN-specific.
            if let id = cmd.alertId, let k = cmd.alertKind {
                let requestId = cmd.requestId
                Task { [weak self] in
                    guard let self else { return }
                    await garminHandleDismissAlert(
                        requestId: requestId, alertId: id, alertKind: k,
                        lookupReceipt: { rid in Self.dismissReceiptStore.receipt(peer: "garmin", requestId: rid) },
                        performDismiss: { await model.dismissAlert(id: id, kind: k, from: .garmin, peerId: "garmin") },
                        persistReceipt: { rid, aid, akind in
                            Self.dismissReceiptStore.persist(peer: "garmin", requestId: rid, alertId: aid, alertKind: akind)
                        },
                        sendAck: { rid, aid, akind in self.send(model.dismissAckCommand(requestId: rid, alertId: aid, alertKind: akind)) },
                        sendStatusBackstop: { self.send(model.statusCommand(includeHistory: true)) }
                    )
                }
            }
        case .statusRead:
            if cmd.forceGlucose == true {
                Task { await model.refreshGlucoseNow(); self.send(model.statusCommand(includeHistory: true, replyingTo: cmd.requestId)) }
            } else {
                send(model.statusCommand(includeHistory: true, replyingTo: cmd.requestId))
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
    /// I-M2: mirrors the `#if GARMIN` variant's diagnostics surface — no device, no probe, nothing to
    /// report; `.unknown` (never `.installed`, which would misreport readiness this stub never has).
    var appInstallStateForDiagnostics: GarminDiagnostics.AppInstallState { .unknown }
    /// I-M2: no-op mirror of the `#if GARMIN` variant's store-link action — there's no ConnectIQ SDK
    /// (and so no `IQApp`/store page) to open in this build.
    func openConnectIQAppStore() {}
}

#endif
