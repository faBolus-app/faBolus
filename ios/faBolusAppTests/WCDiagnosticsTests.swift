import Testing
import faBolusCore
@testable import faBolus

/// Phase 09.6-05 (Task 1, Part C-3a, D-03.3): behavior pins for the `[Watch WC]` diagnostics
/// section — fabricated reachability/counter inputs are injected directly (no live watch or
/// WCSession pairing required), mirroring 09.6-04's `GarminDiagnostics` "inject the already-tracked
/// state as plain values" precedent.
@MainActor
struct WCDiagnosticsTests {
    @Test func reachableStateRendersReachableYesAndCounters() {
        let block = WCDiagnostics.section(reachable: true, sent: 10, undeliverable: 2, enabled: true)
        let lines = block.components(separatedBy: "\n")

        #expect(lines.first == "")
        #expect(lines[1] == "[Watch WC]")
        #expect(block.contains("Reachable: yes"))
        #expect(block.contains("Sent: 10"))
        #expect(block.contains("Undeliverable: 2"))
    }

    @Test func unreachableStateRendersReachableNoAndUnreachableEmptyState() {
        let block = WCDiagnostics.section(reachable: false, sent: 3, undeliverable: 1, enabled: true)

        #expect(block.contains("[Watch WC]"))
        #expect(block.contains("Reachable: no"))
        #expect(block.contains("— (not currently reachable)"))
        #expect(!block.contains("Sent:"))
        #expect(!block.contains("Undeliverable:"))
    }

    @Test func disabledRendersOnlyHeaderAndEmptyStatePrompt() {
        let block = WCDiagnostics.section(reachable: true, sent: 10, undeliverable: 2, enabled: false)

        #expect(block.contains("[Watch WC]"))
        #expect(!block.contains("Reachable:"))
        #expect(!block.contains("Sent:"))
        #expect(!block.contains("Undeliverable:"))
    }

    /// The header is always present, even unreachable — never an omitted section (Pitfall 4).
    @Test func headerNeverOmittedWhenUnreachable() {
        let block = WCDiagnostics.section(reachable: false, sent: 0, undeliverable: 0, enabled: true)
        let lines = block.components(separatedBy: "\n")
        #expect(lines[1] == "[Watch WC]")
    }
}
