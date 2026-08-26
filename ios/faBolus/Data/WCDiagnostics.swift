import Foundation

/// Phase 09.6-05 (Task 1, Part C-3a, D-03.3): pure `[Watch WC]` diagnostics-text section builder.
/// Originally surfaced the phone-side WatchConnectivity host's already-tracked state — live
/// reachability and outbound send-outcome counters — read directly at the `DebugMenuView` call site,
/// never re-derived or re-probed here (no new WatchConnectivity round-trip was ever issued from this
/// file). Mirrors `GarminDiagnostics`/`RemoteRoleDiagnostics`'s shape: takes plain, already-projected
/// values rather than a live transport instance, so it's fully unit-testable with fabricated state (no
/// live WCSession or paired watch needed).
///
/// Phase 17.5 (D1-01): the WatchConnectivity host is retired; `DebugMenuView` now always calls this
/// with the no-host fallback values. This section builder itself is Plan 03's scope to remove.
///
/// PHI/identity constraint (T-09.6-01): only reachability + counts are ever rendered — no device
/// name, no therapy value.
@MainActor
enum WCDiagnostics {
    /// Builds the `[Watch WC]` `[Bracket]` block, matching the exact shape every existing
    /// diagnostics-text section already uses (blank line, header, plain key: value lines).
    ///
    /// - Parameters:
    ///   - reachable: the transport's live `isReachable` state.
    ///   - sent: how many outbound sends this host has attempted.
    ///   - undeliverable: how many of those the transport reported undeliverable.
    ///   - enabled: the SAME shared "Share local diagnostics" opt-in every other section gates on.
    ///     When `false`, no reachability/counter value is ever rendered — only the header plus the
    ///     shared empty-state prompt.
    static func section(reachable: Bool, sent: Int, undeliverable: Int, enabled: Bool) -> String {
        var lines: [String] = ["", "[Watch WC]"]
        guard enabled else {
            lines.append("Turn on “Share local diagnostics” above to start collecting Watch WC data.")
            return lines.joined(separator: "\n")
        }
        lines.append("Reachable: \(reachable ? "yes" : "no")")
        guard reachable else {
            // Pitfall 4: the header + "Reachable: no" line are never omitted — this explicit empty
            // state is the third line, not a collapsed/absent section.
            lines.append("— (not currently reachable)")
            return lines.joined(separator: "\n")
        }
        lines.append("Sent: \(sent)")
        lines.append("Undeliverable: \(undeliverable)")
        return lines.joined(separator: "\n")
    }
}
