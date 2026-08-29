import Foundation
import CryptoKit
import faBolusCore

/// Pure `[Remote role]` diagnostics-text section builder.
/// Surfaces this phone's host role + each paired remote peer's already-tracked connection + grant
/// state — read directly from `MacPairingCoordinator` (paired peers, live connection, per-peer
/// `RemotePeerPolicy`) at the `DebugMenuView` call site, never re-derived here. `@MainActor` because
/// the live caller reads `MacPairingCoordinator.shared`, a `@MainActor` singleton; this type itself
/// takes only plain, already-computed values, so it's fully unit-testable with fabricated peer state
/// (no live BLE).
///
/// PHI/identity constraint: a peer's raw display name (a user-chosen device name, e.g.
/// "Zev's MacBook Pro") never reaches the rendered output. Every peer line redacts `displayName` to
/// a `stableToken(for:)` — a SHA-256 digest of the name, truncated — so the token is deterministic
/// across renders (same peer ⇒ same token, useful for correlating repeated diagnostics pulls) while
/// never leaking the underlying name.
@MainActor
enum RemoteRoleDiagnostics {
    /// One paired remote peer's already-tracked state (read, never recomputed): the peer's raw
    /// display name (redacted before rendering), whether it is the currently-connected peer, and its
    /// host-granted `RemotePeerPolicy`.
    struct PeerInfo {
        let displayName: String
        let connected: Bool
        let policy: RemotePeerPolicy
    }

    /// Deterministic, non-identifying token for a peer display name — same input always yields the
    /// same token (SHA-256 is not process-randomized, unlike Swift's default `Hasher`), so repeated
    /// diagnostics pulls can be correlated without ever reconstructing the original name.
    private static func stableToken(for displayName: String) -> String {
        let digest = SHA256.hash(data: Data(displayName.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "peer-\(hex.prefix(8))"
    }

    /// A new peer is view-only until the host explicitly grants more (see `RemotePeerPolicy` doc) —
    /// rendered as "pending" here; any peer with at least one granted permission is "granted".
    private static func grantSummary(_ policy: RemotePeerPolicy) -> String {
        guard !policy.isViewOnly else { return "pending" }
        let perms = policy.permissions.map(\.rawValue).sorted().joined(separator: ",")
        return "granted (\(perms))"
    }

    /// Builds the `[Remote role]` block.
    ///
    /// - Parameters:
    ///   - role: this phone's role label (e.g. "host") for the peers being rendered.
    ///   - peers: every paired peer's already-tracked `(displayName, connected, policy)`, in host
    ///     pairing order.
    ///   - enabled: the SAME shared "Share local diagnostics" opt-in every other section gates on.
    static func section(role: String, peers: [PeerInfo], enabled: Bool) -> String {
        var lines: [String] = ["", "[Remote role]"]
        guard enabled else {
            lines.append("Turn on “Share local diagnostics” above to start collecting remote-role data.")
            return lines.joined(separator: "\n")
        }
        guard !peers.isEmpty else {
            lines.append("— (not currently reachable)")
            return lines.joined(separator: "\n")
        }
        lines.append("Role: \(role)")
        for peer in peers {
            let token = stableToken(for: peer.displayName)
            let connection = peer.connected ? "connected" : "disconnected"
            lines.append("\(token): \(connection) · \(grantSummary(peer.policy))")
        }
        return lines.joined(separator: "\n")
    }
}
