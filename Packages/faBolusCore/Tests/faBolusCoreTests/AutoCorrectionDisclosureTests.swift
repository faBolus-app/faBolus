import Testing
@testable import faBolusCore

/// P16 S1 + O3: pure disclosure of the pump controller's documented automatic-correction behavior. Pins
/// the mechanism gate (both strings vanish for a no-controller pump and when the controller is toggled off
/// at runtime), the S1 high/rising trigger boundaries, and that the copy is derived from the descriptor's
/// own `displayName` + lockout number (never a hardcoded brand). These functions NEVER affect delivery —
/// they return a string to show or nil, nothing else.
struct AutoCorrectionDisclosureTests {

    // A capable, enabled controller with a known lockout window and a hypothetical non-Tandem brand — used
    // to prove the copy derives from `displayName` rather than a hardcoded "Control-IQ".
    private let hypothetical = ControllerDescriptor(
        variant: .controlIQ, displayName: "Acme Loop",
        automaticCorrection: AutomaticCorrection(enabled: true, blockedByRecentBolusMinutes: 45),
        activityPresets: [], drivingParameters: [],
        targetsUserAdjustable: false, basalModulation: .none)

    // MARK: no controller — both strings are always nil, whatever the glucose/trend

    @Test func noControllerNeverDiscloses() {
        let d = ControllerDescriptor.noController
        #expect(AutoCorrectionDisclosure.lockoutMessage(descriptor: d, controllerEnabled: true,
                                                        glucoseMgdl: 300, trend: .upUp) == nil)
        #expect(AutoCorrectionDisclosure.ambientIndicator(descriptor: d, controllerEnabled: true) == nil)
    }

    // MARK: capable controller turned OFF at runtime — both nil

    @Test func controllerDisabledAtRuntimeNeverDiscloses() {
        let d = ControllerDescriptor.controlIQ
        #expect(AutoCorrectionDisclosure.lockoutMessage(descriptor: d, controllerEnabled: false,
                                                        glucoseMgdl: 250, trend: .up) == nil)
        #expect(AutoCorrectionDisclosure.ambientIndicator(descriptor: d, controllerEnabled: false) == nil)
    }

    // MARK: S1 trigger boundaries

    @Test func highFlatGlucoseDisclosesLockout() {
        // 185 flat: at/above the always-disclose threshold, trend irrelevant.
        let msg = AutoCorrectionDisclosure.lockoutMessage(descriptor: .controlIQ, controllerEnabled: true,
                                                          glucoseMgdl: 185, trend: .flat)
        #expect(msg != nil)
    }

    @Test func risingElevatedGlucoseDisclosesLockout() {
        // 160 rising: below 180 but at/above the rising threshold AND the pump's arrow is rising.
        let msg = AutoCorrectionDisclosure.lockoutMessage(descriptor: .controlIQ, controllerEnabled: true,
                                                          glucoseMgdl: 160, trend: .rising)
        #expect(msg != nil)
    }

    @Test func elevatedButFlatDoesNotDisclose() {
        // 160 flat: elevated but not rising and below 180 → no lockout disclosure.
        #expect(AutoCorrectionDisclosure.lockoutMessage(descriptor: .controlIQ, controllerEnabled: true,
                                                        glucoseMgdl: 160, trend: .flat) == nil)
    }

    @Test func belowRisingThresholdEvenWhenRisingDoesNotDisclose() {
        // 149 rising: below the rising threshold → no lockout disclosure.
        #expect(AutoCorrectionDisclosure.lockoutMessage(descriptor: .controlIQ, controllerEnabled: true,
                                                        glucoseMgdl: 149, trend: .rising) == nil)
    }

    @Test func upAndUpUpArrowsAlsoCountAsRising() {
        // The rising set is the pump's own ↑/⇈/↗ arrows — all trigger at the rising threshold.
        #expect(AutoCorrectionDisclosure.lockoutMessage(descriptor: .controlIQ, controllerEnabled: true,
                                                        glucoseMgdl: 155, trend: .up) != nil)
        #expect(AutoCorrectionDisclosure.lockoutMessage(descriptor: .controlIQ, controllerEnabled: true,
                                                        glucoseMgdl: 155, trend: .upUp) != nil)
        // Falling at the same elevated value must NOT disclose (only rising does).
        #expect(AutoCorrectionDisclosure.lockoutMessage(descriptor: .controlIQ, controllerEnabled: true,
                                                        glucoseMgdl: 155, trend: .falling) == nil)
    }

    @Test func absentGlucoseSuppressesLockoutButAmbientStillShows() {
        // O3 is glucose-independent; S1 needs a reading.
        #expect(AutoCorrectionDisclosure.lockoutMessage(descriptor: .controlIQ, controllerEnabled: true,
                                                        glucoseMgdl: nil, trend: .rising) == nil)
        #expect(AutoCorrectionDisclosure.ambientIndicator(descriptor: .controlIQ, controllerEnabled: true) != nil)
    }

    // MARK: copy derives from the descriptor (no hardcoded brand / lockout number)

    @Test func lockoutCopyUsesDescriptorDisplayNameNotHardcodedBrand() {
        let ciq = AutoCorrectionDisclosure.lockoutMessage(descriptor: .controlIQ, controllerEnabled: true,
                                                          glucoseMgdl: 200, trend: .flat)
        #expect(ciq?.contains("Control-IQ") == true)   // real classic descriptor's displayName
        let plus = AutoCorrectionDisclosure.lockoutMessage(descriptor: .controlIQPlus, controllerEnabled: true,
                                                           glucoseMgdl: 200, trend: .flat)
        #expect(plus?.contains("Control-IQ+") == true)   // real Pro descriptor's displayName
        // A hypothetical non-Tandem controller: the copy must reflect ITS name and NOT any hardcoded
        // "Control-IQ" literal — proving the message is derived from `displayName`.
        let custom = AutoCorrectionDisclosure.lockoutMessage(descriptor: hypothetical, controllerEnabled: true,
                                                             glucoseMgdl: 200, trend: .flat)
        #expect(custom?.contains("Acme Loop") == true)
        #expect(custom?.contains("Control-IQ") == false)
    }

    @Test func ambientCopyUsesDescriptorDisplayName() {
        #expect(AutoCorrectionDisclosure.ambientIndicator(descriptor: .controlIQ,
                                                          controllerEnabled: true)?.contains("Control-IQ") == true)
        let custom = AutoCorrectionDisclosure.ambientIndicator(descriptor: hypothetical, controllerEnabled: true)
        #expect(custom?.contains("Acme Loop") == true)
        #expect(custom?.contains("Control-IQ") == false)
    }

    @Test func lockoutTextStatesTheDescriptorsOwnLockoutWindow() {
        // The disclosed window is the descriptor's own `blockedByRecentBolusMinutes` (60 for CIQ, 45 for the
        // hypothetical) — not a number restated in the disclosure code.
        let ciq = AutoCorrectionDisclosure.lockoutMessage(descriptor: .controlIQ, controllerEnabled: true,
                                                          glucoseMgdl: 200, trend: .flat)
        #expect(ciq?.contains("60 min") == true)
        #expect(ControllerDescriptor.controlIQ.automaticCorrection.blockedByRecentBolusMinutes == 60)
        let custom = AutoCorrectionDisclosure.lockoutMessage(descriptor: hypothetical, controllerEnabled: true,
                                                             glucoseMgdl: 200, trend: .flat)
        #expect(custom?.contains("45 min") == true)
    }
}
