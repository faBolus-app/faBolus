import Foundation

/// Phase 09.6-06 (Task 1, Part C-1, D-03.1): pure aggregator that promotes `DebugMenuView`'s inline
/// `diagnosticsText` string-building into a standalone, testable type. Mirrors PATTERNS.md's
/// documented shape exactly: `DiagnosticsBundle` only concatenates each surface's own already-
/// formatted `[Bracket]` section string (`CapabilityDiagnostics`, `CgmArbiterDiagnostics`,
/// `RemoteRoleDiagnostics`, `GarminDiagnostics`, the BLE-session-log line-builder,
/// and this type's own `pumpIdentitySection`/`connectionTelemetrySection`/`notificationTelemetrySection`
/// helpers) — it never re-derives or reformats any surface's own state, and performs no I/O of its
/// own (no `FileManager`/`WCSession`/`GarminRemoteBridge`/`GlucoseArbiter` reference anywhere in this
/// file).
///
/// PHI constraint (T-09.6-05): `DiagnosticsBundle` adds no field of its own — the aggregate can only
/// ever contain what each already-reviewed surface section already emits. The whole-bundle redaction
/// review (Task 2) re-confirms nothing new leaks once every surface is concatenated together.
enum DiagnosticsBundle {
    /// Concatenates already-formatted section strings into the single shareable bundle, in the SAME
    /// stable order they are supplied. Pure: no I/O, no async, no re-derivation — identical inputs
    /// always produce identical output.
    static func build(sections: [String]) -> String {
        sections.joined(separator: "\n")
    }

    /// Header + explicit "not currently reachable" placeholder for a surface whose section string is
    /// absent (`nil`) or empty — Pitfall 4: the header must never simply vanish. Most Part C section
    /// builders (`CapabilityDiagnostics`, `GarminDiagnostics`, `RemoteRoleDiagnostics`,
    /// `CgmArbiterDiagnostics`) already render their OWN `[Bracket]` header + empty-state line and
    /// don't need this helper — it exists for a surface whose section producer only returns a string
    /// when data genuinely exists (e.g. a future surface ingested over a request/response channel).
    /// When `section` IS supplied, it is passed through verbatim — this helper never reformats it.
    static func sectionOrPlaceholder(label: String, section: String?) -> String {
        guard let section, !section.isEmpty else {
            return "\n[\(label)]\n— (not currently reachable)"
        }
        return section
    }

    /// `[Pump identity]` — always present (no opt-in gate; not sensitive telemetry, just the
    /// connected pump's already-cached identity fields). Extracted verbatim from `diagnosticsText`'s
    /// prior inline block so it flows through the same pure-aggregator array as every other section.
    static func pumpIdentitySection(modelName: String, softwareVersion: String, isMobi: Bool, connection: String) -> String {
        var lines: [String] = ["", "[Pump identity]"]
        lines.append("Model: \(modelName.isEmpty ? "—" : modelName)")
        lines.append("Software: \(softwareVersion.isEmpty ? "—" : softwareVersion)")
        lines.append("Is Mobi: \(isMobi ? "yes" : "no")")
        lines.append("Connection: \(connection)")
        return lines.joined(separator: "\n")
    }

    /// `[Connection telemetry]` — always present; counters simply read 0/— before any connection
    /// event has ever been recorded (P12 §5.2.8's existing behavior, unchanged). Extracted verbatim
    /// from `diagnosticsText`'s prior inline block.
    static func connectionTelemetrySection(connectCount: Int, totalUptimeFormatted: String,
                                            disconnects: [(key: String, count: Int)],
                                            reconcile: [(key: String, count: Int)]) -> String {
        var lines: [String] = ["", "[Connection telemetry]"]
        lines.append("Connects: \(connectCount)")
        lines.append("Total uptime: \(totalUptimeFormatted)")
        for d in disconnects { lines.append("Disconnect \(d.key): \(d.count)") }
        for r in reconcile { lines.append("Reconcile \(r.key): \(r.count)") }
        return lines.joined(separator: "\n")
    }

    /// `[Notification telemetry]` — pre-existing Part A-adjacent section (P9), extracted verbatim so
    /// it too flows through the same pure-aggregator array rather than staying an inline `View` block.
    static func notificationTelemetrySection(counts: [(category: String, delivered: Int, dismissed: Int, actedUpon: Int)]) -> String {
        var lines: [String] = ["", "[Notification telemetry]"]
        if counts.isEmpty {
            lines.append("—")
        } else {
            for c in counts {
                lines.append("\(c.category): delivered \(c.delivered), dismissed \(c.dismissed), acted \(c.actedUpon)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
