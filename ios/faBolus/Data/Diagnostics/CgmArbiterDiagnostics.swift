import Foundation
import faBolusCore

/// Phase 09.6-03 (Task 1, Part C-2, D-03.2): pure `[CGM arbiter]` diagnostics-text section builder.
/// Surfaces which CGM source is currently winning and why, read from the SAME already-arbitrated
/// `GlucoseProvenance` the live UI "via <source>" badge uses (`AppModel.glucoseProvenance` /
/// `failoverBadge`) — this type never re-runs `GlucoseArbiter.merge` or recomputes provenance
/// (Don't Hand-Roll).
///
/// PHI constraint (T-09.6-01): only provenance/status CASE NAMES are emitted (`pump`/`failover`,
/// `pumpStale`/`pumpMissing`, `idle`/`needsSetup`/`searching`/`connected`/`stale`/`error`) — never a
/// glucose value, and `GlucoseSourceStatus.error`'s associated `String` is deliberately discarded and
/// redacted to the bare case name "error" so an arbitrary upstream error message never reaches the
/// shareable export.
enum CgmArbiterDiagnostics {
    /// Case-name-only projection of a `GlucoseSourceStatus`, discarding `.error`'s associated string.
    private static func caseName(_ status: GlucoseSourceStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .needsSetup: return "needsSetup"
        case .searching: return "searching"
        case .connected: return "connected"
        case .stale: return "stale"
        case .error: return "error"
        }
    }

    /// Builds the `[CGM arbiter]` block.
    ///
    /// - Parameters:
    ///   - provenance: the already-arbitrated `GlucoseProvenance` (read, never recomputed here).
    ///   - sourceStatuses: the configured failover source(s), as `(id, status)` pairs read directly
    ///     from each `GlucoseSource.status` — never re-derived.
    ///   - enabled: the SAME shared "Share local diagnostics" opt-in every other section gates on.
    static func section(
        provenance: GlucoseProvenance,
        sourceStatuses: [(id: String, status: GlucoseSourceStatus)],
        enabled: Bool
    ) -> String {
        var lines: [String] = ["", "[CGM arbiter]"]
        guard enabled else {
            lines.append("Turn on “Share local diagnostics” above to start collecting CGM-arbiter data.")
            return lines.joined(separator: "\n")
        }
        switch provenance {
        case .pump:
            lines.append("Active source: pump")
        case let .failover(sourceID, reason):
            lines.append("Active source: \(sourceID) (reason: \(reason.rawValue))")
        }
        if sourceStatuses.isEmpty {
            lines.append("Configured sources: none")
        } else {
            for (id, status) in sourceStatuses {
                lines.append("\(id): \(caseName(status))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
