import Testing
@testable import faBolusCore

/// P13c-3: typed pump-model identity. `PumpModel` replaces the raw `isMobi` reads left in the app after
/// 13b for the three model-*identity* consumers (fixed-PIN save prompt, backup provenance token, brand
/// copy). Pins the derivation from the snapshot and the identity facts, which are deliberately NOT
/// capability gates (what a pump can do comes from `PumpCapabilities.derive`).
struct PumpModelTests {

    @Test func snapshotDerivesModelFromMobiAndName() {
        var snap = PumpSnapshot()
        #expect(snap.pumpModel == .unknown)          // nothing detected yet
        snap.pumpModelName = "t:slim X2"
        #expect(snap.pumpModel == .tslimX2)          // a name but not Mobi ⇒ t:slim
        snap.isMobi = true
        #expect(snap.pumpModel == .mobi)             // Mobi wins regardless of name
    }

    @Test func onlyMobiHasASavablePairingPin() {
        #expect(PumpModel.mobi.hasSavablePairingPin)
        #expect(!PumpModel.tslimX2.hasSavablePairingPin)
        #expect(!PumpModel.unknown.hasSavablePairingPin)
    }

    @Test func backupTokensAreStableAndDistinct() {
        // These strings are recorded in backup metadata — they must stay stable across UI copy changes.
        #expect(PumpModel.mobi.backupToken == "mobi")
        #expect(PumpModel.tslimX2.backupToken == "tslim")
        #expect(PumpModel.unknown.backupToken == "unknown")
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
}
