import Testing
import faBolusCore
@testable import faBolus

/// Phase 09.6-01 (Task 1, TRACER — Part B-a, D-02a): behavior pins for the tracer that proves the
/// phase's architectural spine end-to-end — a NEW pure section-builder (`CapabilityDiagnostics.section`)
/// reading already-cached pump state, gated by the single shared opt-in, ready to flow into the
/// existing `DebugMenuView.diagnosticsText` → `ShareLink`/Documents-file export.
struct CapabilityDiagnosticsTests {
    @Test func enabledRendersCapabilitiesAndSortedRejectedOpcodes() {
        let caps = PumpCapabilities.mobiAdvanced
        let block = CapabilityDiagnostics.section(capabilities: caps, badOpcodes: [0x54, 0x2F], enabled: true)
        let lines = block.components(separatedBy: "\n")

        #expect(lines.first == "")
        #expect(lines[1] == "[Capability/opcode]")
        #expect(lines.contains("supportsSuspendResume: yes"))
        #expect(lines.contains("supportsCarbEntry: yes"))
        // Sorted ascending, decimal: 0x2F == 47, 0x54 == 84.
        #expect(lines.last == "Rejected opcodes: 47, 84")
    }

    @Test func enabledWithEmptyBadOpcodesRendersNone() {
        let block = CapabilityDiagnostics.section(capabilities: .full, badOpcodes: [], enabled: true)
        #expect(block.contains("Rejected opcodes: none"))
    }

    @Test func disabledRendersOnlyHeaderAndSharedEmptyStatePrompt() {
        let block = CapabilityDiagnostics.section(capabilities: .mobiAdvanced, badOpcodes: [0x2F], enabled: false)
        let lines = block.components(separatedBy: "\n")

        #expect(lines == [
            "",
            "[Capability/opcode]",
            "Turn on “Share local diagnostics” above to start collecting capability/opcode data.",
        ])
        // Never a capability flag or opcode value when the opt-in is off.
        #expect(!block.contains("supports"))
        #expect(!block.contains("47"))
    }
}
