import Foundation
import CryptoKit

/// Phase 09.6-04 (Task 1, Part C-4a, D-03.4): pure `[Garmin CIQ]` diagnostics-text section builder.
/// Surfaces the phone-side `GarminRemoteBridge`'s already-tracked messaging state — send-queue
/// depth, the last send's outcome, how many times the send-watchdog has fired, and device
/// connection status — read directly at the `DebugMenuView` call site, never re-derived or
/// re-probed here (no new ConnectIQ send is ever issued from this file). Phone-side only (RESEARCH
/// Assumption A3): answers "did my message reach the watch" without a second Connect IQ build.
///
/// Mirrors 09.6-03's `RemoteRoleDiagnostics`/`CgmArbiterDiagnostics` shape: this type takes a plain,
/// already-projected `BridgeState` value rather than the live `GarminRemoteBridge` instance, so it's
/// fully unit-testable with fabricated state (no live ConnectIQ device or bridge instantiation
/// needed) and stays free of any ConnectIQ import — the neutral `SendOutcome` vocabulary is owned
/// here; `GarminRemoteBridge` (which already imports ConnectIQ under `#if GARMIN`) maps its raw
/// `IQSendMessageResult`/watchdog-timeout signal onto it at that boundary (Pattern 4).
///
/// PHI/identity constraint (T-09.6-01): a Garmin device's raw name (user-assigned, e.g. "Zev's
/// venu3s") never reaches the rendered output — every device line redacts `deviceName` to a
/// `stableToken(for:)` (SHA-256, truncated), deterministic across renders like
/// `RemoteRoleDiagnostics`'s peer-name redaction (same rationale: `Hasher` is process-randomized,
/// SHA-256 via `CryptoKit` is not).
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
    }

    /// Deterministic, non-identifying token for a Garmin device name — same input always yields the
    /// same token (SHA-256, not process-randomized), so repeated diagnostics pulls can be correlated
    /// without ever reconstructing the original name. Mirrors `RemoteRoleDiagnostics.stableToken`.
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
    ///     never an omitted header — Pitfall 4).
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
        return lines.joined(separator: "\n")
    }
}
