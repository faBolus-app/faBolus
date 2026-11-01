import Testing
@testable import faBolusCore

/// The pump model and its per-model capability set. The model comes from the advertised name,
/// never the API version, and only a t:slim X2 can receive a dose.
struct PumpModelTests {

    @Test func modelComesFromTheAdvertisedNamePrefix() {
        #expect(PumpModel(advertisedName: "tslim X2 ***693") == .tslimX2)
        #expect(PumpModel(advertisedName: "Tandem Mobi 123456") == .mobi)
        // Anything else is unknown, including a name that merely contains a known one.
        #expect(PumpModel(advertisedName: "") == .unknown)
        #expect(PumpModel(advertisedName: "My tslim X2") == .unknown)
        #expect(PumpModel(advertisedName: "t:slim X2") == .unknown)
    }

    @Test func onlyATslimX2CanReceiveADose() {
        #expect(PumpModel.tslimX2.capabilities.canDeliverBolus)
        #expect(!PumpModel.mobi.capabilities.canDeliverBolus)
        #expect(!PumpModel.unknown.capabilities.canDeliverBolus)
        #expect(PumpState().capabilities == .unknown, "a state with no identified pump offers nothing")
    }

    @Test func eachModelIsACapabilitySetNotASpecialCase() {
        #expect(PumpModel.tslimX2.capabilities == .tslimX2)
        #expect(PumpModel.mobi.capabilities == .mobi)
        #expect(PumpModel.unknown.capabilities == .unknown)
        // Mobi has no screen of its own, so the app must be able to show everything for it.
        #expect(PumpModel.tslimX2.capabilities.hasOwnScreen)
        #expect(!PumpModel.mobi.capabilities.hasOwnScreen)
        // No model offers an extended bolus or alert escalation in this release.
        for model in PumpModel.allCases {
            #expect(!model.capabilities.supportsExtendedBolus)
            #expect(model.capabilities.maxAlertEscalation == .none)
        }
        #expect(PumpModel.unknown.capabilities == PumpCapabilities.unknown)
        #expect(!PumpCapabilities.unknown.supportsCarbEntry)
    }

    @Test func onlyMobiHasAReusablePairingCode() {
        #expect(PumpModel.mobi.capabilities.hasReusablePairingCode)
        #expect(!PumpModel.tslimX2.capabilities.hasReusablePairingCode)
        #expect(!PumpModel.unknown.capabilities.hasReusablePairingCode)
    }

    @Test func displayNameEmptyOnlyWhenUnknown() {
        #expect(PumpModel.mobi.displayName == "Mobi")
        #expect(PumpModel.tslimX2.displayName == "t:slim X2")
        #expect(PumpModel.unknown.displayName.isEmpty)
    }

    @Test func bothCurrentModelsAreTandem() {
        #expect(PumpModel.mobi.manufacturer == "Tandem Diabetes Care")
        #expect(PumpModel.tslimX2.manufacturer == "Tandem Diabetes Care")
    }

    @Test func rawValuesAreStable() {
        // Stored with the pairing, so a rename must not change them.
        #expect(PumpModel.tslimX2.rawValue == "tslimX2")
        #expect(PumpModel.mobi.rawValue == "mobi")
        #expect(PumpModel.unknown.rawValue == "unknown")
    }
}
