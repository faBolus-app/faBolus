import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// T1-6 (D-01 / D-06 guardrail #4): the extended disable-Control-IQ warning is a PURE function of the
/// pump's own `ControllerDescriptor` — never a hardcoded brand string. Asserts:
///   (a) the warning body names automatic basal adjustment + automatic correction boluses, derived from
///       the descriptor's `displayName`;
///   (b) no warning path when `automaticCorrection.enabled == false` (the `.none` controller — nothing to
///       warn about, T1-6 fail-closed);
///   (c) Control-IQ vs Control-IQ+ bodies differ PURELY because the descriptors differ — never two
///       hardcoded copy branches.
@Suite struct CiqDisableWarningTests {

    // MARK: (a) body names what automation is lost, derived from the descriptor

    @Test func bodyNamesAutomaticBasalAdjustmentAndAutomaticCorrectionBoluses() {
        let body = ControlIQDisableWarning.body(descriptor: .controlIQ)
        #expect(body.contains("automatic basal adjustment"))
        #expect(body.contains("automatic correction boluses"))
        // Never a hardcoded brand literal standing in for the descriptor's own name.
        #expect(body.contains(ControllerDescriptor.controlIQ.displayName))
    }

    @Test func titleNamesTheDescriptorDisplayName() {
        let title = ControlIQDisableWarning.title(descriptor: .controlIQPlus)
        #expect(title.contains("Control-IQ+"))
        #expect(title == "Turn off Control-IQ+?")
    }

    // MARK: (b) fail-closed — no warning when automaticCorrection.enabled == false

    @Test func noWarningWhenAutomaticCorrectionDisabled() {
        #expect(ControlIQDisableWarning.shouldWarn(descriptor: .noController) == false)
        #expect(ControllerDescriptor.noController.automaticCorrection.enabled == false)
    }

    @Test func warningFiresWhenAutomaticCorrectionEnabled() {
        #expect(ControlIQDisableWarning.shouldWarn(descriptor: .controlIQ) == true)
        #expect(ControlIQDisableWarning.shouldWarn(descriptor: .controlIQPlus) == true)
    }

    // MARK: (c) Control-IQ vs Control-IQ+ bodies/titles differ purely via the descriptor

    @Test func controlIQAndControlIQPlusBodiesDifferPurelyFromDescriptor() {
        let classicBody = ControlIQDisableWarning.body(descriptor: .controlIQ)
        let plusBody = ControlIQDisableWarning.body(descriptor: .controlIQPlus)
        #expect(classicBody != plusBody)
        #expect(classicBody.contains("Control-IQ") && !classicBody.contains("Control-IQ+"))
        #expect(plusBody.contains("Control-IQ+"))

        let classicTitle = ControlIQDisableWarning.title(descriptor: .controlIQ)
        let plusTitle = ControlIQDisableWarning.title(descriptor: .controlIQPlus)
        #expect(classicTitle != plusTitle)
    }

    // MARK: descriptor-derived, not a per-variant hardcoded switch — verified by exercising every variant

    @Test func everyControllerVariantResolvesConsistentlyWithItsOwnDescriptor() {
        for variant: ControllerVariant in [.none, .controlIQ, .controlIQPro] {
            let descriptor = ControllerDescriptor.for(variant)
            #expect(ControlIQDisableWarning.shouldWarn(descriptor: descriptor) == descriptor.automaticCorrection.enabled)
            if descriptor.automaticCorrection.enabled {
                #expect(ControlIQDisableWarning.body(descriptor: descriptor).contains(descriptor.displayName))
            }
        }
    }
}
