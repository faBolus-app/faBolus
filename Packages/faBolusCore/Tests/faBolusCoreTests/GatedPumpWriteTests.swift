import Testing
@testable import faBolusCore

/// R3-F: the authoritative therapy-write declared set (the seed for phase P8). Pins the enumeration and its
/// gate classification so a new `PumpBackend` write can't be added without a decided gate, and so the
/// app-test `everyTherapyWriteEntryPointIsCentrallyGated` stays in lockstep with the `.unverifiedAck` set.
@Suite struct GatedPumpWriteTests {

    private func names(_ g: GatedPumpWrite.Gate) -> Set<String> {
        Set(GatedPumpWrite.allCases.filter { $0.gate == g }.map(\.rawValue))
    }

    @Test func declaredSetIsStableAndFullyClassified() {
        // Pin the size: adding a reachable pump-write entry point without classifying it here fails visibly.
        #expect(GatedPumpWrite.allCases.count == 37)
        for w in GatedPumpWrite.allCases { _ = w.gate }   // exhaustive switch → also proves no crash
    }

    @Test func gatePartitionsMatchTheAppModelFunnels() {
        #expect(names(.ledgeredDelivery) == ["deliverBolus", "deliverExtendedBolus"])
        // Both child-only writes are gated by child mode only (NOT read-only) — cancel is a safety STOP,
        // dismiss is low-risk. This locks the documented gap so P12's BolusGate review can't forget it.
        #expect(names(.childOnly) == ["cancelBolus", "dismissNotification"])
        #expect(names(.unverifiedAck) == [
            "createProfile", "setActiveProfile", "renameProfile", "deleteProfile",
            "addProfileSegment", "modifyProfileSegment", "deleteProfileSegment", "setCgmHighLowAlert",
        ])
        #expect(names(.controlInterlock).count == 25)
        // The partition is total and disjoint.
        let total = names(.ledgeredDelivery).count + names(.unverifiedAck).count
            + names(.childOnly).count + names(.controlInterlock).count
        #expect(total == GatedPumpWrite.allCases.count)
    }
}
