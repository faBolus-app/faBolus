import Foundation
import CryptoKit

/// Pure `[Garmin CIQ]` diagnostics-text section builder. Surfaces the phone-side
/// `GarminRemoteBridge`'s already-tracked messaging state — send-queue depth, the last send's
/// outcome, how many times the send-watchdog has fired, and device connection status — read
/// directly at the `DebugMenuView` call site, never re-derived or re-probed here (no new ConnectIQ
/// send is ever issued from this file). Phone-side only: answers "did my message reach the watch"
/// without a second Connect IQ build.
///
/// Takes a plain, already-projected `BridgeState` value rather than the live `GarminRemoteBridge`
/// instance, so it's fully unit-testable with fabricated state (no live ConnectIQ device) and stays
/// free of any ConnectIQ import — the neutral `SendOutcome` vocabulary is owned here;
/// `GarminRemoteBridge` (which already imports ConnectIQ under `#if GARMIN`) maps its raw
/// `IQSendMessageResult`/watchdog-timeout signal onto it at that boundary.
///
/// PHI/identity: a Garmin device's raw name (user-assigned) never reaches the rendered output —
/// every device line redacts `deviceName` to a `stableToken(for:)` (SHA-256, truncated),
/// deterministic across renders. `Hasher` is process-randomized; SHA-256 via `CryptoKit` is not.
@MainActor
enum GarminDiagnostics {
    /// Neutral projection of a ConnectIQ send completion / send-watchdog outcome. `GarminRemoteBridge`
    /// maps `IQSendMessageResult` (success/failure variants) and its own watchdog-timeout signal onto
    /// this vocabulary — no ConnectIQ-specific type or raw code ever reaches this file.
    enum SendOutcome: String {
        case none = "none yet"
        case delivered
        case failed
        case timedOut = "timed out"
        /// An unrecoverable send failure (AppNotFound/UnsupportedType/InsufficientMemory) —
        /// distinguished from `.failed` (transient; the bridge keeps retrying it) so diagnostics can
        /// tell "still retrying" apart from "gave up, ledger is the backstop".
        case permanentlyFailed = "permanently failed (unrecoverable)"
    }

    /// Neutral projection of a `getAppStatus` result — `GarminRemoteBridge` maps the raw
    /// `IQAppStatus?`/`isInstalled` bit onto this vocabulary at the one place it already imports
    /// ConnectIQ (mirrors `SendOutcome` above). `.unknown` is the fail-safe default when the
    /// completion itself couldn't determine a status (never treated as `.installed`).
    enum AppInstallState: String, Equatable {
        case unknown = "unknown"
        case installed = "installed"
        case notInstalled = "not installed / wrong app id"
        /// The SDK refused to construct an `IQApp` handle at all for our (app-uuid, device) pair —
        /// `IQApp(uuid:store:device:)` is a FAILABLE initializer (the ObjC factory
        /// `+appWithUUID:storeUuid:device:` carries no nullability annotation, so Swift imports it as
        /// `init?`). Distinct from `.notInstalled`: there, we have a handle and the watch answered "not
        /// installed"; here we never got far enough to ask. It must be its own visible state because
        /// with `app == nil` the `guard let app` in `pump()` silently blocks EVERY send for the rest of
        /// the process — the exact silent-stall class bug 2.2 exists to eliminate.
        case noAppHandle = "no app handle"

        /// User-facing status text — used both for `AppModel.garminStatus` (visible not-installed
        /// state) and diagnostics rendering.
        var statusText: String {
            switch self {
            case .installed: return "ready"
            case .notInstalled:
                return
                    "Garmin app not installed on the watch (or a beta/official app-id mismatch) — open the Connect IQ Store to install/verify it."
            case .unknown: return "install status unknown"
            case .noAppHandle:
                return
                    "Garmin remote unavailable — could not create an app reference for this watch. Re-select the watch under “Set up Garmin remote”."
            }
        }
        /// Whether the not-installed/mismatch state should offer a Connect IQ Store link — the ONLY
        /// state that does (installed needs no action; unknown has nothing actionable to offer yet;
        /// `.noAppHandle` has no store remedy either — with no handle there is nothing to show a store
        /// page FOR, and `showStore(for:)` requires the very `IQApp` we failed to build).
        var offerStoreLink: Bool { self == .notInstalled }
    }

    /// The phone's already-tracked Garmin Connect IQ messaging state (read, never recomputed) —
    /// projected from `GarminRemoteBridge` at the `DebugMenuView` call site. `nil` (the parameter to
    /// `section(state:enabled:)`, not this type) means no Garmin device has ever been selected/paired.
    struct BridgeState {
        let queueDepth: Int
        let lastSendOutcome: SendOutcome
        let watchdogFires: Int
        let deviceConnected: Bool
        /// Raw device name, if known — redacted to a stable token before it ever reaches the
        /// rendered text; never rendered verbatim.
        let deviceName: String?
        /// The watch-app install/version state.
        ///
        /// Was `let appInstallState: AppInstallState = .installed` — and Swift EXCLUDES a `let` stored
        /// property that has a default value from the synthesised memberwise initializer, so it was
        /// permanently `.installed`, unsettable by any call site, and the `App:` line below was
        /// unreachable dead code. `var` with the same default keeps every existing call site compiling
        /// while making the field real. (Found while diagnosing bug 2.2 `watch-cgm-status-lag`, whose
        /// only observability channel this is.)
        var appInstallState: AppInstallState = .installed

        // MARK: bug 2.2 stall discriminators
        //
        // The 2026-08-29 device export (`Queue depth: 2 / Last send: timed out / Watchdog fires: 10 /
        // Device: connected`) could not distinguish "the message-readiness gate latched false" from
        // "the ConnectIQ channel is wedged" from "a re-parked echo is starving status", because the
        // section had no field for any of them. Each of the following exists to make ONE of those
        // mechanisms provable or refutable from a single owner-supplied export. All default so existing
        // call sites keep compiling.

        /// The `GarminMessageReadiness` gate. A stall with `false` is the readiness latch; a stall with
        /// `true` is the transport.
        var messageReady: Bool = true
        /// Ordered command echoes waiting (bolus outcomes, dismiss acks, control dicts) — the lane that
        /// drains before status and can therefore starve it.
        var echoQueueDepth: Int = 0
        /// Whether a coalesced status snapshot is waiting behind that lane.
        var statusPending: Bool = false
        /// Bytes moved on the most recent send, from the SDK's `progress:` block (which ConnectIQ.h
        /// guarantees fires at least once). `nil` means no progress callback ever arrived — the
        /// transfer never started, which is the opposite verdict from "slow but moving".
        var lastSendProgress: SendProgress? = nil
        /// Completions that arrived AFTER the send-watchdog had already superseded them. Non-zero proves
        /// the channel works and the deadline was too short — the most decisive single field here.
        var lateCompletions: Int = 0
        /// How many times the bridge rebuilt its own ConnectIQ registration to recover. Non-zero proves
        /// self-healing fired instead of waiting for the user to tap "Set up Garmin remote".
        var autoRecoveries: Int = 0
    }

    /// Bytes transferred / total for a single ConnectIQ send, projected from the SDK's `progress:`
    /// block. Plain value type — no ConnectIQ type reaches this file.
    struct SendProgress: Equatable {
        let sentBytes: Int
        let totalBytes: Int
    }

    /// Deterministic, non-identifying token for a Garmin device name — same input always yields the
    /// same token (SHA-256, not process-randomized), so repeated diagnostics pulls can be correlated
    /// without ever reconstructing the original name.
    private static func stableToken(for name: String) -> String {
        let digest = SHA256.hash(data: Data(name.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "dev-\(hex.prefix(8))"
    }

    /// Builds the `[Garmin CIQ]` `[Bracket]` block, matching the exact shape every existing
    /// diagnostics-text section already uses (blank line, header, plain key: value lines).
    ///
    /// - Parameters:
    ///   - state: the bridge's already-tracked messaging state, or `nil` when no Garmin device has
    ///     ever been selected/paired (renders the explicit "not currently reachable" empty state,
    ///     never an omitted header).
    ///   - enabled: the SAME shared "Share local diagnostics" opt-in every other section gates on.
    ///     When `false`, no queue/send/watchdog/device value is ever rendered — only the header plus
    ///     the shared empty-state prompt (even if `state` is populated).
    static func section(state: BridgeState?, enabled: Bool) -> String {
        var lines: [String] = ["", "[Garmin CIQ]"]
        guard enabled else {
            lines.append("Turn on “Share local diagnostics” above to start collecting Garmin CIQ data.")
            return lines.joined(separator: "\n")
        }
        guard let state else {
            lines.append("— (not currently reachable)")
            return lines.joined(separator: "\n")
        }
        lines.append("Queue depth: \(state.queueDepth)")
        lines.append("Last send: \(state.lastSendOutcome.rawValue)")
        lines.append("Watchdog fires: \(state.watchdogFires)")
        if state.deviceConnected {
            if let name = state.deviceName {
                lines.append("Device: connected (\(stableToken(for: name)))")
            } else {
                lines.append("Device: connected")
            }
        } else {
            lines.append("Device: disconnected")
        }
        // bug 2.2 discriminators — each answers one of the competing stall mechanisms the previous
        // export could not tell apart. Appended AFTER the existing lines so every prior pin holds.
        lines.append("Message-ready: \(state.messageReady ? "yes" : "no")")
        lines.append("Echo queue: \(state.echoQueueDepth)")
        lines.append("Status pending: \(state.statusPending ? "yes" : "no")")
        if let p = state.lastSendProgress {
            lines.append("Last send progress: \(p.sentBytes)/\(p.totalBytes) bytes")
        } else {
            // Explicit, never omitted: a missing line would read as "not measured", when the whole
            // point is proving that ZERO bytes moved (the SDK guarantees progress fires at least once
            // for a transfer that actually started).
            lines.append("Last send progress: none")
        }
        lines.append("Late completions: \(state.lateCompletions)")
        lines.append("Auto recoveries: \(state.autoRecoveries)")
        // Surface the watch-app install/version state on EVERY pull — never a silent "✓" while
        // readiness never arms. Previously conditional on `!= .installed`, which was unreachable (the
        // field was an unsettable `let`); a wrong app id is one of the stall candidates, so its
        // healthy value has to be visible too or its absence proves nothing.
        lines.append("App: \(state.appInstallState.statusText)")
        // Legend. The owner reads this export COLD, months later, without the debug session open — and
        // it is the ONLY verification loop for the bug-2.2 fix (no one can drive ConnectIQ/BLE from a
        // test). So the export has to interpret itself: each line below maps an observable signature to
        // the single mechanism it implicates. Keep these in sync with the discriminators above.
        lines.append("— How to read the above —")
        lines.append("Message-ready: no + Device: connected  ⇒ readiness latch (should self-clear now)")
        lines.append("Late completions > 0  ⇒ sends DO finish, just slower than the deadline")
        lines.append("Auto recoveries > 0  ⇒ registration had wedged; the bridge rebuilt it itself")
        lines.append("Echo queue > 0 + Status pending: yes  ⇒ an echo was starving status pushes")
        lines.append("Last send progress: none + Message-ready: yes  ⇒ nothing moved; not our bug")
        return lines.joined(separator: "\n")
    }
}
