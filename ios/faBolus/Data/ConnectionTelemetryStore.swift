import Foundation
import faBolusCore

/// §5.2.8 / N21 — local-first, OPT-IN connection telemetry (connection uptime, disconnect reasons,
/// reconciliation outcomes), the diagnostics that make the group-A/C connection defects confirmable.
/// Shares the P9 App-Group container AND the SAME opt-in flag (`NotificationRuntime.telemetryEnabledKey`),
/// so one "share local diagnostics" choice governs both; default OFF, never uploaded. Read-modify-write
/// persisted like the P9 telemetry so a sibling process can't clobber it.
@MainActor
final class ConnectionTelemetryStore {
    private let store: UserDefaults
    private let key = "connectionTelemetry.v1"
    /// When the current link came up, for uptime accrual; nil while down. In-memory only — a process
    /// restart just forgets the in-progress session's uptime (acceptable for cumulative diagnostics).
    private var connectedAt: Date?

    init(store: UserDefaults? = UserDefaults(suiteName: WidgetStore.appGroup)) {
        self.store = store ?? .standard
    }

    /// The shared opt-in — the same flag P9 notification telemetry uses (one diagnostics switch).
    var enabled: Bool { store.bool(forKey: NotificationRuntime.telemetryEnabledKey) }
    var snapshot: ConnectionTelemetry { Self.load(store, key) }

    /// F1 (§13) — erase the accumulated diagnostics blob (for "Delete all on-device data"). Leaves the
    /// opt-in flag alone: that's a preference the user set, not health/diagnostics DATA.
    func clearStoredData() { store.removeObject(forKey: key) }

    // MARK: recorders (all no-ops unless opted in)

    /// The pump link came up: count the connect and start the uptime clock.
    func recordConnected(at now: Date = Date()) {
        connectedAt = now
        bump { $0.connectCount += 1 }
    }

    /// The pump link went down for `reason` (a token from `reasonToken(from:)`): accrue the elapsed
    /// uptime and count the reason.
    func recordDisconnected(reason: String, at now: Date = Date()) {
        let up = connectedAt.map { max(0, now.timeIntervalSince($0)) }
        connectedAt = nil
        bump {
            if let up { $0.totalUptimeSeconds += up }
            $0.disconnects[reason, default: 0] += 1
        }
    }

    /// An unresolved delivery was reconciled to `outcome`.
    func recordReconciliation(_ outcome: ConnectionTelemetry.ReconcileOutcome) {
        bump { $0.reconcile[outcome.rawValue, default: 0] += 1 }
    }

    /// B3a (§5.2.8): a command round-trip completed. `seconds != nil` → count its latency bucket;
    /// `seconds == nil` → the wait timed out (no response). Observational; a no-op unless opted in.
    func recordCommandLatency(_ seconds: Double?) {
        let bucket = seconds.map(ConnectionTelemetry.latencyBucket) ?? ConnectionTelemetry.timeoutBucket
        bump { $0.commandLatency[bucket, default: 0] += 1 }
    }

    /// Bucket a disconnect into a stable token. Keyed off `PumpSnapshot.connectionDetail` (set at the
    /// app boundary in P12 increment 6), so no new backend/protocol plumbing is needed. `nil` detail is a
    /// plain drop or a user-initiated disconnect ("dropped"); the known radio-down phrases map to their
    /// own tokens. D-03: `TandemBackend.applyClientError` now populates `connectionDetail` with a
    /// `"\(domain)#\(code) \(description)"` shape (e.g. "CBErrorDomain#6 The connection has timed out
    /// unexpectedly.") — bucket that on its `domain#code` prefix instead of collapsing it into the same
    /// generic "error" token as every other unmatched detail, so distinct CBError codes stay distinct
    /// counters. Anything that doesn't match any branch (a free-text description with no domain#code
    /// shape) still buckets as "error".
    static func reasonToken(from detail: String?) -> String {
        guard let d = detail else { return "dropped" }
        if d.contains("Bluetooth is off") { return "btOff" }
        if d.contains("permission") { return "unauthorized" }
        if d.contains("unavailable") { return "unsupported" }
        if d.contains("resetting") { return "resetting" }
        if let token = domainCodeToken(from: d) { return token }
        return "error"
    }

    /// Extract a leading `domain#code` token (e.g. "CBErrorDomain#6") from a detail string shaped
    /// `"\(domain)#\(code) \(description)"`. Returns `nil` if `d` doesn't match that shape (no `#`, or
    /// the segment right after `#` isn't a run of digits), so callers fall through to the generic
    /// "error" bucket rather than mis-bucketing arbitrary free text that happens to contain a `#`.
    ///
    /// D-02c (09.6-02): for `CBErrorDomain` specifically, append the human-readable label from
    /// `cbErrorLabels` when the extracted code is a known key (0–18) — e.g.
    /// "CBErrorDomain#7 → Peripheral disconnected". Any other domain, or a code outside 0–18, falls
    /// through unchanged to the raw `domain#code` token (fail-closed, V5 input validation) — never
    /// crashes, never emits unbounded text.
    private static func domainCodeToken(from d: String) -> String? {
        guard let hashIndex = d.firstIndex(of: "#") else { return nil }
        let domain = d[d.startIndex..<hashIndex]
        let afterHash = d.index(after: hashIndex)
        guard afterHash < d.endIndex else { return nil }
        let codeEnd = d[afterHash...].firstIndex(of: " ") ?? d.endIndex
        let codeSubstring = d[afterHash..<codeEnd]
        guard !codeSubstring.isEmpty, codeSubstring.allSatisfy(\.isNumber) else { return nil }
        let token = String(d[d.startIndex..<codeEnd])
        guard domain == "CBErrorDomain", let code = Int(codeSubstring), let label = cbErrorLabels[code] else {
            return token
        }
        return "\(token) → \(label)"
    }

    /// `CBError.Code` raw-value table (0–18), verified via 09.6-RESEARCH.md's Code Examples (a
    /// .NET/MAUI binding mirror of Apple's CoreBluetooth CBError header, cross-checked against this
    /// project's own on-device `CBErrorDomain#7` capture — matches `peripheralDisconnected`). Additive
    /// only: `domainCodeToken(from:)` falls back to the raw token for any code not present here.
    private static let cbErrorLabels: [Int: String] = [
        0: "Unknown", 1: "Invalid parameters", 2: "Invalid handle", 3: "Not connected",
        4: "Out of space", 5: "Operation cancelled", 6: "Connection timeout",
        7: "Peripheral disconnected", 8: "UUID not allowed", 9: "Already advertising",
        10: "Connection failed", 11: "Connection limit reached", 12: "Unknown device",
        13: "Operation not supported", 14: "Peer removed pairing information",
        15: "Encryption timed out", 16: "Too many LE paired devices",
        17: "LE GATT exceeded background notification limit",
        18: "LE GATT near background notification limit",
    ]

    private func bump(_ mutate: (inout ConnectionTelemetry) -> Void) {
        guard enabled else { return }
        var t = Self.load(store, key)   // read-modify-write (sibling processes)
        mutate(&t)
        if let data = try? JSONEncoder().encode(t) { store.set(data, forKey: key) }
    }

    private static func load(_ store: UserDefaults, _ key: String) -> ConnectionTelemetry {
        guard let data = store.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ConnectionTelemetry.self, from: data)
        else { return .init() }
        return decoded
    }
}
