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
    /// A standing request for the caller to re-run the SDK's `getAppStatus` arming probe, set when the
    /// device reports `.connected` while readiness is NOT armed.
    ///
    /// Why this exists (bug 2.2 `watch-cgm-status-lag`): readiness used to be a ONE-WAY latch. Any of
    /// the four non-connected `IQDeviceStatus` cases cleared it, and the only things that ever set it
    /// again were `deviceCharacteristicsDiscovered:` — which the SDK does not promise to re-fire for a
    /// device that was already connected (ConnectIQ.h:53-58) — and `registerApp()`, reachable in
    /// practice only when the user taps "Set up Garmin remote". A single blip therefore stranded every
    /// status push AND every watch-poll REPLY (both pass the same `pump()` gate) for the rest of the
    /// process lifetime, which is exactly the reported "syncs once per tap, then never again".
    ///
    /// It is deliberately a *probe request*, not an arm: ConnectIQ.h:53-58 is explicit that a bare
    /// `IQDeviceStatus_Connected` is NOT message-readiness, so `isReady` still flips only on real
    /// characteristic discovery or a successful `getAppStatus` probe. This also de-fangs the unordered
    /// `Task { @MainActor }` hops in the two device-event delegates: if the `false` clear lands after
    /// the discovery `true`, the standing request re-arms us anyway.
    private(set) var needsArmingProbe = false

    /// Characteristics discovered → the device is ready for communication. Supersedes any outstanding
    /// probe request (readiness is already armed; there is nothing left to probe for).
    mutating func characteristicsDiscovered() {
        isReady = true
        needsArmingProbe = false
    }

    /// Any non-connected device status clears readiness — and cancels any outstanding probe request
    /// (probing a disconnected device is pointless; the next `.connected` re-requests). A `.connected`
    /// status never arms readiness itself; when we are not already ready it REQUESTS the arming probe,
    /// which is the only automatic recovery path out of the latch.
    mutating func deviceStatusChanged(isConnected: Bool) {
        guard isConnected else {
            isReady = false
            needsArmingProbe = false
            return
        }
        if !isReady { needsArmingProbe = true }
    }

    /// One-shot read of the probe request — returns `true` at most once per request, so a reconnect
    /// cannot trigger repeated `getAppStatus`/re-registration churn.
    mutating func consumeArmingProbeRequest() -> Bool {
        guard needsArmingProbe else { return false }
        needsArmingProbe = false
        return true
    }

    /// Whether a send may proceed with respect to message readiness.
    var canSend: Bool { isReady }
}

/// Whether the in-flight ConnectIQ send is genuinely stuck, or merely slow but still moving.
///
/// The vendored SDK guarantees the `sendMessage(…progress:completion:isTransient:)` PROGRESS block
/// fires "at least once"; the COMPLETION block carries no such guarantee (ConnectIQ.h). The bridge
/// used to pass `progress: nil` and arm a flat deadline against "operation complete", so a
/// legitimately slow multi-KB status transfer (up to `GarminHistoryCap.pointBudget` history points
/// plus their epochs) was re-sent ON TOP of the still-live transfer. ConnectIQ serialises sends per
/// app, so every re-attempt queued behind the original, pushed the real completion further out, and
/// that late completion was then discarded by the stale-generation guard — the watchdog manufacturing
/// the timeouts it existed to recover from. Wiring progress turns it into a no-progress stall
/// detector, with a hard ceiling so a trickling "slow loris" transfer can never own the single
/// in-flight slot forever.
enum GarminSendWatchdogVerdict: Equatable {
    case progressing
    case stalled
}

/// `sinceLastProgress`/`sinceStart` in seconds. Inclusive boundaries: at exactly the timeout (or the
/// ceiling) the send is stalled. ConnectIQ-free and pure so it gets unit coverage in the default target.
func garminSendWatchdogVerdict(
    sinceLastProgress: TimeInterval, sinceStart: TimeInterval,
    noProgressTimeout: TimeInterval, hardCeiling: TimeInterval
) -> GarminSendWatchdogVerdict {
    if sinceStart >= hardCeiling { return .stalled }
    return sinceLastProgress >= noProgressTimeout ? .stalled : .progressing
}

/// What the bridge should do about a run of sends whose completions never arrived.
enum GarminSendStallAction: Equatable {
    /// Keep re-attempting on the existing registration.
    case keepRetrying
    /// Rebuild the ConnectIQ registration (fresh `IQApp` + re-register + arming probe) — precisely what
    /// tapping "Set up Garmin remote" does by hand, done automatically.
    case reregister
}

/// Escalation policy from "a send stalled" to "rebuild the ConnectIQ registration".
///
/// Bug 2.2: the device export showed ten watchdog fires and `Last send: timed out` on a link the SDK
/// reported as `.connected`, with no code path that ever rebuilt the registration. The user's tap was
/// the only repair, so the relay refreshed exactly once per tap. This makes that repair automatic and
/// evidence-driven: an ARRIVING completion (success or an explicit `IQSendMessageResult` failure)
/// proves the channel is alive and resets the streak; only silence escalates.
struct GarminSendStallTracker {
    /// One full payload's attempt budget (mirrors the bridge's `maxSendAttempts`) — three consecutive
    /// stalls means the same payload was tried to exhaustion with no completion at all.
    static let stallsBeforeReregister = 3
    /// Floor between automatic rebuilds. Unregister/register churn on a genuinely dead link would be
    /// its own battery/BLE-congestion problem, so recovery keeps trying but never thrashes.
    static let minReregisterInterval: TimeInterval = 30

    private(set) var consecutiveStalls = 0
    private(set) var lastReregister: Date?

    /// A send made no progress and its completion never arrived.
    mutating func recordStall(now: Date) -> GarminSendStallAction {
        consecutiveStalls += 1
        guard consecutiveStalls >= Self.stallsBeforeReregister else { return .keepRetrying }
        if let last = lastReregister, now.timeIntervalSince(last) < Self.minReregisterInterval {
            return .keepRetrying  // rate-limited; the streak stays hot so we rebuild once it elapses
        }
        lastReregister = now
        consecutiveStalls = 0
        return .reregister
    }

    /// A completion ARRIVED — success or an explicit SDK failure. Either way the channel is alive, so a
    /// rebuild is not the remedy.
    mutating func recordCompletion() { consecutiveStalls = 0 }
}

/// Whether a blocked send may re-run the SDK's `getAppStatus` arming probe again yet.
///
/// The last hole in bug 2.2's recovery: re-arming on the `.connected` transition only helps if a
/// further device event actually arrives, and an arming probe that resolves `.unknown` (the SDK's
/// completion gave us no status) leaves readiness false with nothing scheduled to try again. Driving a
/// rate-limited re-probe from the blocked send itself closes that — the phone pushes status on every
/// new CGM value plus a ~20 s quiet-link backstop, so the component that WANTS to transmit is the one
/// that triggers the repair, and no permanent latch can survive.
func garminShouldRetryArmingProbe(lastProbe: Date?, now: Date, minInterval: TimeInterval) -> Bool {
    guard let lastProbe else { return true }
    return now.timeIntervalSince(lastProbe) >= minInterval
}

/// Which lane `pump()` serves next.
enum GarminPumpSlot: Equatable {
    case echo
    case status
    case idle
}

/// Anti-starvation ordering for the single in-flight slot.
///
/// Bug 2.2: `pump()` drains `echoQueue` STRICTLY before `pendingStatus`, and a watchdog-exhausted echo
/// is re-parked at `echoQueue` index 0 — where the next `pump()` re-pulls it with `attempts` reset to
/// zero. `maxSendAttempts` was therefore not a global bound: one undeliverable echo (including a tiny
/// out-of-band `eating_sense` control dict from `sendRaw`) retried forever and starved every status
/// push and every watch-poll reply, which is the reported "CGM never updates".
///
/// Safety: this does NOT weaken the terminal-echo rules. No echo is ever dropped or coalesced, and
/// echo-vs-echo ORDER is untouched — a healthy echo still outranks a pending status. Only an echo that
/// has ALREADY exhausted its attempt budget yields ONE slot to a pending status.
func garminNextPumpSlot(hasEcho: Bool, headEchoExhausted: Bool, hasPendingStatus: Bool) -> GarminPumpSlot {
    if hasEcho && !(headEchoExhausted && hasPendingStatus) { return .echo }
    if hasPendingStatus { return .status }
    return hasEcho ? .echo : .idle
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
            let n = (dict["n"] as? NSNumber)?.intValue, n > 0
        else { return [] }
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
struct GarminEchoSeed: Equatable {
    let requestId: String
    let status: String
    let deliveredUnits: Double?
    let message: String?
}

/// Which of the ledger's durable terminal outcomes to re-enqueue as echoes on launch — those NOT
/// already confirmed-sent to the watch. `alreadyEchoed` is the durable set of requestIds whose
/// echo was previously acked.
func garminEchoesToSeed(
    terminalOutcomes: [(requestId: String, status: String, message: String?, deliveredUnits: Double?)],
    alreadyEchoed: Set<String>
) -> [GarminEchoSeed] {
    terminalOutcomes.filter { !alreadyEchoed.contains($0.requestId) }
        .map {
            GarminEchoSeed(
                requestId: $0.requestId, status: $0.status, deliveredUnits: $0.deliveredUnits, message: $0.message)
        }
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
func garminDismissAckDecision(
    outcome: DismissOutcome, requestId: String, alertId: Int,
    alertKind: Int
) -> GarminDismissAckDecision {
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
        persistReceipt(rid, aid, akind)  // BEFORE sendAck — persist must win the race against a crash
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
            let id = UUID(uuidString: s.trimmingCharacters(in: .whitespaces))
        {
            return id
        }
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
    private var pendingStatus: [String: Any]?  // latest coalesced statusRead payload
    private var echoQueue: [[String: Any]] = []  // ordered command echoes; never coalesced/dropped
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
    /// Monotonic registration epoch, mirroring `sendGeneration`. Bumped on every `registerApp()` so an
    /// outstanding `getAppStatus` probe from a superseded registration can be discarded when it lands.
    /// An `Int` is `Sendable`, so it is the only thing that needs to cross into the `@MainActor` hop —
    /// capturing the `IQApp` itself there would trip Swift 6 (`IQApp` is a non-Sendable ObjC class), the
    /// same reason the probe reads `isInstalled` into a `Bool?` before hopping.
    private var registrationGeneration = 0
    private var inFlight: (payload: [String: Any], isEcho: Bool, attempts: Int)?
    private static let sendTimeout: TimeInterval = 8
    private static let maxSendAttempts = 3
    // After an explicit send-failure we do NOT re-pump synchronously (that busy-loops the just-failed
    // payload). A bounded-backoff timer schedules one deferred pump() so a transient failure still
    // recovers even without a reconnect; the readiness gate still defers transmit until message-ready.
    private var sendBackoff: Timer?
    private static let sendBackoffInterval: TimeInterval = 4
    // bug 2.2 (`watch-cgm-status-lag`): the send-watchdog above measured a flat 8 s against "operation
    // COMPLETE", but the SDK only guarantees the `progress:` block fires — not the completion
    // (ConnectIQ.h). Passing `progress: nil` threw that guaranteed liveness signal away, so a slow but
    // healthy multi-KB status transfer was re-sent on top of itself, each re-attempt queueing behind
    // the original (ConnectIQ serialises sends per app) until the genuine completion arrived late and
    // was discarded by the `sendGeneration` guard. `sendTimeout` is now a NO-PROGRESS window, extended
    // by each progress callback, bounded by `sendHardCeiling` so a trickling transfer can't own the
    // single in-flight slot forever.
    private var inFlightStartedAt: Date?
    private var lastProgressAt: Date?
    private static let sendHardCeiling: TimeInterval = 60
    // Escalation from "sends keep going silent" to "rebuild the ConnectIQ registration" — the automatic
    // form of what the owner had to do by hand via "Set up Garmin remote".
    private var sendStalls = GarminSendStallTracker()
    // Rate limit for the arming probe, shared by every path that runs it (registration, the
    // `.connected` re-arm, and the blocked-send retry) so a wedged bridge re-probes at most this often.
    private var lastArmingProbeAt: Date?
    private static let armingProbeRetryInterval: TimeInterval = 20
    // Set when a watchdog-exhausted echo is re-parked at the head of `echoQueue`. One-shot: it lets a
    // pending status take a single slot ahead of that echo so a wedged echo can't starve CGM status
    // forever. Never drops, coalesces, or reorders echoes relative to each other.
    private var headEchoExhausted = false

    // Read-only diagnostics: last completed send outcome (mapped from ConnectIQ at the one place
    // this file imports ConnectIQ) and how many times the send-watchdog has fired this session.
    private(set) var lastSendOutcomeForDiagnostics: GarminDiagnostics.SendOutcome = .none
    private(set) var sendWatchdogFireCountForDiagnostics = 0
    // Watch-app install/version from the most recent `getAppStatus` probe. Defaults to `.installed`
    // so a bridge that hasn't completed its first `registerApp()` probe doesn't misreport a
    // not-installed state it hasn't observed.
    private(set) var appInstallStateForDiagnostics: GarminDiagnostics.AppInstallState = .installed
    // bug 2.2 discriminators. `lastSendProgressForDiagnostics == nil` means no `progress:` callback ever
    // arrived for the last send (the transfer never started) — a different verdict from "moving slowly".
    // `lateCompletionCountForDiagnostics > 0` proves the channel works and the deadline was too short.
    // `autoRecoveryCountForDiagnostics > 0` proves the bridge repaired itself.
    private(set) var lastSendProgressForDiagnostics: GarminDiagnostics.SendProgress?
    private(set) var lateCompletionCountForDiagnostics = 0
    private(set) var autoRecoveryCountForDiagnostics = 0

    init(model: AppModel) {
        self.model = model
        super.init()
        Self.shared = self
        // Opt into CoreBluetooth state restoration (ConnectIQ.h:133-135) so iOS can relaunch us
        // in the background on BLE activity — paired with early (launch-time) construction so a
        // background relaunch has a live bridge. `restoreDevice()` is the intended reconnect-on-launch
        // (the SDK does not handle willRestoreState itself).
        ConnectIQ.sharedInstance().initialize(
            withUrlScheme: Self.urlScheme, uiOverrideDelegate: nil,
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

    /// Whether the message-readiness gate is armed. THE discriminator bug 2.2 lacked: a stall with
    /// `false` here is the readiness latch, a stall with `true` is the transport.
    var messageReadyForDiagnostics: Bool { readiness.canSend }

    /// Ordered command echoes still queued (the lane that drains ahead of status and can starve it).
    var echoQueueDepthForDiagnostics: Int { echoQueue.count }

    /// Whether a coalesced status snapshot is waiting behind the echo lane.
    var statusPendingForDiagnostics: Bool { pendingStatus != nil }

    /// Complete `[Garmin CIQ]` projection, assembled here so the diagnostics call site never has to
    /// enumerate fields (and so a new field can never be silently forgotten there — which is exactly
    /// how `appInstallState` ended up unreadable). Read-only: never issues a ConnectIQ send or probe.
    var diagnosticsBridgeState: GarminDiagnostics.BridgeState {
        var state = GarminDiagnostics.BridgeState(
            queueDepth: queueDepthForDiagnostics,
            lastSendOutcome: lastSendOutcomeForDiagnostics,
            watchdogFires: sendWatchdogFireCountForDiagnostics,
            deviceConnected: deviceConnectedForDiagnostics,
            deviceName: deviceNameForDiagnostics)
        state.appInstallState = appInstallStateForDiagnostics
        state.messageReady = messageReadyForDiagnostics
        state.echoQueueDepth = echoQueueDepthForDiagnostics
        state.statusPending = statusPendingForDiagnostics
        state.lastSendProgress = lastSendProgressForDiagnostics
        state.lateCompletions = lateCompletionCountForDiagnostics
        state.autoRecoveries = autoRecoveryCountForDiagnostics
        return state
    }

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
        UserDefaults.standard.set(
            [first.uuid.uuidString, first.modelName ?? "", first.friendlyName ?? ""],
            forKey: Self.deviceDefaultsKey)
        device = first
        registerApp()
        model?.garminStatus = "Garmin remote: \(first.friendlyName ?? first.modelName ?? "device") ✓"
    }

    private func restoreDevice() {
        guard let parts = UserDefaults.standard.array(forKey: Self.deviceDefaultsKey) as? [String],
            parts.count == 3, let uuid = UUID(uuidString: parts[0])
        else { return }
        device = IQDevice(id: uuid, modelName: parts[1], friendlyName: parts[2])
        registerApp()
        model?.garminStatus = "Garmin remote: \(parts[2].isEmpty ? parts[1] : parts[2])"
    }

    private func registerApp() {
        guard let device else { return }
        // Bump BEFORE either outcome below, so any probe still in flight from the previous registration
        // is invalidated whether this call goes on to succeed or to hit the nil-handle branch.
        registrationGeneration &+= 1
        // Unregister any prior registration BEFORE re-registering. Called from both `restoreDevice()`
        // (launch) and `handleOpenURL()` (re-select). Without unregister, a repeated call stacks
        // listeners (ConnectIQ.h:220-227/:264-272), causing duplicate `handle(cmd)` and a stale
        // registration against the previous device on a switch. Safe on first call — a no-op.
        ConnectIQ.sharedInstance().unregister(forAllDeviceEvents: self)
        ConnectIQ.sharedInstance().unregister(forAllAppMessages: self)
        // Sideloaded app: store UUID == app UUID.
        //
        // `IQApp(uuid:store:device:)` is FAILABLE (`IQApp?`). The ObjC factory
        // `+appWithUUID:storeUuid:device:` (IQApp.h:33) has no nullability annotation, so Swift imports
        // it as `init?` — verified by type-checking against the real ConnectIQ.xcframework, not assumed.
        // The pre-existing `register(forAppMessages:)` below tolerated the optional silently because
        // that ObjC-imported API accepts it; nothing else did, so the nil case had no defined behavior.
        //
        // Why nil is NOT benign, and gets its own visible state rather than a bare `return`: `self.app`
        // feeds `pump()`'s `guard let app`, so a nil handle silently blocks EVERY send — status pushes,
        // command echoes and poll replies alike — for the whole process lifetime, with no timeout and no
        // log. That is precisely the silent-stall class this bug (2.2) exists to remove, so it must be
        // observable in the export the owner pulls. Not retried here: the app UUID is a compile-time
        // constant and `device` is already non-nil, so an immediate retry would fail identically; the
        // remedy is a device re-select, which is what the status text asks for.
        guard let app = IQApp(uuid: Self.watchAppUUID, store: Self.watchAppUUID, device: device) else {
            // Drop any stale handle — we unregistered the previous one above, so keeping it would leave
            // a handle pointing at a registration that no longer exists.
            self.app = nil
            // Readiness must not stay latched true from a previous device: with no app there is nothing
            // to be ready FOR, and a stale `true` would let `pump()` past its readiness check only to
            // fail the `guard let app` on the same line, burning the arming-probe retry budget silently.
            readiness.deviceStatusChanged(isConnected: false)
            appInstallStateForDiagnostics = .noAppHandle
            model?.garminStatus = GarminDiagnostics.AppInstallState.noAppHandle.statusText
            return
        }
        self.app = app
        ConnectIQ.sharedInstance().register(forDeviceEvents: device, delegate: self)
        ConnectIQ.sharedInstance().register(forAppMessages: app, delegate: self)
        probeAppStatusAndArm(app)
    }

    /// Automatic form of the "Set up Garmin remote" repair (bug 2.2 `watch-cgm-status-lag`).
    ///
    /// The owner's watch refreshed exactly once per tap because `registerApp()` — a fresh `IQApp`, a
    /// fresh registration, and the `getAppStatus` arming probe — was the ONLY code edge that ever
    /// repaired a wedged channel or re-armed the readiness latch, and its only callers were
    /// `restoreDevice()` (launch) and `handleOpenURL()` (that tap). This runs the identical repair on
    /// evidence instead of on a user action.
    ///
    /// Safety: `registerApp()` does not touch `echoQueue`, `pendingStatus`, `inFlight`, the durable
    /// `alreadyEchoedKey` set, or the dismiss-receipt outbox — so no terminal bolus echo can be lost,
    /// duplicated, or reordered by a rebuild. `unregister` immediately precedes `register` for the same
    /// delegate, so listeners never stack. Rate limiting lives in `GarminSendStallTracker`; the extra
    /// guard here keeps a manual re-select from being counted or throttled as an auto-recovery.
    private func autoRecoverRegistration() {
        guard device != nil else { return }
        autoRecoveryCountForDiagnostics += 1
        registerApp()
    }

    /// The SDK's own reachability probe, and the ONLY thing besides `deviceCharacteristicsDiscovered:`
    /// that may arm readiness.
    ///
    /// Already-connected-at-registration (ConnectIQ.h:53-58): if the device was connected before we
    /// registered, `deviceCharacteristicsDiscovered:` may not re-fire, leaving readiness stuck false.
    /// Probe app status; a reachable, installed `IQAppStatus` means communicable → arm readiness and
    /// drain. (`nil`/not-installed keeps it false.) Extracted from `registerApp()` so the reconnect
    /// re-arm path can reuse the exact same arming mechanism without tearing the registration down.
    private func probeAppStatusAndArm(_ app: IQApp) {
        lastArmingProbeAt = Date()
        let gen = registrationGeneration
        ConnectIQ.sharedInstance().getAppStatus(app) { [weak self] appStatus in
            // Read the one Sendable bit (installed?) HERE so only a `Bool?` crosses to the main
            // actor — capturing non-Sendable `IQAppStatus` into a @MainActor Task trips Swift 6.
            // `nil` (completion never resolved) is its own tri-state bit, distinct from `false`.
            let installed: Bool? = appStatus?.isInstalled
            Task { @MainActor in
                guard let self else { return }
                // STALENESS GUARD. `getAppStatus` is async and nothing cancels an outstanding probe, so
                // a callback can land AFTER a later `registerApp()` has replaced or cleared `self.app`
                // (a device re-select, or `autoRecoverRegistration()`). Without this guard the stale
                // callback would clobber `appInstallStateForDiagnostics` — including overwriting the
                // `.noAppHandle` that the nil-handle branch just set — and, on `.installed`, would call
                // `characteristicsDiscovered()` + `pump()`, arming readiness for an app handle that no
                // longer exists. The export would then read `Message-ready: yes` / `App: ready` while
                // `self.app` is nil: precisely the misleading silent state this bug exists to remove.
                //
                // Compared by EPOCH, not by `self.app === app`: the latter would capture the non-Sendable
                // `IQApp` into this `@MainActor` closure (Swift 6 violation, and the same trap the
                // `isInstalled`-to-`Bool?` read above exists to avoid), and an address-identity test also
                // carries an ABA hazard if a freed handle's address is reused. A monotonic `Int` epoch has
                // neither problem. Discarding a superseded probe loses no arming, because `registerApp()`
                // always issues a fresh probe for the registration that superseded it.
                guard gen == self.registrationGeneration else { return }
                let state = garminClassifyAppInstallState(installed: installed)
                switch state {
                case .noAppHandle:
                    // UNREACHABLE BY CONSTRUCTION, and deliberately spelled out rather than folded into
                    // a `default:`. `garminClassifyAppInstallState` maps a `Bool?` onto exactly
                    // `.unknown`/`.installed`/`.notInstalled` and has no route to `.noAppHandle`, which
                    // is set ONLY by `registerApp()`'s nil-handle branch (pinned by
                    // `GarminDiagnosticsTests.probeClassifierNeverProducesNoAppHandle`). A `default:`
                    // here would have SILENTLY swallowed this case and compiled; the exhaustive switch
                    // is what caught it, so the exhaustiveness is load-bearing and must stay.
                    // If the classifier ever did gain this route, returning here is the correct
                    // behavior: bail BEFORE touching `appInstallStateForDiagnostics` so a probe cannot
                    // overwrite the nil-handle state, and leave readiness alone — with no app handle
                    // there is nothing to be ready for.
                    return
                case .installed:
                    self.appInstallStateForDiagnostics = state
                    self.readiness.characteristicsDiscovered()
                    self.pump()
                case .notInstalled:
                    self.appInstallStateForDiagnostics = state
                    // Visible, actionable state — corrects the "✓" `restoreDevice()`/`handleOpenURL()`
                    // already set synchronously (before this async probe resolves).
                    // `openConnectIQAppStore()` is exposed for a future UI "Install" action; never
                    // auto-invoked here — launching Garmin Connect unprompted on every cold start
                    // (registerApp runs from restoreDevice at every launch) would be its own surprise.
                    self.model?.garminStatus = state.statusText
                case .unknown:
                    // fail-safe: record the tri-state bit but change nothing else — no user-visible
                    // status churn, and readiness stays false so `pump()` keeps holding.
                    self.appInstallStateForDiagnostics = state
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
            let cmd = RemoteCommand(
                kind: .bolusStatus, requestId: seed.requestId,
                status: RemoteCommand.Status(rawValue: seed.status),
                deliveredUnits: seed.deliveredUnits, message: seed.message)
            if let dict = try? cmd.asDictionary() { echoQueue.append(dict) }
        }
        pump()  // readiness gate defers transmit until the device is message-ready
    }

    /// Launch-time analogue of `seedTerminalEchoesFromLedger()` for the dismiss-ack lane: a receipt
    /// persisted (authenticated pump clear proven) but never sent is resent proactively. Idempotent
    /// per launch. Never touches the bolus `alreadyEchoedKey` lane.
    func seedUnsentDismissAcksFromReceiptStore() {
        guard !didSeedDismissReceipts, let model else { return }
        didSeedDismissReceipts = true
        for receipt in Self.dismissReceiptStore.unackedReceipts() {
            send(
                model.dismissAckCommand(
                    requestId: receipt.requestId, alertId: receipt.alertId, alertKind: receipt.alertKind))
        }
        pump()  // readiness gate defers transmit until the device is message-ready
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

    /// A send wants to go out but message-readiness is not armed. Re-run the SDK's arming probe
    /// (rate-limited, and only while the SDK itself reports the device connected) so recovery never
    /// depends on a further device event arriving, and an arming probe that resolved `.unknown` is
    /// retried instead of stranding the bridge for the rest of the process lifetime — the bug-2.2
    /// "syncs once per tap, then never again" shape.
    private func ensureArmedIfBlocked() {
        guard let app, !readiness.canSend, let device,
            ConnectIQ.sharedInstance().getDeviceStatus(device) == .connected,
            garminShouldRetryArmingProbe(
                lastProbe: lastArmingProbeAt, now: Date(), minInterval: Self.armingProbeRetryInterval)
        else { return }
        probeAppStatusAndArm(app)
    }

    private func pump() {
        // Also gate on message-readiness — a send before characteristics discovery is silently
        // lost. Enqueue-before-pump means gating here only DEFERS the transmit; discovery drains it.
        guard let app, readiness.canSend, !sendInFlight else {
            // Blocked on readiness (not on an in-flight send) → try to re-arm ourselves.
            if !readiness.canSend { ensureArmedIfBlocked() }
            return
        }
        let next: [String: Any]
        let isEcho: Bool
        let attempts: Int
        if let f = inFlight {  // re-attempt of a payload whose completion was lost
            next = f.payload
            isEcho = f.isEcho
            attempts = f.attempts
        } else {
            // Lane choice is delegated to `garminNextPumpSlot` so the anti-starvation rule is pinned by
            // unit tests in the default target. Echoes still win normally — a terminal bolus outcome
            // must never wait behind a CGM snapshot — but an echo that has ALREADY exhausted its
            // attempts and been re-parked yields ONE slot to a pending status. Without that valve, a
            // re-parked echo is re-pulled with `attempts` reset to 0 and retries forever ahead of
            // `pendingStatus`, which is the bug-2.2 head-of-line livelock that stalled the watch's CGM
            // reading indefinitely. Nothing is dropped, coalesced, or reordered echo-vs-echo.
            switch garminNextPumpSlot(
                hasEcho: !echoQueue.isEmpty, headEchoExhausted: headEchoExhausted,
                hasPendingStatus: pendingStatus != nil)
            {
            case .echo:
                next = echoQueue.removeFirst()
                isEcho = true
                attempts = 0
            case .status:
                guard let status = pendingStatus else { return }
                next = status
                pendingStatus = nil
                isEcho = false
                attempts = 0
                headEchoExhausted = false  // one-shot: the echo regains priority on the next pump
            case .idle:
                return
            }
        }
        inFlight = (next, isEcho, attempts)
        sendInFlight = true
        sendGeneration &+= 1
        let gen = sendGeneration
        let startedAt = Date()
        inFlightStartedAt = startedAt
        lastProgressAt = startedAt
        lastSendProgressForDiagnostics = nil  // no progress callback for THIS send yet
        armSendWatchdog(generation: gen)
        // Mark coalescing-safe status snapshots (`!isEcho`) as transient so a busy/backgrounded
        // watch may drop a stale one without holding up the next. A terminal echo is NEVER marked
        // transient (must not be silently coalesced by the transport). Distinct from permanent/
        // transient RESULT classification below: this flag describes the outbound send.
        ConnectIQ.sharedInstance().sendMessage(
            next, to: app,
            progress: { [weak self] sentBytes, totalBytes in
                // The SDK guarantees this block fires at least once for a transfer that starts
                // (ConnectIQ.h) — it is the ONLY liveness signal `sendMessage` promises, and it used to
                // be discarded (`progress: nil`). Each callback proves bytes are moving, so it records
                // the byte counts for diagnostics and EXTENDS the watchdog: a slow-but-healthy transfer
                // must never be re-sent on top of itself (ConnectIQ serialises sends per app, so a
                // re-attempt queues behind the original and pushes the real completion out past the
                // stale-generation guard — bug 2.2's self-inflicted timeout spiral).
                let sent = Int(sentBytes)
                let total = Int(totalBytes)
                Task { @MainActor in
                    guard let self, gen == self.sendGeneration else { return }  // superseded send
                    self.lastSendProgressForDiagnostics = GarminDiagnostics.SendProgress(
                        sentBytes: sent, totalBytes: total)
                    let now = Date()
                    self.lastProgressAt = now
                    // Extend the no-progress window only while under the absolute ceiling — a trickling
                    // transfer must not own the single in-flight slot forever.
                    if garminSendWatchdogVerdict(
                        sinceLastProgress: 0,
                        sinceStart: now.timeIntervalSince(self.inFlightStartedAt ?? now),
                        noProgressTimeout: Self.sendTimeout, hardCeiling: Self.sendHardCeiling)
                        == .progressing
                    {
                        self.armSendWatchdog(generation: gen)
                    }
                }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    guard gen == self.sendGeneration else {
                        // The watchdog already gave up on this send, yet the transport DID complete it.
                        // Counting these is the decisive bug-2.2 discriminator: a non-zero count proves
                        // the channel works and the deadline was too short, rather than the channel
                        // being dead. Also resets the stall streak — an arriving completion, however
                        // late, means re-registration is not the remedy.
                        self.lateCompletionCountForDiagnostics += 1
                        self.sendStalls.recordCompletion()
                        return
                    }
                    self.sendWatchdog?.invalidate()
                    self.sendWatchdog = nil
                    // A completion ARRIVED (success or an explicit SDK failure) — the channel is alive,
                    // so the escalation-to-re-registration streak resets. Only silence escalates.
                    self.sendStalls.recordCompletion()
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
                        // Open the starvation valve: this echo is re-parked at the head of the queue and
                        // will be retried ahead of everything, so let a pending status take ONE slot
                        // first. Otherwise a repeatedly-failing echo blocks CGM status forever (bug 2.2).
                        // The echo is never dropped and its order relative to other echoes is unchanged.
                        self.headEchoExhausted = true
                    case .ack:
                        self.headEchoExhausted = false  // the head echo cleared — normal priority resumes
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
                    case .drop:
                        break  // a coalescing-safe status snapshot; a newer one supersedes it
                    case .surfaceAndDrop:
                        // The echo left the queue permanently (unrecoverable) — close the valve so a
                        // future echo starts at normal priority.
                        self.headEchoExhausted = false
                    }
                    self.inFlight = nil
                    self.sendInFlight = false
                    self.inFlightStartedAt = nil
                    self.lastProgressAt = nil
                    if sendResult == .success {
                        self.pump()  // drain the next queued message (echo first, else the latest status)
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

    /// The ConnectIQ completion never arrived. Recover instead of wedging the queue: re-attempt the same
    /// payload (bounded), else park/drop it and move on. Bumping `sendGeneration` makes any late
    /// completion for this send a no-op, so it can't double-drain.
    ///
    /// bug 2.2: the deadline is now a NO-PROGRESS window, not "not finished yet". If the SDK's
    /// `progress:` block reported bytes within `sendTimeout` and we are still under `sendHardCeiling`,
    /// the transfer is alive and this fire is spurious — re-arm and let it finish rather than re-sending
    /// on top of it. Only a genuine stall counts toward escalation, and an exhausted payload with no
    /// completion at all triggers an automatic re-registration (a fresh `IQApp` + registration + arming
    /// probe): the same repair the user was having to perform by tapping "Set up Garmin remote".
    private func sendWatchdogFired(generation gen: Int) {
        guard gen == sendGeneration else { return }  // a completion already advanced us; stale timer
        let now = Date()
        if inFlight != nil,
            garminSendWatchdogVerdict(
                sinceLastProgress: now.timeIntervalSince(lastProgressAt ?? now),
                sinceStart: now.timeIntervalSince(inFlightStartedAt ?? now),
                noProgressTimeout: Self.sendTimeout, hardCeiling: Self.sendHardCeiling) == .progressing
        {
            armSendWatchdog(generation: gen)  // still moving — do NOT pile a re-send onto a live transfer
            return
        }
        sendGeneration &+= 1
        sendWatchdog = nil
        sendInFlight = false
        inFlightStartedAt = nil
        lastProgressAt = nil
        lastSendOutcomeForDiagnostics = .timedOut
        sendWatchdogFireCountForDiagnostics += 1
        var attemptsExhausted = false
        if var f = inFlight {
            f.attempts += 1
            if f.attempts < Self.maxSendAttempts {
                inFlight = f  // bounded re-attempt
            } else {
                attemptsExhausted = true
                // Attempts exhausted. A watchdog TIMEOUT has no permanent/transient signal (no
                // IQSendMessageResult) — stays on the boolean seam, always treated as transient,
                // so a terminal echo parks at the front of echoQueue (never dropped); a coalescing
                // status snapshot is dropped.
                if garminSendDisposition(success: false, isEcho: f.isEcho) == .reenqueueFront {
                    echoQueue.insert(f.payload, at: 0)
                    // Open the starvation valve — see the completion path. A re-parked echo would
                    // otherwise be re-pulled with `attempts` reset to 0 and retried ahead of
                    // `pendingStatus` forever, which is what stalled the watch's CGM reading.
                    headEchoExhausted = true
                }
                inFlight = nil
            }
        }
        // Escalate only on a genuine, completion-less stall. Rate limiting and the
        // three-strikes threshold live in `GarminSendStallTracker` (unit-tested in the default target).
        if sendStalls.recordStall(now: now) == .reregister {
            autoRecoverRegistration()
            return  // registerApp()'s arming probe pumps once the channel is proven reachable again
        }
        // A fully-exhausted payload with no completion means the channel is suspect; back off instead of
        // immediately re-sending into it. Anything still queued drains on the backoff pump.
        if attemptsExhausted {
            scheduleBackoffPump()
            return
        }
        pump()
    }

    /// Schedule a single bounded-backoff pump() after an explicit send-failure instead of re-pumping
    /// synchronously (that busy-loops the just-failed payload). Coalesced — one pending backoff is
    /// enough. The pump() it fires still honors the readiness gate.
    private func scheduleBackoffPump() {
        guard sendBackoff == nil else { return }
        sendBackoff = Timer.scheduledTimer(withTimeInterval: Self.sendBackoffInterval, repeats: false) {
            [weak self] _ in
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
            send(
                RemoteCommand(
                    kind: .bolusStatus, requestId: cmd.requestId,
                    status: .failed, message: RemoteCommandFreshness.rejectionMessage))
            return
        }
        switch cmd.kind {
        case .bolusRequest:
            // Watch already confirmed via hold-to-deliver — deliver directly, no phone dialog.
            // Pump still enforces max + signing. Blocked when Garmin is read-only.
            guard !AppSettings.shared.remotesReadOnly else {
                send(
                    RemoteCommand(
                        kind: .bolusStatus, requestId: cmd.requestId, status: .failed, message: "Read-only mode"))
                return
            }
            // Host recomputes carbs→units, runs the divergence guard, records carbs.
            guard cmd.units != nil || (cmd.carbsGrams ?? 0) > 0 else { return }
            // Forward the entered bolus passcode so the host verifies it against the salted hash.
            // When a passcode is required and this is absent/wrong, `remoteDeliver` denies and
            // echoes `.failed` — the watch never verifies or stores it.
            Task {
                await model.remoteDeliver(
                    requestId: cmd.requestId, units: cmd.units,
                    carbsGrams: cmd.carbsGrams, bgMgdl: cmd.bgMgdl.map(Int.init),
                    remoteEstimate: cmd.remoteEstimateUnits, passcode: cmd.bolusPasscode,
                    includeStaleBG: cmd.includeStaleBG ?? false, sentAt: cmd.sentAt,
                    from: .garmin, peerId: "garmin")
            }
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
                            Self.dismissReceiptStore.persist(
                                peer: "garmin", requestId: rid, alertId: aid, alertKind: akind)
                        },
                        sendAck: { rid, aid, akind in
                            self.send(model.dismissAckCommand(requestId: rid, alertId: aid, alertKind: akind))
                        },
                        sendStatusBackstop: { self.send(model.statusCommand(includeHistory: true)) }
                    )
                }
            }
        case .statusRead:
            if cmd.forceGlucose == true {
                Task {
                    await model.refreshGlucoseNow()
                    self.send(model.statusCommand(includeHistory: true, replyingTo: cmd.requestId))
                }
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
        // Clear readiness whenever the device is not connected; the `true` transition is still owned
        // solely by deviceCharacteristicsDiscovered / the getAppStatus probe (a bare `.connected` is NOT
        // message-ready — ConnectIQ.h:53-58).
        //
        // bug 2.2 (`watch-cgm-status-lag`): a `.connected` transition arriving while we are NOT ready now
        // leaves a one-shot request to re-run that probe, and we service it here. Before this, readiness
        // was a one-way latch — cleared by any of the four non-connected `IQDeviceStatus` cases and
        // re-armed only by `deviceCharacteristicsDiscovered:` (which the SDK does not promise to re-fire
        // for an already-connected device) or by the user tapping "Set up Garmin remote". So a single
        // blip stranded every status push AND every watch-poll REPLY (both pass the same `pump()` gate)
        // for the rest of the process lifetime. This also removes the permanence of the unordered
        // `Task { @MainActor }` hops between this delegate and `deviceCharacteristicsDiscovered:`: if the
        // `false` clear lands after the discovery `true`, the standing request re-arms us anyway.
        Task { @MainActor in
            self.readiness.deviceStatusChanged(isConnected: status == .connected)
            if self.readiness.consumeArmingProbeRequest(), let app = self.app {
                self.probeAppStatusAndArm(app)
            }
        }
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

    init(model: AppModel) {
        model.garminStatus = nil
        Self.shared = self
    }
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
    /// Mirrors the `#if GARMIN` bug-2.2 discriminator surface. No SDK ⇒ never message-ready, nothing
    /// queued, nothing sent, nothing to recover from.
    var messageReadyForDiagnostics: Bool { false }
    var echoQueueDepthForDiagnostics: Int { 0 }
    var statusPendingForDiagnostics: Bool { false }
    var lastSendProgressForDiagnostics: GarminDiagnostics.SendProgress? { nil }
    var lateCompletionCountForDiagnostics: Int { 0 }
    var autoRecoveryCountForDiagnostics: Int { 0 }
    /// Mirror of the `#if GARMIN` full projection so the diagnostics call site is branch-agnostic.
    var diagnosticsBridgeState: GarminDiagnostics.BridgeState {
        var state = GarminDiagnostics.BridgeState(
            queueDepth: 0, lastSendOutcome: .none, watchdogFires: 0,
            deviceConnected: false, deviceName: nil)
        state.appInstallState = appInstallStateForDiagnostics
        state.messageReady = messageReadyForDiagnostics
        return state
    }
    /// No-op mirror of the `#if GARMIN` store-link action — no ConnectIQ SDK in this build.
    func openConnectIQAppStore() {}
}

#endif
