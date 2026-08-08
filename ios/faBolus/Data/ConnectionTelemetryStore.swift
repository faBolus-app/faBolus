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

    /// Bucket a disconnect into a stable token. Keyed off `PumpSnapshot.connectionDetail` (set at the
    /// app boundary in P12 increment 6), so no new backend/protocol plumbing is needed. `nil` detail is a
    /// plain drop or a user-initiated disconnect ("dropped"); the known radio-down phrases map to their
    /// own tokens; anything else (a transport error's description) buckets as "error" so free-text error
    /// strings don't fragment the counters.
    static func reasonToken(from detail: String?) -> String {
        guard let d = detail else { return "dropped" }
        if d.contains("Bluetooth is off") { return "btOff" }
        if d.contains("permission") { return "unauthorized" }
        if d.contains("unavailable") { return "unsupported" }
        if d.contains("resetting") { return "resetting" }
        return "error"
    }

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
