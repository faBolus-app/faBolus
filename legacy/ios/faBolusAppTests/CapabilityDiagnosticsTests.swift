import Testing
import faBolusCore
import TandemMessages
@testable import faBolus

/// Pins the diagnostics section format: rejected opcodes render as human-readable names, and the dump is empty when the opt-in is off.
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

    /// The effective time-sensitive interruption level must be observable at both capability
    /// states, read from the injected `timeSensitiveAvailable` value (never a live
    /// `UNUserNotificationCenter` probe), and the copy must never promise breakthrough.
    @Test func timeSensitiveCapabilityPresentReportsUrgentAsBestEffort() {
        let block = CapabilityDiagnostics.section(
            capabilities: .full, badOpcodes: [], enabled: true, timeSensitiveAvailable: true)
        #expect(block.contains("timeSensitiveCapability: yes"))
        #expect(block.contains("effectiveInterruptionLevel: urgent (breaks through Focus/Do Not Disturb when allowed by iOS Settings — never guaranteed)"))
        #expect(!block.contains("will break through"))
    }

    @Test func timeSensitiveCapabilityAbsentReportsLadderToppingOutAtAlert() {
        let block = CapabilityDiagnostics.section(
            capabilities: .full, badOpcodes: [], enabled: true, timeSensitiveAvailable: false)
        #expect(block.contains("timeSensitiveCapability: no"))
        #expect(block.contains("effectiveInterruptionLevel: alert (no Urgent rung on this build — time-sensitive capability absent)"))
    }

    @Test func timeSensitiveLineIsGatedOnTheSharedOptInLikeEveryOtherValue() {
        let block = CapabilityDiagnostics.section(
            capabilities: .full, badOpcodes: [], enabled: false, timeSensitiveAvailable: true)
        #expect(!block.contains("timeSensitiveCapability"))
        #expect(!block.contains("effectiveInterruptionLevel"))
    }

    @Test func omittedArgumentReflectsTheRealBuildAccessor() {
        let block = CapabilityDiagnostics.section(capabilities: .full, badOpcodes: [], enabled: true)
        #expect(block.contains("timeSensitiveCapability: \(NotificationCapability.timeSensitiveAvailable ? "yes" : "no")"))
    }
}
