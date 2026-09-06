import Foundation
import faBolusCore

/// Pure aggregator that concatenates each surface's already-formatted `[Bracket]` section string
/// (`CapabilityDiagnostics`, `CgmArbiterDiagnostics`, `GarminDiagnostics`, the BLE-session-log
/// line-builder, and this type's own identity/telemetry helpers). Never re-derives or reformats
/// any surface's own state, and performs no I/O of its own.
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
        lines.append("")
        lines.append(connectionTelemetryLimitation)
        return lines.joined(separator: "\n")
    }

    /// The connection-telemetry non-complementarity, in operator-facing prose. Shared verbatim by
    /// both renderers (this export section and the on-screen footer) so the screen and the export can
    /// never disagree about what the counters mean. `Connects` and `Total uptime` are written on
    /// different edges by different mechanisms, not a matched pair: the first observation of a
    /// connection starts neither counter; a bolus that returns the link to connected bumps `Connects`
    /// with no matching disconnect; a connecting-to-error timeout records a disconnect with zero
    /// uptime; and a silent background reconnect bumps `Connects` while discarding the uptime accrued
    /// before it.
    static let connectionTelemetryLimitation =
        "No ratio between any two rows above is meaningful — not a rate, not an average session "
        + "length. Connects and Total uptime are written on different edges by different mechanisms: "
        + "the first observation of a connection starts neither counter; a bolus that returns the "
        + "link to connected bumps Connects with no matching disconnect; a connecting-to-error "
        + "timeout records a disconnect with zero uptime; and a silent background reconnect bumps "
        + "Connects while discarding the uptime accrued before it. Read each counter on its own."

    /// `[Command latency]` — one row per canonical bucket in `ConnectionTelemetry.latencyBucketOrder`
    /// (fast→slow), never `.sorted(by:)` over `counts`' keys — the alphabetical key sort the other
    /// dictionary rows use would print the slowest bucket first with the sub-second buckets split
    /// apart, misreadable as a slow or bimodal link. Every canonical bucket renders, 0 when absent, so
    /// the fixed order is visible regardless of which buckets happen to have data.
    static func commandLatencySection(counts: [String: Int]) -> String {
        var lines: [String] = ["", "[Command latency]"]
        for bucket in ConnectionTelemetry.latencyBucketOrder {
            lines.append("\(bucket): \(counts[bucket] ?? 0)")
        }
        return lines.joined(separator: "\n")
    }

    /// `[Notification telemetry]` — flows through the same pure-aggregator array rather than staying
    /// an inline `View` block. `windowStartFormatted` follows `connectionTelemetrySection`'s own
    /// convention: already-rendered, never derived here, never backfilled with today's date.
    ///
    /// `requested` (never `delivered`/`presented`/`seen`) counts a broker-approved OS submission, not a
    /// confirmed presentation. `dismissed` is a LOWER BOUND — iOS reports a dismiss only for an explicit
    /// per-notification swipe-away, never "Clear All" or an app-side withdrawal — and the fix that made it
    /// move at all is NOT retroactive: a replay record persisted by an earlier build carries no
    /// attributable category until it churns, so nothing before this window start could ever have counted.
    static func notificationTelemetrySection(
        counts: [(category: String, requested: Int, dismissed: Int, actedUpon: Int)],
        windowStartFormatted: String
    ) -> String {
        var lines: [String] = ["", "[Notification telemetry]"]
        lines.append("Window start: \(windowStartFormatted)")
        if counts.isEmpty {
            lines.append("—")
        } else {
            for c in counts {
                lines.append("\(c.category): requested \(c.requested), dismissed \(c.dismissed), acted \(c.actedUpon)")
            }
        }
        lines.append("")
        lines.append(notificationTelemetryLimitation)
        return lines.joined(separator: "\n")
    }

    /// Shared verbatim by the export section and the on-screen footer (`DebugMenuView`) so they can never
    /// disagree about what these counters mean.
    static let notificationTelemetryLimitation =
        "requested counts a broker-approved submission to the OS, not a confirmed presentation. dismissed "
        + "is a LOWER BOUND, not an exact count: iOS reports a dismiss only for an explicit "
        + "per-notification swipe-away — \"Clear All\" and an app-side withdrawal are never reported — and "
        + "the fix that made it move at all is NOT retroactive, since a replay record persisted by an "
        + "earlier build carries no attributable category until it churns. Read each counter against the "
        + "window start above, never as a count since install."
}
