import Foundation

/// §5.2.8 / N21 — local-first, OPT-IN connection telemetry: the diagnostics that make the group-A/C
/// connection defects (A1–A4, C1–C2) *confirmable* instead of anecdotal. Cumulative counters only — no
/// timestamps, no glucose, no per-event log — so it stays a small, privacy-preserving blob that is never
/// uploaded. A sibling of the P9 notification `CategoryTelemetry`; kept as its own Codable value so it
/// never touches any decision path.
///
/// Command latency is a deliberate follow-up (it's the one dimension that would instrument the command
/// path); this covers connection uptime, disconnect reasons, and reconciliation outcomes.
public struct ConnectionTelemetry: Sendable, Equatable, Codable {
    /// How many times the pump link came up (a fresh connect edge).
    public var connectCount: Int
    /// Total time the link has been up, summed across sessions (seconds).
    public var totalUptimeSeconds: Double
    /// Disconnect reason token → count (see `reasonTokens`), so a flaky radio vs a denied permission vs a
    /// plain range drop are distinguishable rather than one undifferentiated "disconnected".
    public var disconnects: [String: Int]
    /// Reconciliation outcome (`ReconcileOutcome.rawValue`) → count: how unresolved deliveries settled.
    public var reconcile: [String: Int]

    public enum ReconcileOutcome: String, Sendable, CaseIterable, Codable {
        case delivered, cancelled, notDelivered, unavailable, indeterminate
    }

    public init(connectCount: Int = 0, totalUptimeSeconds: Double = 0,
                disconnects: [String: Int] = [:], reconcile: [String: Int] = [:]) {
        self.connectCount = connectCount
        self.totalUptimeSeconds = totalUptimeSeconds
        self.disconnects = disconnects
        self.reconcile = reconcile
    }
}
