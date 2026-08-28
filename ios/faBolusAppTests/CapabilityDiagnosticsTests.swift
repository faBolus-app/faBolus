import Testing
import faBolusCore
import TandemMessages
@testable import faBolus

/// Phase 09.6-01 (Task 1, TRACER — Part B-a, D-02a): behavior pins for the tracer that proves the
/// phase's architectural spine end-to-end — a NEW pure section-builder (`CapabilityDiagnostics.section`)
/// reading already-cached pump state, gated by the single shared opt-in, ready to flow into the
/// existing `DebugMenuView.diagnosticsText` → `ShareLink`/Documents-file export.
///
/// Debug pump-pairing-loop-api25 hardening (transparency 4a/4b): the "Rejected opcodes" line now renders
/// each auto-excluded read with its HUMAN-READABLE name via `PumpReadCatalog`, and a SAFETY-relevant
/// exclusion (the op-20 cartridge pre-check) appends a user-facing "relying on the pump's own protection"
/// note. `CapabilityDiagnosticsTransparencyTests` covers those paths in depth; the pins here track the
/// format change.
struct CapabilityDiagnosticsTests {
    @Test func enabledRendersCapabilitiesAndSortedRejectedOpcodes() {
        let caps = PumpCapabilities.mobiAdvanced
        let block = CapabilityDiagnostics.section(capabilities: caps, badOpcodes: [0x54, 0x2F], enabled: true)
        let lines = block.components(separatedBy: "\n")

        #expect(lines.first == "")
        #expect(lines[1] == "[Capability/opcode]")
        #expect(lines.contains("supportsSuspendResume: yes"))
        #expect(lines.contains("supportsCarbEntry: yes"))
        // Sorted ascending, decimal: 0x2F == 47 (unknown → "op-47"), 0x54 == 84 (PumpVersionRequest).
        // Neither is a safety-relevant read, so no "Safety note:" line is appended.
        #expect(lines.last == "Rejected opcodes: op-47, Pump version (op-84)")
        #expect(!block.contains("Safety note:"))
    }

    @Test func enabledWithEmptyBadOpcodesRendersNone() {
        let block = CapabilityDiagnostics.section(capabilities: .full, badOpcodes: [], enabled: true)
        #expect(block.contains("Rejected opcodes: none"))
    }

    @Test func disabledRendersOnlyHeaderAndSharedEmptyStatePrompt() {
        let block = CapabilityDiagnostics.section(capabilities: .mobiAdvanced, badOpcodes: [0x2F], enabled: false)
        let lines = block.components(separatedBy: "\n")

        #expect(
            lines == [
                "",
                "[Capability/opcode]",
                "Turn on “Share local diagnostics” above to start collecting capability/opcode data."
            ])
        // Never a capability flag or opcode value when the opt-in is off.
        #expect(!block.contains("supports"))
        #expect(!block.contains("47"))
    }
}
