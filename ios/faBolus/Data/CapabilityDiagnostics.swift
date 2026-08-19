import Foundation
import faBolusCore

/// Phase 09.6-01 (Task 1, TRACER — Part B-a, D-02a): pure `[Capability/opcode]` diagnostics-text
/// section builder. Proves the phase's architectural spine end-to-end: a NEW pure section-builder
/// reads already-computed state (`TandemBackend.capabilities`/`badOpcodesForDiagnostics`), gates on
/// the SAME shared "Share local diagnostics" opt-in every other section already reads (Pitfall 3),
/// and flows into the existing `DebugMenuView.diagnosticsText` → `ShareLink`/Documents-file export —
/// zero new export mechanism, zero new opt-in, zero new BLE traffic (Pitfall 2).
///
/// This function does not read the opt-in flag itself — the caller (`DebugMenuView`) passes `enabled`
/// through, keeping this a pure, trivially-testable function with no `UserDefaults`/App-Group
/// dependency of its own.
///
/// PHI constraint (T-09.6-01): only non-PHI machine tokens are emitted — `PumpCapabilities` boolean
/// flag NAMES (Swift property names, not prose) and decimal opcode integers. No peripheral
/// identifier, no therapy value.
enum CapabilityDiagnostics {
    /// Fixed, declaration-order enumeration of every `PumpCapabilities` boolean flag (Models.swift),
    /// so the rendered section is deterministic and covers every flag without reflection.
    private static func flagLines(_ c: PumpCapabilities) -> [String] {
        let flags: [(String, Bool)] = [
            ("supportsCarbEntry", c.supportsCarbEntry),
            ("supportsBolusCancel", c.supportsBolusCancel),
            ("supportsAlertClear", c.supportsAlertClear),
            ("supportsRemoteAlertDismiss", c.supportsRemoteAlertDismiss),
            ("supportsHistoryBackfill", c.supportsHistoryBackfill),
            ("supportsPairing", c.supportsPairing),
            ("supportsExtendedBolus", c.supportsExtendedBolus),
            ("supportsSuspendResume", c.supportsSuspendResume),
            ("supportsTempBasal", c.supportsTempBasal),
            ("supportsModes", c.supportsModes),
            ("supportsProfiles", c.supportsProfiles),
            ("supportsControlIQSettings", c.supportsControlIQSettings),
            ("supportsCgmSession", c.supportsCgmSession),
            ("supportsCartridgeFill", c.supportsCartridgeFill),
            ("supportsLimits", c.supportsLimits),
            ("supportsTimeSync", c.supportsTimeSync),
            ("supportsSounds", c.supportsSounds),
            ("supportsReminders", c.supportsReminders),
            ("supportsSleepScheduleWrite", c.supportsSleepScheduleWrite),
        ]
        return flags.map { "\($0.0): \($0.1 ? "yes" : "no")" }
    }

    /// Builds the `[Capability/opcode]` `[Bracket] block`, matching the exact shape every existing
    /// diagnostics-text section already uses (blank line, header, plain key: value lines).
    ///
    /// - Parameters:
    ///   - capabilities: the connected backend's already-derived `PumpCapabilities` (read, never
    ///     re-derived here).
    ///   - badOpcodes: opcodes this specific pump connection has rejected this session (read from
    ///     `TandemBackend.badOpcodesForDiagnostics`, never re-probed here).
    ///   - enabled: the SAME shared "Share local diagnostics" opt-in every other section gates on.
    ///     When `false`, no capability or opcode value is ever rendered — only the header plus the
    ///     shared empty-state prompt.
    static func section(capabilities: PumpCapabilities, badOpcodes: Set<UInt8>, enabled: Bool) -> String {
        var lines: [String] = ["", "[Capability/opcode]"]
        guard enabled else {
            lines.append("Turn on “Share local diagnostics” above to start collecting capability/opcode data.")
            return lines.joined(separator: "\n")
        }
        lines.append(contentsOf: flagLines(capabilities))
        if badOpcodes.isEmpty {
            lines.append("Rejected opcodes: none")
        } else {
            // Transparency 4a (debug pump-pairing-loop-api25 hardening): render each auto-excluded read with
            // its human-readable name via the shared `PumpReadCatalog` (now accurate — mechanism B's fixed
            // op77 correlation records the TRUE opcode, not 0), e.g. "Cartridge/load status (op-20)".
            lines.append("Rejected opcodes: "
                + badOpcodes.sorted().map(PumpReadCatalog.rejectedOpcodeLabel(for:)).joined(separator: ", "))
        }
        // Transparency 4b: when a SAFETY-relevant read (e.g. the op-20 cartridge pre-check) is auto-excluded,
        // disclose that the app is relying on the pump's own protection for that capability — a degraded
        // guard must never be silent.
        for note in PumpReadCatalog.safetyDegradedNotes(excludedOpcodes: badOpcodes) {
            lines.append("Safety note: \(note)")
        }
        return lines.joined(separator: "\n")
    }
}
