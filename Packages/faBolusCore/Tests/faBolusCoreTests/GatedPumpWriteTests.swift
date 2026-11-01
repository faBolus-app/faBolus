import Testing
@testable import faBolusCore

/// The declared set of consequential pump writes. Pins the enumeration and its gate classification so a
/// write can't be added without a decided gate.
@Suite struct GatedPumpWriteTests {

    private func names(_ g: GatedPumpWrite.Gate) -> Set<String> {
        Set(GatedPumpWrite.allCases.filter { $0.gate == g }.map(\.rawValue))
    }

    @Test func declaredSetIsStableAndFullyClassified() {
        // Pin the size: adding a reachable pump-write entry point without classifying it here fails visibly.
        #expect(GatedPumpWrite.allCases.count == 4)
        for w in GatedPumpWrite.allCases { _ = w.gate }  // exhaustive switch → also proves no crash
    }

    @Test func gatePartitionsMatchTheFunnels() {
        #expect(names(.ledgeredDelivery) == ["deliverBolus", "deliverExtendedBolus"])
        // Cancel is a safety stop and dismiss is low-risk: neither is ever blocked by a gate.
        #expect(names(.alwaysAllowed) == ["cancelBolus", "dismissNotification"])
        // The partition is total and disjoint.
        #expect(names(.ledgeredDelivery).count + names(.alwaysAllowed).count == GatedPumpWrite.allCases.count)
    }

    /// Only delivery needs a capability; cancel and dismiss never do, on any model.
    @Test func onlyDeliveryNeedsACapability() {
        for caps in [PumpCapabilities.tslimX2, .mobi, .unknown] {
            #expect(GatedPumpWrite.cancelBolus.hasRequiredCapability(in: caps))
            #expect(GatedPumpWrite.dismissNotification.hasRequiredCapability(in: caps))
        }
        #expect(GatedPumpWrite.deliverBolus.hasRequiredCapability(in: .tslimX2))
        #expect(!GatedPumpWrite.deliverBolus.hasRequiredCapability(in: .mobi))
        #expect(!GatedPumpWrite.deliverBolus.hasRequiredCapability(in: .unknown))
        #expect(!GatedPumpWrite.deliverExtendedBolus.hasRequiredCapability(in: .tslimX2))
    }
}
