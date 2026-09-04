import Testing
@testable import faBolusCore

/// `PumpCapabilities.derive(isMobi:features:)` re-sources capabilities from the pump's own
/// `PumpFeaturesV1` bitmask instead of inferring everything from one `isMobi` boolean. These pin the
/// safety contract that makes it shippable without hardware: **absent features ⇒ the exact model
/// preset** (pure fallback), and **present features can only NARROW, never widen** the preset.
struct PumpCapabilitiesDeriveTests {

    // MARK: - Fallback: no features yet ⇒ identical to the model preset

    @Test func absentFeaturesEqualsTheModelPreset() {
        // Mobi with no PumpFeaturesV1 response yet is byte-identical to `.mobiAdvanced` + the
        // t:slim-only remote-dismiss quirk (dismiss honored on Mobi).
        var mobi = PumpCapabilities.mobiAdvanced
        mobi.supportsRemoteAlertDismiss = true
        #expect(PumpCapabilities.derive(isMobi: true, features: nil) == mobi)

        var tslim = PumpCapabilities.full
        tslim.supportsRemoteAlertDismiss = false  // t:slim silently rejects remote dismissal
        #expect(PumpCapabilities.derive(isMobi: false, features: nil) == tslim)
    }

    // MARK: - Present features agree with the preset ⇒ no change

    @Test func fullyCapableMobiKeepsAllAdvancedControl() {
        let f = PumpFeatureBits(
            controlIQSupported: true, basalLimitSupported: true,
            blePumpControlSupported: true)
        let caps = PumpCapabilities.derive(isMobi: true, features: f)
        #expect(caps.supportsAnyAdvancedControl)
        #expect(caps.supportsControlIQSettings)
        #expect(caps.supportsLimits)
        #expect(caps.supportsModes)  // preserved from the .mobiAdvanced floor
        #expect(caps.supportsRemoteAlertDismiss)
    }

    // MARK: - Narrowing

    @Test func noBlePumpControlDisablesAllAdvancedControl() {
        // A pump that can't be BLE-controlled: even a Mobi preset collapses to no advanced control.
        let f = PumpFeatureBits(
            controlIQSupported: true, basalLimitSupported: true,
            blePumpControlSupported: false)
        let caps = PumpCapabilities.derive(isMobi: true, features: f)
        #expect(!caps.supportsAnyAdvancedControl)
        #expect(!caps.supportsModes)
        #expect(!caps.supportsControlIQSettings)
        #expect(!caps.supportsLimits)
        // Non-advanced base capabilities are untouched (bolus/status/pairing still work).
        #expect(caps.supportsCarbEntry)
        #expect(caps.supportsBolusCancel)
    }

    @Test func noControlIQNarrowsOnlyControlIQSettings() {
        let f = PumpFeatureBits(
            controlIQSupported: false, basalLimitSupported: true,
            blePumpControlSupported: true)
        let caps = PumpCapabilities.derive(isMobi: true, features: f)
        #expect(!caps.supportsControlIQSettings)  // narrowed off
        #expect(caps.supportsLimits)  // untouched
        #expect(caps.supportsModes)  // untouched
    }

    @Test func noBasalLimitNarrowsOnlyLimits() {
        let f = PumpFeatureBits(
            controlIQSupported: true, basalLimitSupported: false,
            blePumpControlSupported: true)
        let caps = PumpCapabilities.derive(isMobi: true, features: f)
        #expect(!caps.supportsLimits)  // narrowed off
        #expect(caps.supportsControlIQSettings)  // untouched
    }

    // MARK: - Temp-rate gate: capability, never a pump-model check

    /// The temp-rate surfacing gate reads
    /// `PumpCapabilities.supportsTempBasal` — a DERIVED capability, never a hardcoded pump-model/`isMobi`
    /// check. Proven in both directions: a capability set with `supportsTempBasal == false` (`.full`,
    /// the t:slim-style floor) reports the gate CLOSED, while one with `supportsTempBasal == true`
    /// (`.mobiAdvanced`, the connected MockBackend's preset) reports it OPEN.
    @Test func tempRateGateKeysOnCapabilityNotPumpModel() {
        #expect(!PumpCapabilities.full.supportsTempBasal)  // gate closed: no temp-rate capability
        #expect(PumpCapabilities.mobiAdvanced.supportsTempBasal)  // gate open: capability present
    }

    // MARK: - supportsExtendedBolus: a bolus capability, independent of advanced control

    /// Extended (combo) bolus is a BOLUS capability — available even on a t:slim (`.full`) that advertises
    /// no advanced control, and never stripped when advanced control is narrowed off. Kept because these
    /// are the only assertions in faBolusCore on `capabilities.supportsExtendedBolus`, the live flag
    /// `AppModel` reads to decide bolus eligibility; relocated here so they outlive the PumpControlBounds
    /// test file.
    @Test func extendedBolusIsABolusCapabilityIndependentOfAdvancedControl() {
        // Available on t:slim (`.full`) even though `.full` advertises NO advanced control.
        #expect(PumpCapabilities.full.supportsExtendedBolus)
        #expect(PumpCapabilities.mobiAdvanced.supportsExtendedBolus)
        // Narrowing advanced control off (pump reports no BLE pump control) must NOT strip extended bolus —
        // it's a bolus, not an advanced-control write.
        let narrowed = PumpCapabilities.derive(isMobi: true, features: PumpFeatureBits(blePumpControlSupported: false))
        #expect(narrowed.supportsExtendedBolus)
    }

    // MARK: - supportsSleepScheduleWrite: a NEW dedicated Mobi-only write-gate capability
    // Deliberately NOT folded into supportsControlIQSettings; the read
    // (PumpBackend.refreshSleepSchedule / PumpSnapshot.sleepSchedules) is universal/ungated and is
    // proven separately at the UI layer, never behind this flag.

    @Test func supportsSleepScheduleWriteDefaultsFalse() {
        #expect(PumpCapabilities().supportsSleepScheduleWrite == false)
    }

    @Test func mobiAdvancedSupportsSleepScheduleWrite() {
        #expect(PumpCapabilities.mobiAdvanced.supportsSleepScheduleWrite == true)
    }

    @Test func deriveMobiWithBleControlSupportsSleepScheduleWrite() {
        let f = PumpFeatureBits(
            controlIQSupported: true, basalLimitSupported: true,
            blePumpControlSupported: true)
        #expect(PumpCapabilities.derive(isMobi: true, features: f).supportsSleepScheduleWrite)
    }

    @Test func deriveTslimNeverSupportsSleepScheduleWrite() {
        // t:slim: no schedule write, even with the identical (rich) feature bitmask a Mobi would have.
        let f = PumpFeatureBits(
            controlIQSupported: true, basalLimitSupported: true,
            blePumpControlSupported: true)
        #expect(!PumpCapabilities.derive(isMobi: false, features: f).supportsSleepScheduleWrite)
    }

    @Test func deriveNoBleControlNarrowsOffSleepScheduleWrite() {
        // Narrowed off with the rest of advanced control when the pump can't be BLE-controlled at all.
        let f = PumpFeatureBits(
            controlIQSupported: true, basalLimitSupported: true,
            blePumpControlSupported: false)
        #expect(!PumpCapabilities.derive(isMobi: true, features: f).supportsSleepScheduleWrite)
    }

    // MARK: - PumpSleepScheduleSlot: neutral 5-field projection (decode-boundary discipline)

    @Test func pumpSleepScheduleSlotRoundTripsAndIdMatchesSlot() {
        let a = PumpSleepScheduleSlot(
            slot: 2, enabled: true, activeDays: 0x1F,
            startMinute: 1320, endMinute: 360)
        let b = PumpSleepScheduleSlot(
            slot: 2, enabled: true, activeDays: 0x1F,
            startMinute: 1320, endMinute: 360)
        #expect(a == b)
        #expect(a.id == a.slot)
        #expect(
            a.slot == 2 && a.enabled && a.activeDays == 0x1F
                && a.startMinute == 1320 && a.endMinute == 360)
    }

    // MARK: - Never-widen invariant (the core safety property)

    @Test func featuresCanNeverWidenBeyondTheModelPreset() {
        // A t:slim (.full floor: all advanced OFF) that reports every feature bit set must STILL have
        // no advanced control — faBolus offers BLE pump control only on the Mobi surface, so a rich
        // bitmask can never conjure an affordance the model preset withheld.
        let allBits = PumpFeatureBits(
            controlIQSupported: true, basalLimitSupported: true,
            blePumpControlSupported: true)
        let tslim = PumpCapabilities.derive(isMobi: false, features: allBits)
        #expect(!tslim.supportsAnyAdvancedControl)
        #expect(!tslim.supportsControlIQSettings)
        #expect(!tslim.supportsLimits)

        // General form: for every model + feature combination, each advanced flag of the result is a
        // subset of the corresponding preset flag (⇒ derive never sets a flag the preset had false).
        for isMobi in [true, false] {
            let preset = isMobi ? PumpCapabilities.mobiAdvanced : PumpCapabilities.full
            for ciq in [true, false] {
                for lim in [true, false] {
                    for ble in [true, false] {
                        let caps = PumpCapabilities.derive(
                            isMobi: isMobi,
                            features: PumpFeatureBits(
                                controlIQSupported: ciq, basalLimitSupported: lim,
                                blePumpControlSupported: ble))
                        #expect(!(caps.supportsControlIQSettings && !preset.supportsControlIQSettings))
                        #expect(!(caps.supportsLimits && !preset.supportsLimits))
                        #expect(!(caps.supportsModes && !preset.supportsModes))
                        #expect(!(caps.supportsTempBasal && !preset.supportsTempBasal))
                        #expect(!(caps.supportsSuspendResume && !preset.supportsSuspendResume))
                    }
                }
            }
        }
    }
}
