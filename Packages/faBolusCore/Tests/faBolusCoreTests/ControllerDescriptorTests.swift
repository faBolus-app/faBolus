import Testing
@testable import faBolusCore

/// P13c-3: the controller descriptor as data. Pins that `ControllerDescriptor.for(variant)` maps each
/// `ControllerVariant` to the right §2.4 behavior — including the one clinical difference the CIQ/CIQ+
/// discriminator exists to render (auto-corrections during Sleep) — and that a no-controller pump (DASH)
/// renders nothing controller-specific. These values are §13 clinical-review-gated; the tests pin the
/// *shape and the discriminator*, not a clinical claim.
struct ControllerDescriptorTests {

    // MARK: no controller (Omnipod DASH / CIQ-off / non-Tandem)

    @Test func noControllerIsInert() {
        let d = ControllerDescriptor.for(.none)
        #expect(!d.hasController)
        #expect(d.displayName.isEmpty)
        #expect(!d.automaticCorrection.enabled)
        #expect(d.activityPresets.isEmpty)
        #expect(d.drivingParameters.isEmpty)
        #expect(!d.targetsUserAdjustable)
        #expect(d.basalModulation == .none)
    }

    // MARK: Control-IQ (classic)

    @Test func controlIQCarriesTheFiveFields() {
        let d = ControllerDescriptor.for(.controlIQ)
        #expect(d.variant == .controlIQ)
        #expect(d.hasController)
        #expect(d.displayName == "Control-IQ")
        // Field 1: auto-correction 60% toward 110, ≤ once/60 min, blocked by a bolus in the prior 60 min.
        #expect(d.automaticCorrection.enabled)
        #expect(d.automaticCorrection.deliveredFraction == 0.60)
        #expect(d.automaticCorrection.targetMgdl == 110)
        #expect(d.automaticCorrection.minIntervalMinutes == 60)
        #expect(d.automaticCorrection.blockedByRecentBolusMinutes == 60)
        // Field 2: Sleep 112.5–120, Exercise 140–160 (suspend raised).
        let sleep = d.activityPresets.first { $0.name == "Sleep" }
        let exercise = d.activityPresets.first { $0.name == "Exercise" }
        #expect(sleep?.targetLowMgdl == 112.5 && sleep?.targetHighMgdl == 120)
        #expect(exercise?.targetLowMgdl == 140 && exercise?.targetHighMgdl == 160)
        #expect(exercise?.suspendThresholdMgdl == 79)
        // Field 3: seeded by weight + TDI on top of the programmed profile.
        #expect(d.drivingParameters.contains(.bodyWeight))
        #expect(d.drivingParameters.contains(.totalDailyInsulin))
        // Field 4: target NOT user-adjustable. Field 5: modulates relative to the profile.
        #expect(!d.targetsUserAdjustable)
        if case .relativeToProfile = d.basalModulation {} else { Issue.record("expected relativeToProfile") }
    }

    @Test func classicControlIQDisablesAutoCorrectionDuringSleep() {
        // The discriminator's clinical meaning: classic Control-IQ does NOT auto-correct during Sleep.
        let sleep = ControllerDescriptor.for(.controlIQ).activityPresets.first { $0.name == "Sleep" }
        #expect(sleep?.automaticCorrectionEnabled == false)
    }

    // MARK: Control-IQ+ (Pro) — the discriminator

    @Test func controlIQPlusKeepsAutoCorrectionDuringSleep() {
        // Control-IQ+ is identical to classic EXCEPT it auto-corrects during Sleep — the one behavior the
        // CIQ/CIQ+ discriminator (O7) must render differently.
        let plus = ControllerDescriptor.for(.controlIQPro)
        #expect(plus.variant == .controlIQPro)
        #expect(plus.displayName == "Control-IQ+")
        let sleep = plus.activityPresets.first { $0.name == "Sleep" }
        #expect(sleep?.automaticCorrectionEnabled == true)
        // Everything else matches classic (same fraction/target/interval).
        #expect(plus.automaticCorrection.deliveredFraction == 0.60)
        #expect(plus.automaticCorrection.targetMgdl == 110)
    }

    @Test func onlyTheSleepAutoCorrectionDiffersBetweenClassicAndPlus() {
        // Guard the discriminator: the two descriptors differ ONLY in the Sleep preset's auto-correction
        // flag. If a future edit diverges another field, this fails and forces the change to be deliberate.
        let classic = ControllerDescriptor.for(.controlIQ)
        let plus = ControllerDescriptor.for(.controlIQPro)
        #expect(classic.automaticCorrection == plus.automaticCorrection)
        #expect(classic.drivingParameters == plus.drivingParameters)
        #expect(classic.targetsUserAdjustable == plus.targetsUserAdjustable)
        #expect(classic.basalModulation == plus.basalModulation)
        let cExercise = classic.activityPresets.first { $0.name == "Exercise" }
        let pExercise = plus.activityPresets.first { $0.name == "Exercise" }
        #expect(cExercise == pExercise)  // Exercise identical
    }

    // MARK: variant/descriptor plumbing

    @Test func featureBitsVariantSelectsTheDescriptor() {
        // The pump's own bits pick the descriptor end-to-end: bits → controllerVariant → descriptor.
        #expect(PumpFeatureBits(controlIQSupported: false).controllerVariant == .none)
        #expect(
            ControllerDescriptor.for(PumpFeatureBits(controlIQSupported: false).controllerVariant)
                == .noController)
        #expect(
            ControllerDescriptor.for(
                PumpFeatureBits(controlIQSupported: true, controlIQProSupported: true).controllerVariant)
                == .controlIQPlus)
    }

    @Test func snapshotExposesTheDescriptorForItsVariant() {
        var snap = PumpSnapshot()
        #expect(snap.controllerDescriptor == .noController)  // default .none
        snap.controllerVariant = .controlIQPro
        #expect(snap.controllerDescriptor == .controlIQPlus)
        #expect(snap.controllerDescriptor.hasController)
    }

    /// C1 (§2.4) — `controlIQBrandName` renders the exact variant when known and the GENERIC "Control-IQ"
    /// as a fallback for the pre-op-79 window (variant still `.none`, `displayName == ""`), so a
    /// Control-IQ-capability-gated section never shows a blank brand.
    @Test func controlIQBrandNameNamesTheVariantWithAGenericFallback() {
        var snap = PumpSnapshot()
        #expect(snap.controlIQBrandName == "Control-IQ")  // .none ⇒ generic fallback (never "")
        snap.controllerVariant = .controlIQ
        #expect(snap.controlIQBrandName == "Control-IQ")
        snap.controllerVariant = .controlIQPro
        #expect(snap.controlIQBrandName == "Control-IQ+")  // the exact variant when known
        #expect(!snap.controlIQBrandName.isEmpty)
    }
}
