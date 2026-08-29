import Testing
import faBolusCore
@testable import faBolus

/// Behavior pins for the `[CGM arbiter]` diagnostics
/// section — reads the SAME already-arbitrated `GlucoseProvenance` the live UI badge uses
/// (`AppModel.glucoseProvenance`/`failoverBadge`), never re-runs `GlucoseArbiter.merge`. Redaction:
/// a `GlucoseSourceStatus.error(String)` case renders its CASE NAME only, never the associated string.
struct CgmArbiterDiagnosticsTests {
    @Test func pumpProvenanceRendersActiveSourcePump() {
        let block = CgmArbiterDiagnostics.section(provenance: .pump, sourceStatuses: [], enabled: true)
        let lines = block.components(separatedBy: "\n")

        #expect(lines.first == "")
        #expect(lines[1] == "[CGM arbiter]")
        #expect(lines.contains("Active source: pump"))
    }

    @Test func failoverProvenanceRendersSourceIdAndReason() {
        let block = CgmArbiterDiagnostics.section(
            provenance: .failover(sourceID: "dexcom-g7", reason: .pumpStale),
            sourceStatuses: [],
            enabled: true)
        #expect(block.contains("Active source: dexcom-g7 (reason: pumpStale)"))
    }

    @Test func errorStatusRendersCaseNameNotAssociatedString() {
        let block = CgmArbiterDiagnostics.section(
            provenance: .pump,
            sourceStatuses: [(id: "dexcom-g7-ble", status: .error("token expired"))],
            enabled: true)

        #expect(block.contains("dexcom-g7-ble: error"))
        #expect(!block.contains("token expired"))
    }

    @Test func disabledRendersOnlyHeaderAndEmptyState() {
        let block = CgmArbiterDiagnostics.section(
            provenance: .failover(sourceID: "dexcom-g7", reason: .pumpMissing),
            sourceStatuses: [(id: "dexcom-g7-ble", status: .connected)],
            enabled: false)
        let lines = block.components(separatedBy: "\n")

        #expect(
            lines == [
                "",
                "[CGM arbiter]",
                "Turn on “Share local diagnostics” above to start collecting CGM-arbiter data."
            ])
        #expect(!block.contains("Active source"))
        #expect(!block.contains("dexcom-g7-ble"))
    }
}
