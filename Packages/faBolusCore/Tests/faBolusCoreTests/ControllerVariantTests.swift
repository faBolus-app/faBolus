import Testing
@testable import faBolusCore

/// P13c-2: the Control-IQ vs Control-IQ+ discriminator. `PumpFeatureBits.controllerVariant` classifies
/// the pump's own `PumpFeaturesV1` bits into `.none` / `.controlIQ` / `.controlIQPro` — the axis the
/// controller descriptor (13c) will select content from. Pins the mapping and the "Pro implies CIQ" rule.
struct ControllerVariantTests {

    @Test func noControlIQBitMeansNone() {
        // No CIQ support ⇒ .none, even if the Pro bit is (nonsensically) set on its own.
        #expect(PumpFeatureBits(controlIQSupported: false).controllerVariant == .none)
        #expect(PumpFeatureBits(controlIQSupported: false, controlIQProSupported: true).controllerVariant == .none)
    }

    @Test func controlIQWithoutProIsClassic() {
        #expect(PumpFeatureBits(controlIQSupported: true, controlIQProSupported: false).controllerVariant == .controlIQ)
    }

    @Test func proBitUpgradesToControlIQPro() {
        #expect(PumpFeatureBits(controlIQSupported: true, controlIQProSupported: true).controllerVariant == .controlIQPro)
    }

    @Test func defaultBitsAreNone() {
        // A freshly-defaulted PumpFeatureBits (the "pump told us nothing" state) has no controller.
        #expect(PumpFeatureBits().controllerVariant == .none)
    }

    @Test func proDoesNotAlterTheDerivedCapabilitySet() {
        // The Pro bit is controller IDENTITY, not a capability gate: adding it must NOT widen or narrow
        // the derived capabilities (that stays governed by the CIQ / basal-limit / BLE-control bits).
        let base = PumpFeatureBits(controlIQSupported: true, basalLimitSupported: true, blePumpControlSupported: true)
        var pro = base; pro.controlIQProSupported = true
        #expect(PumpCapabilities.derive(isMobi: true, features: base)
                == PumpCapabilities.derive(isMobi: true, features: pro))
    }
}
