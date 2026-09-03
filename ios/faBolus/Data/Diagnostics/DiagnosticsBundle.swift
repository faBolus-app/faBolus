import Foundation

/// Pure aggregator that concatenates each surface's already-formatted `[Bracket]` section string
/// (`CapabilityDiagnostics`, `CgmArbiterDiagnostics`, `RemoteRoleDiagnostics`, `GarminDiagnostics`,
/// the BLE-session-log line-builder, and this type's own identity/telemetry helpers). Never
/// re-derives or reformats any surface's own state, and performs no I/O of its own.
///
/// PHI: `DiagnosticsBundle` adds exactly two non-PHI provenance values of its own — a build-commit
/// stamp (`buildProvenanceSection`) naming which binary produced the export, and a connection-telemetry
/// window-start timestamp (`connectionTelemetrySection`) dating how far back its counters reach. Every
/// other section still only contains what each already-reviewed surface emits.
enum DiagnosticsBundle {
    /// Concatenates already-formatted section strings into the single shareable bundle, in the SAME
    /// stable order they are supplied. Pure: no I/O, no async, no re-derivation — identical inputs
    /// always produce identical output.
    static func build(sections: [String]) -> String {
        sections.joined(separator: "\n")
    }

    /// `[Build]` — names the exact binary an export came from. `buildStamp` is already the fully
    /// rendered value (short commit hash, plus a trailing "+" when the tree was dirty, or "unknown"
    /// outside a git checkout) — this helper only wraps it in the section shape, never re-derives it.
    static func buildProvenanceSection(buildStamp: String) -> String {
        "\n[Build]\nCommit: \(buildStamp)"
    }

    /// Header + explicit "not currently reachable" placeholder for a surface whose section string is
    /// absent (`nil`) or empty — the header must never simply vanish. Most section builders already
    /// render their own `[Bracket]` header + empty-state line and don't need this helper. When
    /// `section` IS supplied, it is passed through verbatim — this helper never reformats it.
    static func sectionOrPlaceholder(label: String, section: String?) -> String {
        guard let section, !section.isEmpty else {
            return "\n[\(label)]\n— (not currently reachable)"
        }
        return section
    }

    /// `[Pump identity]` — always present (no opt-in gate; not sensitive telemetry, just the
    /// connected pump's already-cached identity fields).
    static func pumpIdentitySection(modelName: String, softwareVersion: String, isMobi: Bool, connection: String)
        -> String
    {
        var lines: [String] = ["", "[Pump identity]"]
        lines.append("Model: \(modelName.isEmpty ? "—" : modelName)")
        lines.append("Software: \(softwareVersion.isEmpty ? "—" : softwareVersion)")
        lines.append("Is Mobi: \(isMobi ? "yes" : "no")")
        lines.append("Connection: \(connection)")
        return lines.joined(separator: "\n")
    }

    /// `[Connection telemetry]` — always present; counters simply read 0/— before any connection
    /// event has ever been recorded. `windowStartFormatted` is already-rendered (a formatted date, or
    /// the explicit "unknown — accrued across an unknown set of builds" marker) — this helper never
    /// derives it and never substitutes today's date for an absent value.
    static func connectionTelemetrySection(
        connectCount: Int, totalUptimeFormatted: String,
        disconnects: [(key: String, count: Int)],
        reconcile: [(key: String, count: Int)],
        windowStartFormatted: String
    ) -> String {
        var lines: [String] = ["", "[Connection telemetry]"]
        lines.append("Window start: \(windowStartFormatted)")
        lines.append("Connects: \(connectCount)")
        lines.append("Total uptime: \(totalUptimeFormatted)")
        for d in disconnects { lines.append("Disconnect \(d.key): \(d.count)") }
        for r in reconcile { lines.append("Reconcile \(r.key): \(r.count)") }
        return lines.joined(separator: "\n")
    }

    /// `[Notification telemetry]` — flows through the same pure-aggregator array rather than staying
    /// an inline `View` block.
    static func notificationTelemetrySection(
        counts: [(category: String, delivered: Int, dismissed: Int, actedUpon: Int)]
    ) -> String {
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
