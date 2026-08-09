import Foundation

/// §5.2.8 / N21 — local-first, OPT-IN connection telemetry: the diagnostics that make the group-A/C
/// connection defects (A1–A4, C1–C2) *confirmable* instead of anecdotal. Cumulative counters only — no
/// timestamps, no glucose, no per-event log — so it stays a small, privacy-preserving blob that is never
/// uploaded. A sibling of the P9 notification `CategoryTelemetry`; kept as its own Codable value so it
/// never touches any decision path.
///
/// Connection uptime, disconnect reasons, reconciliation outcomes — and (B3a) the 4th dimension:
/// command round-trip latency buckets, the one dimension that instruments the command path (observational
/// only, gated on the same opt-in).
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
    /// B3a (§5.2.8): command round-trip latency bucket (`latencyBucket`) → count, incl. a `timeout` bucket.
    /// Purely observational — a distribution of how long pump responses take, so a laggy radio is
    /// distinguishable from a healthy one. Never on any decision path.
    public var commandLatency: [String: Int]

    public enum ReconcileOutcome: String, Sendable, CaseIterable, Codable {
        case delivered, cancelled, notDelivered, unavailable, indeterminate
    }

    public init(connectCount: Int = 0, totalUptimeSeconds: Double = 0,
                disconnects: [String: Int] = [:], reconcile: [String: Int] = [:],
                commandLatency: [String: Int] = [:]) {
        self.connectCount = connectCount
        self.totalUptimeSeconds = totalUptimeSeconds
        self.disconnects = disconnects
        self.reconcile = reconcile
        self.commandLatency = commandLatency
    }

    // Back-compat decode (B3a): a P12 blob persisted BEFORE `commandLatency` existed has no such key, and
    // Swift's synthesized decoder would THROW on the missing non-optional key → the store's `try? decode`
    // would fall back to a zeroed telemetry, silently wiping the shipped connect/uptime/disconnect/reconcile
    // counters. Decode every field with `decodeIfPresent` (defaulting to empty/zero) so an old blob upgrades
    // in place, preserving those counters. Encoding stays the default (all keys written).
    private enum CodingKeys: String, CodingKey { case connectCount, totalUptimeSeconds, disconnects, reconcile, commandLatency }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connectCount = try c.decodeIfPresent(Int.self, forKey: .connectCount) ?? 0
        totalUptimeSeconds = try c.decodeIfPresent(Double.self, forKey: .totalUptimeSeconds) ?? 0
        disconnects = try c.decodeIfPresent([String: Int].self, forKey: .disconnects) ?? [:]
        reconcile = try c.decodeIfPresent([String: Int].self, forKey: .reconcile) ?? [:]
        commandLatency = try c.decodeIfPresent([String: Int].self, forKey: .commandLatency) ?? [:]
    }

    /// B3a (§5.2.8): bucket a command round-trip time into a stable token. Fixed edges so the distribution
    /// is comparable across sessions; a value at/over 4 s buckets `ge4s` (a `timeout` is recorded separately
    /// by the caller, not via this function). Pure.
    public static func latencyBucket(_ seconds: Double) -> String {
        switch seconds {
        case ..<0.25: return "lt250ms"
        case ..<0.5:  return "lt500ms"
        case ..<1:    return "lt1s"
        case ..<2:    return "lt2s"
        case ..<4:    return "lt4s"
        default:      return "ge4s"
        }
    }
    /// The bucket token for a command that never got a response (timed out / disconnected mid-wait).
    public static let timeoutBucket = "timeout"
}
