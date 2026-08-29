import Foundation
import faBolusCore

/// ConnectIQ-free readiness for Garmin outbound sends. The vendored SDK is explicit
/// (ConnectIQ.h:53-58,64-68) that `IQDeviceStatus_Connected` does NOT mean services and
/// characteristics are discovered — wait for `deviceCharacteristicsDiscovered:` before
/// communicating. Encodes just the boolean transitions so they get unit coverage in the
/// default (non-GARMIN) target, where the `#if GARMIN` bridge is not compiled. Callers still
/// AND-in ConnectIQ-typed preconditions (`app != nil`, `!sendInFlight`).
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

/// ConnectIQ-free classification of a Garmin outbound `sendMessage` result, so the durable
/// terminal-echo outbox policy gets unit coverage in the default (non-GARMIN) target.
///
/// A terminal command echo (bolus outcome, etc.; `isEcho == true`) must survive an explicit
/// send-failure: re-enqueue to the front of `echoQueue` rather than drop. Dropping a terminal
/// `bolusStatus` echo permanently loses the outcome and leaves the watch stuck "delivering…".
/// A coalesced status snapshot (`isEcho == false`) may still be dropped — a newer status
/// supersedes it.
enum GarminSendDisposition: Equatable {
    /// Transport acknowledged the send (ConnectIQ `.success`) — clear it from the outbox.
    case ack
    /// Explicit failure of a durable echo — re-enqueue to the front of `echoQueue` (never drop).
    case reenqueueFront
    /// Explicit failure of a coalescing-safe status snapshot — safe to drop.
    case drop
    /// Unrecoverable echo failure (`GarminSendResult.permanentFailure` — AppNotFound /
    /// UnsupportedType / InsufficientMemory, IQConstants.h:34-48). Retrying forever busy-loops,
    /// so it is surfaced once and dropped from the in-memory outbox — unlike `.reenqueueFront`,
    /// this is NOT retried. The durable `RemoteBolusLedger` launch re-seed remains the
    /// terminal-outcome backstop.
    case surfaceAndDrop
}

/// success ⇒ `.ack`; failure of an echo ⇒ `.reenqueueFront`; failure of a non-echo status ⇒ `.drop`.
/// Both the `#if GARMIN` `sendMessage` completion AND the send-watchdog's attempt-exhaustion
/// path route keep/drop through this helper.
///
/// Kept as a boolean seam alongside the granular `GarminSendResult` overload below — the
/// watchdog's timeout has no permanent/transient signal of its own.
func garminSendDisposition(success: Bool, isEcho: Bool) -> GarminSendDisposition {
    if success { return .ack }
    return isEcho ? .reenqueueFront : .drop
}

/// ConnectIQ-free send result with permanent-vs-transient granularity — mirrors IQConstants.h
/// (`AppNotFound` / `UnsupportedType` / `InsufficientMemory` are permanent; every other failure,
/// including ones we can't characterize, is transient). No raw `IQSendMessageResult` crosses here.
enum GarminSendResult: Equatable {
    case success
    case transientFailure
    case permanentFailure
}

/// success ⇒ `.ack`; transient echo failure ⇒ `.reenqueueFront` (never-drop, same as the boolean
/// seam); permanent echo failure ⇒ `.surfaceAndDrop` (unrecoverable — surface once, drop from the
/// in-memory outbox; ledger re-seed is the backstop); any non-echo status failure ⇒ `.drop`
/// regardless of permanent/transient — a newer status supersedes it either way.
///
/// Separate overload from `garminSendDisposition(success:isEcho:)`. The `#if GARMIN` completion
/// routes here (it has a real `IQSendMessageResult`); the watchdog timeout stays on the boolean
/// seam (a timeout is always treated as transient — the safe default when the outcome is unknown).
func garminSendDisposition(result: GarminSendResult, isEcho: Bool) -> GarminSendDisposition {
    switch result {
    case .success: return .ack
    case .transientFailure: return isEcho ? .reenqueueFront : .drop
    case .permanentFailure: return isEcho ? .surfaceAndDrop : .drop
    }
}

/// Caps the outbound Garmin status history array to the watch-plot point budget, applied
/// bridge-side BEFORE send. Does not touch `AppModel`/`RemoteStatusComposer`'s shared
/// `statusCommand` shape (Mac/iPhone still see the full up-to-288-point history). Lives
/// outside `#if GARMIN` so it compiles in the default target. Uncapped, an oversize payload
/// risks the same `InsufficientMemory`/`UnsupportedType` failure classified as permanent
/// (dropped, no retry) — a status push that never needed the extra points could stall the
/// watch chart.
enum GarminHistoryCap {
    /// venu3s watch-face chart budget — matches the widest `watchChartRanges` bucket with
    /// headroom over what's distinguishable at that resolution. Not tied to the composer's
    /// 288-point (24h) buffer, which serves every remote.
    static let pointBudget = 144

    /// Newest-tail, order-preserving cap: an array longer than `pointBudget` keeps the LAST
    /// `pointBudget` elements (the most-recent points the plot actually shows, in their original
    /// oldest→newest order); a short array is returned unchanged. Generic so it caps both the
    /// `history` (Int mg/dL) and paired `historyEpochs` (Int timestamp) arrays identically.
    static func cap<T>(_ points: [T]) -> [T] {
        guard points.count > pointBudget else { return points }
        return Array(points.suffix(pointBudget))
    }
}

/// Applies `GarminHistoryCap` to a status-command dictionary's `history`/`historyEpochs` arrays (the
/// exact JSON keys `RemoteCommand.asDictionary()` produces — no `CodingKeys` override in
/// `RemoteCommand`, so the wire key equals the Swift property name). Caps BOTH to the SAME budget so
/// they stay aligned point-for-point to their timestamps; a dict with neither key (any non-status
/// command — bolus echoes, dismissAcks, …) passes through unchanged. Pure/ConnectIQ-free.
func garminCapStatusHistory(_ dict: [String: Any]) -> [String: Any] {
    var out = dict
    if let h = dict["history"] as? [Int] { out["history"] = GarminHistoryCap.cap(h) }
    if let e = dict["historyEpochs"] as? [Int] { out["historyEpochs"] = GarminHistoryCap.cap(e) }
    return out
}

/// Decode of the out-of-band `imu_window` envelope. Lives outside `#if GARMIN` (Foundation-only)
/// so both wire versions get unit coverage in the default target.
///
/// - v1 (legacy, unversioned or `v:1`): `data` is a flat `[Number]` of Float samples, SAMPLE-MAJOR
///   (each sample's `ch` channel values contiguous), oldest→newest.
/// - v2 (compact, the current wire contract):
///     - `ch` (Int) channel count (e.g. 6: accelX/Y/Z, gyroX/Y/Z), `n` (Int) samples per channel.
///     - `scale` (`[Number]`, length == `ch`) — one dequantization scale per channel, owned by the
///       watch encoder and carried IN the envelope — `float = int16 * scale[ch]`. Never a hardcoded
///       duplicate on either side, so the sides cannot silently drift if the scale is retuned.
///     - `data` — packed int16: `n * ch * 2` raw bytes, little-endian, sample-major. Accepted as
///       either a `[Number]` of raw bytes OR Foundation `Data`. The vendored ConnectIQ SDK's
///       documented `sendMessage` types are String/Number/Null/Array/Dictionary only — no ByteArray
///       — so the real bridged Swift type for a Monkey C `ByteArray` is unverified pre-device;
///       covering both shapes means a mismatch needs only a data-shape fix here, not an envelope
///       redesign.
///
/// ANY malformed/mismatched-length/oversized envelope decodes to an EMPTY array — never a
/// garbled or partial window. `imu_window` is advisory-only (never a dose input);
/// `AppModel.ingestGarminIMUWindow`'s `accelPipeline.predict` already no-ops on empty.
enum GarminImuWindowDecode {
    /// Defensive upper bound on total samples (`n * ch`) — the largest real window is
    /// `WINDOW(150) * ch(6) = 900`; this leaves generous headroom while still rejecting a spoofed
    /// huge `n`/`ch` before it can drive an unbounded allocation.
    static let maxTotalSamples = 4096

    static func decode(_ dict: [String: Any]) -> [Float] {
        let version = (dict["v"] as? NSNumber)?.intValue ?? 1
        return version >= 2 ? decodeV2(dict) : decodeV1(dict)
    }

    private static func decodeV1(_ dict: [String: Any]) -> [Float] {
        (dict["data"] as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue } ?? []
    }

    private static func decodeV2(_ dict: [String: Any]) -> [Float] {
        guard let ch = (dict["ch"] as? NSNumber)?.intValue, ch > 0,
              let n = (dict["n"] as? NSNumber)?.intValue, n > 0 else { return [] }
        let total = n * ch
        guard total > 0, total <= maxTotalSamples else { return [] }
        guard let scaleRaw = dict["scale"] as? [Any], scaleRaw.count == ch else { return [] }
        let scale = scaleRaw.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard scale.count == ch else { return [] }
        guard let bytes = rawBytes(from: dict["data"]), bytes.count == total * 2 else { return [] }
        var out: [Float] = []
        out.reserveCapacity(total)
        for i in 0..<total {
            let lo = UInt16(bytes[2 * i])
            let hi = UInt16(bytes[2 * i + 1])
            let bits = lo | (hi << 8)
            let int16Value = Int16(bitPattern: bits)
            out.append(Float(Double(int16Value) * scale[i % ch]))
        }
        return out
    }

    /// Accepts either a Foundation `Data` or an `[NSNumber]` of raw byte values 0...255 — see the enum
    /// doc comment above for why both shapes are defensively supported.
    private static func rawBytes(from value: Any?) -> [UInt8]? {
        if let data = value as? Data { return [UInt8](data) }
        if let arr = value as? [Any] {
            var out: [UInt8] = []
            out.reserveCapacity(arr.count)
            for element in arr {
                guard let n = (element as? NSNumber)?.intValue, n >= 0, n <= 255 else { return nil }
                out.append(UInt8(n))
            }
            return out
        }
        return nil
    }
}

/// ConnectIQ-free classification of a `getAppStatus` result onto `GarminDiagnostics.AppInstallState`.
/// Lives outside `#if GARMIN` so it compiles in the default target. `nil` when the completion never
/// resolved a status — distinct from an explicit `false`, so a transient probe failure is never
/// confused with a genuinely-absent/mismatched watch app.
func garminClassifyAppInstallState(installed: Bool?) -> GarminDiagnostics.AppInstallState {
    guard let installed else { return .unknown }
    return installed ? .installed : .notInstalled
}

/// A terminal outcome to re-enqueue as a `bolusStatus` echo on launch. ConnectIQ-free so the
/// seeding decision gets unit coverage in the default target.
struct GarminEchoSeed: Equatable { let requestId: String; let status: String; let deliveredUnits: Double?; let message: String? }

/// Which of the ledger's durable terminal outcomes to re-enqueue as echoes on launch — those NOT
/// already confirmed-sent to the watch. `alreadyEchoed` is the durable set of requestIds whose
/// echo was previously acked.
func garminEchoesToSeed(terminalOutcomes: [(requestId: String, status: String, message: String?, deliveredUnits: Double?)],
                        alreadyEchoed: Set<String>) -> [GarminEchoSeed] {
    terminalOutcomes.filter { !alreadyEchoed.contains($0.requestId) }
                    .map { GarminEchoSeed(requestId: $0.requestId, status: $0.status, deliveredUnits: $0.deliveredUnits, message: $0.message) }
}

// MARK: - ConnectIQ-free dismiss-ack decision + handler
//
// Lives OUTSIDE `#if GARMIN`, mirroring `garminEchoesToSeed`/`GarminMessageReadiness` above, precisely
// so `GarminDismissAckBridgeTests` exercises the REAL branching logic in the default (non-GARMIN) test
// target — no ConnectIQ import, no live `AppModel`/`GarminDismissReceiptStore` singleton required.

/// Whether an incoming dismiss should be answered by replaying a stored receipt rather than
/// re-running the dismiss against the pump. A retry reuses the same `requestId`, so once the
/// alert drops out of `activeNotifications`, a same-id retry would hit `dismissAlert`'s
/// missing-alert guard with no way to re-derive the outcome — this check runs first.
func garminDismissShouldReplay(receipt: GarminDismissReceipt?, requestId: String) -> Bool {
    receipt?.requestId == requestId
}

/// Ack decision for a fresh (non-replayed) dismiss. `.authenticatedCleared` is the only outcome
/// that yields an ack; every other (rejected / noResponse / localSnoozeOnly / notAuthenticated)
/// sends nothing — the watch's fail-closed default (stay visible, keep retrying) is right.
enum GarminDismissAckDecision: Equatable {
    case ack(requestId: String, alertId: Int, alertKind: Int)
    case noAck
}
func garminDismissAckDecision(outcome: DismissOutcome, requestId: String, alertId: Int,
                              alertKind: Int) -> GarminDismissAckDecision {
    guard outcome == .authenticatedCleared else { return .noAck }
    return .ack(requestId: requestId, alertId: alertId, alertKind: alertKind)
}

/// ConnectIQ-free core of dismiss handling: replay-or-dismiss, exactly once.
///
/// - Receipt replay: send the stored ack, then the statusRead backstop. Never re-run the dismiss
///   (the alert may already be gone from `activeNotifications`).
/// - Fresh dismiss returning `.authenticatedCleared`: persist the receipt synchronously (before
///   `sendAck`) then send the ack, then the statusRead backstop.
/// - Every other outcome: no ack, only the statusRead backstop (so a capability-absent watch's
///   local-snooze fallback still gets a fresh list).
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
        persistReceipt(rid, aid, akind)   // BEFORE sendAck — persist must win the race against a crash
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
/// The watch confirms on-device (hold-to-deliver) and the host delivers directly — there is no
/// second human confirmation on the phone. The host still recomputes carbs→units, runs the
/// divergence guard, and enforces the max-bolus clamp + message signing. Status is echoed back.
/// Requires Garmin Connect Mobile installed and the watch paired to it.
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

    /// Weak app-wide reference so diagnostics can read this bridge's messaging state without
    /// threading a new parameter through `DebugMenuView`. Set once in `init`.
    static weak var shared: GarminRemoteBridge?

    private weak var model: AppModel?
    private var device: IQDevice?
    private var app: IQApp?

    // Connect IQ's sendMessage is serial + asynchronous: firing another before the last completes
    // backs up a queue, so the watch replays stale status and a bolus's terminal echo gets stuck
    // behind it. We keep at most ONE send in flight, coalesce status pushes (only the latest matters),
    // and never drop command echoes (bolus outcome, etc.) — echoes are sent first.
    private var sendInFlight = false
    // Message-readiness gate. ConnectIQ `.connected` does NOT mean characteristics are
    // discovered; sending before `deviceCharacteristicsDiscovered:` silently loses messages.
    // Gate pump() on this and drain the queue when discovery lands.
    private var readiness = GarminMessageReadiness()
    private var pendingStatus: [String: Any]?     // latest coalesced statusRead payload
    private var echoQueue: [[String: Any]] = []   // ordered command echoes; never coalesced/dropped
    // In-memory `echoQueue` replays terminal echoes until transport-acked within a process.
    // `seedTerminalEchoesFromLedger()` (at launch) closes the across-restart gap from the durable
    // ledger's terminal Garmin outcomes that were not already confirmed-sent. `didSeedTerminalEchoes`
    // makes the seed idempotent per launch.
    private var didSeedTerminalEchoes = false
    // Durable set of requestIds whose terminal echo was already confirmed-sent, so launch
    // re-seed does not re-echo an outcome the watch already received. Bounded (~256, oldest
    // dropped) in UserDefaults.
    private static let alreadyEchoedKey = "garminEchoedRequestIds"
    private static let alreadyEchoedCap = 256
    // Dismiss-ack receipt outbox — a separate UserDefaults key, never touching `alreadyEchoedKey`.
    // A dismissAck echo can therefore never evict (or be evicted by) a bolus outcome's 256-entry set.
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
    // After an explicit send-failure we do NOT re-pump synchronously (that busy-loops the just-failed
    // payload). A bounded-backoff timer schedules one deferred pump() so a transient failure still
    // recovers even without a reconnect; the readiness gate still defers transmit until message-ready.
    private var sendBackoff: Timer?
    private static let sendBackoffInterval: TimeInterval = 4

    // Read-only diagnostics: last completed send outcome (mapped from ConnectIQ at the one place
    // this file imports ConnectIQ) and how many times the send-watchdog has fired this session.
    private(set) var lastSendOutcomeForDiagnostics: GarminDiagnostics.SendOutcome = .none
    private(set) var sendWatchdogFireCountForDiagnostics = 0
    // Watch-app install/version from the most recent `getAppStatus` probe. Defaults to `.installed`
    // so a bridge that hasn't completed its first `registerApp()` probe doesn't misreport a
    // not-installed state it hasn't observed.
    private(set) var appInstallStateForDiagnostics: GarminDiagnostics.AppInstallState = .installed

    init(model: AppModel) {
        self.model = model
        super.init()
        Self.shared = self
        // Opt into CoreBluetooth state restoration (ConnectIQ.h:133-135) so iOS can relaunch us
        // in the background on BLE activity — paired with early (launch-time) construction so a
        // background relaunch has a live bridge. `restoreDevice()` is the intended reconnect-on-launch
        // (the SDK does not handle willRestoreState itself).
        ConnectIQ.sharedInstance().initialize(withUrlScheme: Self.urlScheme, uiOverrideDelegate: nil,
                                              stateRestorationIdentifier: "fabolus.connectiq")
        model.addRemoteEcho { [weak self] cmd in self?.send(cmd) }
        // Proactive status push when pump data changes. AppModel already drives this on a new CGM
        // value and a new/critical pump alert, so the closed-app Garmin background service can
        // refresh immediately via `Background.registerForPhoneAppMessageEvent` instead of waiting
        // for its ~5-min temporal poll. Still subject to readiness + single-in-flight/coalescing
        // in `send`/`pump`. StatusRead-shaped only — never a signed/dose-authorizing command.
        model.addStatusListener { [weak self] snap in self?.sendStatus(snap) }
        model.setupGarmin = { [weak self] in self?.selectDevice() }
        // Phone tells the watch when to run wrist eating-sensing (battery: only when wanted).
        model.onWantAccelSensing = { [weak self] on in
            self?.sendRaw(["v": 1, "type": "eating_sense", "on": on])
        }
        restoreDevice()
    }

    // Unregister on deallocation. Without this, a replaced instance (tests/previews) would leave
    // its delegate registered against the SDK singleton forever.
    deinit {
        ConnectIQ.sharedInstance().unregister(forAllDeviceEvents: self)
        ConnectIQ.sharedInstance().unregister(forAllAppMessages: self)
    }

    var hasDevice: Bool { device != nil }

    /// Outstanding messages this bridge is holding (in-flight send, queued echoes, pending status).
    var queueDepthForDiagnostics: Int {
        echoQueue.count + (pendingStatus == nil ? 0 : 1) + (inFlight == nil ? 0 : 1)
    }

    /// Paired device's live ConnectIQ connection status, or `false` when no device is paired.
    /// Check `hasDevice` first to distinguish "never paired" from "paired but disconnected".
    var deviceConnectedForDiagnostics: Bool {
        guard let device else { return false }
        return ConnectIQ.sharedInstance().getDeviceStatus(device) == .connected
    }

    /// Paired device's raw name, if known — redaction happens at `GarminDiagnostics`, never here.
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
        // Unregister any prior registration BEFORE re-registering. Called from both `restoreDevice()`
        // (launch) and `handleOpenURL()` (re-select). Without unregister, a repeated call stacks
        // listeners (ConnectIQ.h:220-227/:264-272), causing duplicate `handle(cmd)` and a stale
        // registration against the previous device on a switch. Safe on first call — a no-op.
        ConnectIQ.sharedInstance().unregister(forAllDeviceEvents: self)
        ConnectIQ.sharedInstance().unregister(forAllAppMessages: self)
        // Sideloaded app: store UUID == app UUID.
        let app = IQApp(uuid: Self.watchAppUUID, store: Self.watchAppUUID, device: device)
        self.app = app
        ConnectIQ.sharedInstance().register(forDeviceEvents: device, delegate: self)
        ConnectIQ.sharedInstance().register(forAppMessages: app, delegate: self)
        // Already-connected-at-registration (ConnectIQ.h:58): if the device was connected before we
        // registered, `deviceCharacteristicsDiscovered:` may not re-fire, leaving readiness stuck
        // false. Probe app status; a reachable, installed IQAppStatus means communicable → arm
        // readiness and drain. (nil/not-installed keeps it false.)
        ConnectIQ.sharedInstance().getAppStatus(app) { [weak self] appStatus in
            // Read the one Sendable bit (installed?) HERE so only a `Bool?` crosses to the main
            // actor — capturing non-Sendable `IQAppStatus` into a @MainActor Task trips Swift 6.
            // `nil` (completion never resolved) is its own tri-state bit, distinct from `false`.
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
                    // Visible, actionable state — corrects the "✓" `restoreDevice()`/`handleOpenURL()`
                    // already set synchronously (before this async probe resolves).
                    // `openConnectIQAppStore()` is exposed for a future UI "Install" action; never
                    // auto-invoked here — launching Garmin Connect unprompted on every cold start
                    // (registerApp runs from restoreDevice at every launch) would be its own surprise.
                    self.model?.garminStatus = state.statusText
                case .unknown:
                    break   // fail-safe: no status change, readiness stays false
                }
            }
        }
    }

    /// Opens Garmin Connect Mobile's Connect IQ Store page for the paired watch app. No-op if no
    /// app has been resolved yet.
    func openConnectIQAppStore() {
        guard let app else { return }
        ConnectIQ.sharedInstance().showStore(for: app)
    }

    /// Enqueue a command for the watch. Status pushes are coalesced (latest wins); everything else
    /// (bolus echoes, etc.) is queued in order and sent first, so a stale backlog can't delay a
    /// bolus's "delivered"/"cancelled" outcome or make the CGM lag behind the phone.
    private func send(_ cmd: RemoteCommand) {
        guard let rawDict = try? cmd.asDictionary() else { return }
        // Cap history/historyEpochs (no-op for dicts that never carry them) to the watch-plot
        // budget BEFORE enqueueing. Single choke point — every includeHistory send funnels here.
        let dict = garminCapStatusHistory(rawDict)
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

    /// Seed the durable terminal-echo outbox from the ledger at launch, so a bolus outcome recorded
    /// but never echoed (app killed before the echo was transport-acked) is replayed once the watch
    /// is message-ready. Filters outcomes already confirmed-sent. Idempotent per launch.
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
        pump()   // readiness gate defers transmit until the device is message-ready
    }

    /// Launch-time analogue of `seedTerminalEchoesFromLedger()` for the dismiss-ack lane: a receipt
    /// persisted (authenticated pump clear proven) but never sent is resent proactively. Idempotent
    /// per launch. Never touches the bolus `alreadyEchoedKey` lane.
    func seedUnsentDismissAcksFromReceiptStore() {
        guard !didSeedDismissReceipts, let model else { return }
        didSeedDismissReceipts = true
        for receipt in Self.dismissReceiptStore.unackedReceipts() {
            send(model.dismissAckCommand(requestId: receipt.requestId, alertId: receipt.alertId, alertKind: receipt.alertKind))
        }
        pump()   // readiness gate defers transmit until the device is message-ready
    }

    // Durable already-echoed requestId set (UserDefaults, bounded).
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
        // Also gate on message-readiness — a send before characteristics discovery is silently
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
        // Mark coalescing-safe status snapshots (`!isEcho`) as transient so a busy/backgrounded
        // watch may drop a stale one without holding up the next. A terminal echo is NEVER marked
        // transient (must not be silently coalesced by the transport). Distinct from permanent/
        // transient RESULT classification below: this flag describes the outbound send.
        ConnectIQ.sharedInstance().sendMessage(next, to: app, progress: nil, completion: { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.sendGeneration else { return }   // watchdog already superseded this send
                self.sendWatchdog?.invalidate(); self.sendWatchdog = nil
                // Classify onto ConnectIQ-free GarminSendResult at this boundary — no raw
                // IQSendMessageResult crosses into GarminDiagnostics or the disposition helper.
                // Permanent (IQConstants.h:34-48): the device/app rejects the message outright —
                // retrying can never succeed. Everything else is transient.
                let sendResult: GarminSendResult
                switch result {
                case .success: sendResult = .success
                case .failure_AppNotFound, .failure_UnsupportedType, .failure_InsufficientMemory:
                    sendResult = .permanentFailure
                default: sendResult = .transientFailure
                }
                // Map onto ConnectIQ-free GarminDiagnostics.SendOutcome at this boundary.
                switch sendResult {
                case .success: self.lastSendOutcomeForDiagnostics = .delivered
                case .transientFailure: self.lastSendOutcomeForDiagnostics = .failed
                case .permanentFailure: self.lastSendOutcomeForDiagnostics = .permanentlyFailed
                }
                let isEcho = self.inFlight?.isEcho ?? false
                // Transient failure of a terminal echo must NOT be dropped — park it at the front of
                // echoQueue so a readiness-gated reconnect drain replays it. Permanent echo failure is
                // surfaced above and dropped — NOT re-parked; the ledger re-seed remains the backstop.
                // A coalesced status snapshot is safe to drop either way.
                switch garminSendDisposition(result: sendResult, isEcho: isEcho) {
                case .reenqueueFront:
                    if let f = self.inFlight { self.echoQueue.insert(f.payload, at: 0) }
                case .ack:
                    // Terminal echo confirmed sent — record its requestId durably so a launch re-seed
                    // does not re-echo an outcome the watch already got. A dismissAck echo routes to
                    // its own durable lane (GarminDismissReceiptStore) — NEVER `markAlreadyEchoed`,
                    // which is the bolus-only 256-entry set. Distinguished by payload `kind`.
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
                    // Do NOT synchronously re-pump on an explicit failure — that busy-loops the
                    // just-failed payload. Recovery rides the readiness-gated reconnect drain plus
                    // a bounded backoff (a permanent failure has nothing left to re-pump for THIS
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
                // Attempts exhausted. A watchdog TIMEOUT has no permanent/transient signal (no
                // IQSendMessageResult) — stays on the boolean seam, always treated as transient,
                // so a terminal echo parks at the front of echoQueue (never dropped); a coalescing
                // status snapshot is dropped.
                if garminSendDisposition(success: false, isEcho: f.isEcho) == .reenqueueFront {
                    echoQueue.insert(f.payload, at: 0)
                }
                inFlight = nil
            }
        }
        pump()
    }

    /// Schedule a single bounded-backoff pump() after an explicit send-failure instead of re-pumping
    /// synchronously (that busy-loops the just-failed payload). Coalesced — one pending backoff is
    /// enough. The pump() it fires still honors the readiness gate.
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
        // Refuse a delivery-authorizing command that arrived too long after it was composed —
        // a bolus applied minutes late is a double-dose hazard. Only insulin-INCREASING kinds are
        // gated; a late cancel is still honored. Additive: a legacy Garmin that omits `sentAt`
        // is not gated.
        if RemoteCommandFreshness.isStale(cmd) {
            send(RemoteCommand(kind: .bolusStatus, requestId: cmd.requestId,
                               status: .failed, message: RemoteCommandFreshness.rejectionMessage))
            return
        }
        switch cmd.kind {
        case .bolusRequest:
            // Watch already confirmed via hold-to-deliver — deliver directly, no phone dialog.
            // Pump still enforces max + signing. Blocked when Garmin is read-only.
            guard !AppSettings.shared.remotesReadOnly else {
                send(RemoteCommand(kind: .bolusStatus, requestId: cmd.requestId, status: .failed, message: "Read-only mode"))
                return
            }
            // Host recomputes carbs→units, runs the divergence guard, records carbs.
            guard cmd.units != nil || (cmd.carbsGrams ?? 0) > 0 else { return }
            // Forward the entered bolus passcode so the host verifies it against the salted hash.
            // When a passcode is required and this is absent/wrong, `remoteDeliver` denies and
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
            // Route through the ConnectIQ-free core so receipt-replay / authenticated-ack is
            // identical to what GarminDismissAckBridgeTests exercises in the default target.
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
            // Accepts both the legacy v1 flat-Float envelope and v2 compact int16. Fail-safe
            // to empty on any malformed/oversized input.
            let raw = GarminImuWindowDecode.decode(dict)
            Task { @MainActor in self.model?.ingestGarminIMUWindow(rawWindow: raw) }
            return
        }
        guard let cmd = try? RemoteCommand.fromValidated(dict) else { return }
        Task { @MainActor in self.handle(cmd) }
    }
    nonisolated func deviceStatusChanged(_ device: IQDevice!, status: IQDeviceStatus) {
        // Clear readiness whenever the device is not connected; the `true` transition is owned
        // solely by deviceCharacteristicsDiscovered (a bare `.connected` is NOT message-ready).
        Task { @MainActor in self.readiness.deviceStatusChanged(isConnected: status == .connected) }
    }

    /// Characteristics discovered → messaging is ready. Set readiness and drain anything that
    /// queued during the post-connect / pre-discovery window (echoes, coalesced status).
    nonisolated func deviceCharacteristicsDiscovered(_ device: IQDevice!) {
        Task { @MainActor in
            self.readiness.characteristicsDiscovered()
            self.pump()
        }
    }
}

#else

/// Stub used when the app is built **without** the Garmin Connect IQ SDK (the `GARMIN` compile flag is
/// off because the SDK wasn't present at build time — see `scripts/generate-project.sh`). The Garmin
/// remote is unavailable; the Remotes & devices screen shows why. Keeps the same surface `App` uses
/// (`init(model:)` + `handleOpenURL(_:)`) so nothing else changes.
@MainActor
final class GarminRemoteBridge {
    /// Mirrors the `#if GARMIN` variant's `.shared` + diagnostics surface so
    /// `GarminDiagnostics`/`DebugMenuView` compile in a build without the Connect IQ SDK.
    static weak var shared: GarminRemoteBridge?

    init(model: AppModel) { model.garminStatus = nil; Self.shared = self }
    func handleOpenURL(_ url: URL) {}

    var hasDevice: Bool { false }
    var queueDepthForDiagnostics: Int { 0 }
    var lastSendOutcomeForDiagnostics: GarminDiagnostics.SendOutcome { .none }
    var sendWatchdogFireCountForDiagnostics: Int { 0 }
    var deviceConnectedForDiagnostics: Bool { false }
    var deviceNameForDiagnostics: String? { nil }
    /// Mirrors the `#if GARMIN` diagnostics surface — no device, no probe; `.unknown` (never
    /// `.installed`, which would misreport readiness this stub never has).
    var appInstallStateForDiagnostics: GarminDiagnostics.AppInstallState { .unknown }
    /// No-op mirror of the `#if GARMIN` store-link action — no ConnectIQ SDK in this build.
    func openConnectIQAppStore() {}
}

#endif
