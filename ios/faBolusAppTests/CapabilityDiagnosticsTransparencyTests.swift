import Testing
import Foundation
import faBolusCore
import TandemMessages
@testable import faBolus

/// Debug session `pump-pairing-loop-api25` — HARDENING PASS task 4 (TRANSPARENCY UX).
///
/// (4a) Auto-excluded reads must be surfaced with HUMAN-READABLE names — not bare decimal opcodes — in the
///      Debug-menu "Rejected opcodes" line. Mechanism B's fixed op77 correlation now records the TRUE
///      failing opcode (op-20, not 0), so the name is accurate. Wired through `CapabilityDiagnostics.section`
///      via the shared `PumpReadCatalog`.
/// (4b) When a SAFETY-relevant read is unavailable on the pump (e.g. the op-20 cartridge pre-check), the
///      app must surface a user-facing note that it is relying on the pump's OWN protection for that
///      capability — a degraded guard must never be silent.
///
/// These pin the pure builders (`PumpReadCatalog` + `CapabilityDiagnostics.section`) the on-screen
/// `DebugMenuView.pumpReadExclusionsSection` and the diagnostics export both render.
@Suite struct CapabilityDiagnosticsTransparencyTests {

    private var cartridgeOpcode: UInt8 { LoadStatusRequest.props.opCode }          // op-20 (safety-relevant)
    private var batteryOpcode: UInt8 { CurrentBatteryV2Request.props.opCode }      // op-144 (not safety-relevant)

    // MARK: - 4a — human-readable read names

    @Test func readNameMapsKnownReadsAndFallsBackForUnknown() {
        #expect(PumpReadCatalog.readName(for: cartridgeOpcode) == "Cartridge/load status")
        #expect(PumpReadCatalog.readName(for: ControlIQIOBRequest.props.opCode) == "Control-IQ IOB")
        #expect(PumpReadCatalog.readName(for: 47) == "op-47")   // unknown opcode → stable fallback
    }

    @Test func rejectedOpcodeLabelIsHumanReadableForKnownReads() {
        #expect(PumpReadCatalog.rejectedOpcodeLabel(for: cartridgeOpcode) == "Cartridge/load status (op-20)")
        #expect(PumpReadCatalog.rejectedOpcodeLabel(for: 47) == "op-47")
    }

    @Test func rejectedOpcodesLineRendersHumanReadableNamesNotBareDecimals() {
        let block = CapabilityDiagnostics.section(capabilities: .mobiAdvanced,
                                                  badOpcodes: [cartridgeOpcode], enabled: true)
        #expect(block.contains("Rejected opcodes: Cartridge/load status (op-20)"),
                "an excluded read must be surfaced by name, not a bare decimal opcode")
        // The old bare-decimal form ("Rejected opcodes: 20") must be gone.
        #expect(!block.contains("Rejected opcodes: 20"))
    }

    // MARK: - 4b — safety-degraded disclosure

    @Test func excludedCartridgeReadEmitsASafetyDegradedNote() {
        let notes = PumpReadCatalog.safetyDegradedNotes(excludedOpcodes: [cartridgeOpcode])
        #expect(notes.count == 1)
        #expect(notes.first?.contains("Cartridge/load status (op-20)") == true)
        #expect(notes.first?.contains("relying on the pump's own protection") == true)

        let block = CapabilityDiagnostics.section(capabilities: .mobiAdvanced,
                                                  badOpcodes: [cartridgeOpcode], enabled: true)
        #expect(block.contains("Safety note: Cartridge/load status (op-20) is unavailable"),
                "an excluded SAFETY-relevant read must surface a user-facing 'relying on the pump' note")
    }

    @Test func excludingANonSafetyReadEmitsNoSafetyNote() {
        #expect(PumpReadCatalog.safetyDegradedNotes(excludedOpcodes: [batteryOpcode]).isEmpty)
        let block = CapabilityDiagnostics.section(capabilities: .mobiAdvanced,
                                                  badOpcodes: [batteryOpcode], enabled: true)
        #expect(!block.contains("Safety note:"),
                "excluding a non-safety read (battery) must NOT fabricate a safety-degraded note")
    }

    @Test func disabledOptInStillRendersNoOpcodeOrSafetyDetail() {
        // The safety note rides the SAME opt-in gate as every other capability/opcode value (Pitfall 3).
        let block = CapabilityDiagnostics.section(capabilities: .mobiAdvanced,
                                                  badOpcodes: [cartridgeOpcode], enabled: false)
        #expect(!block.contains("Cartridge/load status"))
        #expect(!block.contains("Safety note:"))
    }
}
