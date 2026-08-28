import Testing
import Foundation
import faBolusCore
import TandemMessages
@testable import faBolus

/// Pins that auto-excluded reads show human-readable names, and that a missing safety-relevant read
/// (cartridge pre-check) surfaces a user-facing degraded-guard note. A silent exclusion would hide that the app is relying on the pump's own protection.
@Suite struct CapabilityDiagnosticsTransparencyTests {

    private var cartridgeOpcode: UInt8 { LoadStatusRequest.props.opCode }          // op-20 (safety-relevant)
    private var batteryOpcode: UInt8 { CurrentBatteryV2Request.props.opCode }      // op-144 (not safety-relevant)
    private var iobOpcode: UInt8 { ControlIQIOBRequest.props.opCode }              // op-108 (dose input)
    private var calcSnapshotOpcode: UInt8 { BolusCalcDataSnapshotRequest.props.opCode } // op-115 (dose input)

    // MARK: - Human-readable read names

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

    // MARK: - Safety-degraded disclosure

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
        // The safety note rides the same opt-in gate as every other capability/opcode value.
        let block = CapabilityDiagnostics.section(capabilities: .mobiAdvanced,
                                                  badOpcodes: [cartridgeOpcode], enabled: false)
        #expect(!block.contains("Cartridge/load status"))
        #expect(!block.contains("Safety note:"))
    }

    // MARK: - Dose-input reads emit a dose-specific note (not the op-20 "pump's own protection")

    /// An excluded op108 (IOB) dose-input read must disclose that the bolus calculator fail-closes and will
    /// NOT recommend a dose — distinct from the op20 "relying on the pump's own protection" pre-guard note
    /// (there is no pump-side substitute for the IOB/therapy inputs, so that wording would be wrong here).
    @Test func excludedDoseInputIOBReadEmitsADoseSpecificNoteNotTheOp20Wording() {
        let notes = PumpReadCatalog.safetyDegradedNotes(excludedOpcodes: [iobOpcode])
        #expect(notes.count == 1)
        #expect(notes.first?.contains("Control-IQ IOB (op-\(iobOpcode))") == true,
                "the dose-input note must name the read (human-readable + opcode)")
        #expect(notes.first?.contains("will not recommend a dose") == true,
                "op108 unavailable must disclose the calculator fail-closes and won't recommend a dose")
        #expect(notes.allSatisfy { !$0.contains("own protection") },
                "a dose-input read must NOT reuse the op20 'relying on the pump's own protection' wording")
    }

    /// Same for op115 (therapy settings: CR/ISF/target/max) — the other dose-input read.
    @Test func excludedBolusCalcSnapshotReadEmitsADoseSpecificNote() {
        let notes = PumpReadCatalog.safetyDegradedNotes(excludedOpcodes: [calcSnapshotOpcode])
        #expect(notes.count == 1)
        #expect(notes.first?.contains("Bolus-calculator settings (op-\(calcSnapshotOpcode))") == true,
                "the dose-input note must name the read (human-readable + opcode)")
        #expect(notes.first?.contains("will not recommend a dose") == true,
                "op115 unavailable must disclose the calculator fail-closes and won't recommend a dose")
        #expect(notes.allSatisfy { !$0.contains("own protection") },
                "a dose-input read must NOT reuse the op20 'relying on the pump's own protection' wording")
    }

    /// The two wordings are DISTINCT and coexist: excluding both op20 (safety pre-guard read) and op108
    /// (dose input) yields two separate notes — the op20 "own protection" note AND the dose-input
    /// "will not recommend a dose" note — never one substituted for the other.
    @Test func op20AndADoseInputReadEmitTwoDistinctNotes() {
        let notes = PumpReadCatalog.safetyDegradedNotes(excludedOpcodes: [cartridgeOpcode, iobOpcode])
        #expect(notes.count == 2, "each excluded safety/dose read gets its own note")
        #expect(notes.contains { $0.contains("own protection") },
                "op20 keeps its 'relying on the pump's own protection' pre-guard note")
        #expect(notes.contains { $0.contains("will not recommend a dose") },
                "op108 gets the distinct dose-input 'will not recommend a dose' note")
    }
}
