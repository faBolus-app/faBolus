import Foundation
import faBolusCore

// Phase 9 (09-02, MOBI-02): extracted verbatim from the now-deleted `Views/PumpWizardViews.swift`
// (its sole production call site, `ControlIQSettingsView`, is deleted along with the rest of that
// file — gated by `caps.supportsControlIQSettings`, always false on the t:slim-only capability
// model, and itself only reachable via the also-deleted "Advanced control" Settings Section). This
// type survives the deletion because it is an orphaned-but-tested pure-function safety contract
// (T1-6, D-06 guardrail #4) with its own dedicated `CiqDisableWarningTests.swift` suite and a live
// `CiqAwarenessScopeGuardTests` source-scan entry — neither of which this plan's scope touches.
// Byte-for-byte unchanged from its original declaration; only its home file moved.

// MARK: - Control-IQ disable warning (T1-6, D-01/D-06 guardrail #4)

/// The extended "disabling Control-IQ pauses X" confirmation, expressed as PURE functions of the pump's
/// own `ControllerDescriptor` — never a hardcoded brand/behavior string. Because `descriptor.displayName`
/// and `descriptor.automaticCorrection` already differ between `.controlIQ` and `.controlIQPlus`
/// (`ControllerDescriptor.swift:205-231`), a Control-IQ+ pump's warning differs from classic Control-IQ's
/// automatically, with no second hardcoded copy branch. Copy is verbatim from the 09.15-UI-SPEC
/// Copywriting Contract "T1-6" rows — provenance **(c)** Tandem-sourced (Control-IQ Technology User
/// Guide framing: automatic basal adjustment + automatic correction boluses).
enum ControlIQDisableWarning {
    /// Fires ONLY when the controller actually delivers automatic correction (T1-6 fail-closed): a
    /// `.none` controller (`AutomaticCorrection.none`, `enabled == false`) has nothing to warn about, so
    /// `setControlIQ` on a non-CIQ pump stays a no-op-adjacent action with no confirmation gate.
    static func shouldWarn(descriptor: ControllerDescriptor) -> Bool {
        descriptor.automaticCorrection.enabled
    }

    static func title(descriptor: ControllerDescriptor) -> String {
        "Turn off \(descriptor.displayName)?"
    }

    /// (c) Tandem-sourced, derived from `descriptor.displayName` — never a hardcoded brand literal.
    static func body(descriptor: ControllerDescriptor) -> String {
        "Turning off \(descriptor.displayName) stops automatic basal adjustment and automatic correction boluses. Your pump will deliver only your Personal Profile's manual basal rate until you turn it back on."
    }
}
