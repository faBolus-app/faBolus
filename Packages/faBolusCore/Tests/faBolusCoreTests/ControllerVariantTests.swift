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

    /// B2 — the raw values are a FROZEN remote-wire contract (`RemoteCommand.controllerVariant`). This test
    /// fails if a case is renamed in a way that changes its token (which would silently break older remotes).
    /// The marketing name is "Control-IQ+" but the wire token stays `controlIQPro`.
    @Test func rawValuesAreTheFrozenWireContract() {
        #expect(ControllerVariant.none.rawValue == "none")
        #expect(ControllerVariant.controlIQ.rawValue == "controlIQ")
        #expect(ControllerVariant.controlIQPro.rawValue == "controlIQPro")
        // A non-token (e.g. a future rename to the marketing name) must not resolve.
        #expect(ControllerVariant(rawValue: "controlIQPlus") == nil)
        // Every case round-trips through its own raw (a remote decodes with `?? .none`).
        for v in ControllerVariant.allCases { #expect(ControllerVariant(rawValue: v.rawValue) == v) }
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
