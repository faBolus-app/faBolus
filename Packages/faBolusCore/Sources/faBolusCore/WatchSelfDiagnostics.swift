import Foundation
import CryptoKit

/// Phase 09.6-07 (D-03.1, D-04): pure watch-side diagnostics-text builder + phone-side presenter for
/// the watch's OWN diagnostics, closing the ninth surface flagged PARTIAL in 09.6-VERIFICATION.md.
///
/// The watch (`WatchModel`) calls `watchBody(...)` to compose its own concise diagnostics lines when
/// it replies to a phone-issued `.diagnosticsRead` request (see `RemoteCommand.Kind.diagnosticsRead`);
/// the phone (`DebugMenuView`) calls `phoneSection(...)` to wrap the received text (or its absence) in
/// the `[Watch self]` bracket header, mirroring every other Part C diagnostics-text section's shape
/// exactly. Both halves are pure — no I/O, no transport, no live instance — so they're fully
/// unit-testable without a paired watch.
///
/// PHI/identity constraint (T-09.6-01): a supplied bench device name is redacted to a deterministic
/// SHA-256 token (`watch-XXXX`, same shape as `RemoteRoleDiagnostics.stableToken`/`GarminDiagnostics`'s
/// `dev-XXXX`) before it is ever rendered — never verbatim. No therapy/glucose value is ever included;
/// `watchBody` takes no such parameter, so there is nothing of that kind to leak.
public enum WatchSelfDiagnostics {
    /// Deterministic, non-identifying token for a device name — same input always yields the same
    /// token (SHA-256 is not process-randomized, unlike Swift's default `Hasher`), so repeated
    /// diagnostics pulls can be correlated without ever reconstructing the original name.
    private static func stableToken(for name: String) -> String {
        let digest = SHA256.hash(data: Data(name.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "watch-\(hex.prefix(8))"
    }

    /// Builds the watch's OWN concise diagnostics lines (no `[Watch self]` header — the phone adds
    /// that via `phoneSection`). Read-only: takes only already-tracked plain values; never touches
    /// BLE, WatchConnectivity, or the pump.
    ///
    /// - Parameters:
    ///   - reachable: the watch's own `RemoteClientModel.reachable` (is the phone currently reachable
    ///     over WatchConnectivity, from the watch's side).
    ///   - directCgmActive: whether the watch's direct-CGM failover is currently running (it runs only
    ///     while the phone is unreachable — see `WatchModel`).
    ///   - benchPumpStatus: the FABOLUS_WATCH_DIRECT_PUMP bench client's already-tracked status string
    ///     (`WatchPumpClient.statusForDiagnostics`), or nil on a default (non-bench) build/instance.
    ///   - benchDeviceName: an optional raw bench-pump device/peer name to redact alongside the status
    ///     line — NEVER rendered verbatim; always reduced to a `watch-XXXX` token.
    public static func watchBody(reachable: Bool, directCgmActive: Bool,
                                  benchPumpStatus: String? = nil, benchDeviceName: String? = nil) -> String {
        var lines: [String] = []
        lines.append("Phone reachable: \(reachable ? "yes" : "no")")
        lines.append("Direct-CGM failover: \(directCgmActive ? "active" : "idle")")
        if let status = benchPumpStatus {
            if let name = benchDeviceName, !name.isEmpty {
                lines.append("Bench pump: \(status) (\(stableToken(for: name)))")
            } else {
                lines.append("Bench pump: \(status)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Wraps `body` (or its absence) in the `[Watch self]` bracket header, matching the exact shape
    /// every other diagnostics-text section already uses (blank line, header, plain key/value lines).
    /// The header is never omitted (Pitfall 4): opt-in off, no reply yet, and a present body all
    /// render the SAME three-line shape with a different third line.
    ///
    /// - Parameters:
    ///   - body: the watch's already-received, already-redacted diagnostics text
    ///     (`PhoneRemoteHost.lastWatchDiagnosticsText`), or nil when no reply has arrived yet.
    ///   - enabled: the SAME shared "Share local diagnostics" opt-in every other section gates on.
    public static func phoneSection(body: String?, enabled: Bool) -> String {
        var lines: [String] = ["", "[Watch self]"]
        guard enabled else {
            lines.append("Turn on “Share local diagnostics” above to start collecting Watch self data.")
            return lines.joined(separator: "\n")
        }
        guard let body, !body.isEmpty else {
            lines.append("— (not currently reachable)")
            return lines.joined(separator: "\n")
        }
        lines.append(body)
        return lines.joined(separator: "\n")
    }
}
