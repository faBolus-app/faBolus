import Testing
@testable import faBolusCore

/// The authoritative therapy-write declared set. Pins the enumeration and its
/// gate classification so a new `PumpBackend` write can't be added without a decided gate. The standing
/// enforcement that `AppModel`'s actual write surface stays in lockstep with this declared set is the
/// app-test `PumpWriteFunnelGuardTests` (a source-text scan, not a table over this enum).
@Suite struct GatedPumpWriteTests {

    private func names(_ g: GatedPumpWrite.Gate) -> Set<String> {
        Set(GatedPumpWrite.allCases.filter { $0.gate == g }.map(\.rawValue))
    }

    @Test func declaredSetIsStableAndFullyClassified() {
        // Pin the size: adding a reachable pump-write entry point without classifying it here fails visibly.
        // Was 5: the pump clock-sync write (`syncTimeToNow`) — the single surviving `.controlInterlock`
        // case, gated on its own dedicated `supportsTimeSync` capability — was retired together with that
        // capability and its three backend implementations, leaving the FINAL FOUR-case settled set:
        // the two ledgered deliveries and the two child-only writes. `.controlInterlock` now has no
        // member at all.
        #expect(GatedPumpWrite.allCases.count == 4)
        for w in GatedPumpWrite.allCases { _ = w.gate }  // exhaustive switch → also proves no crash
    }

    @Test func gatePartitionsMatchTheAppModelFunnels() {
        #expect(names(.ledgeredDelivery) == ["deliverBolus", "deliverExtendedBolus"])
        // Both child-only writes are gated by child mode only (NOT read-only) — cancel is a safety STOP,
        // dismiss is low-risk. This locks the documented gap so a future BolusGate review can't forget it.
        #expect(names(.childOnly) == ["cancelBolus", "dismissNotification"])
        // `.controlInterlock` has no surviving member — its last case (syncTimeToNow) retired with the
        // pump clock-sync write. Pinning it empty (rather than deleting the assertion) keeps the
        // partition-is-total-and-disjoint check below meaningful for whatever `.controlInterlock` case
        // is added next.
        #expect(names(.controlInterlock).isEmpty)
        // The partition is total and disjoint.
        let total = names(.ledgeredDelivery).count + names(.childOnly).count + names(.controlInterlock).count
        #expect(total == GatedPumpWrite.allCases.count)
    }

    /// Capability axis: with `syncTimeToNow` retired, none of the four surviving cases require a
    /// capability — Gate 5's capability axis has no denial subject left (delivery + the child-only
    /// pair were always capability-exempt so a bolus is never blocked).
    @Test func hasRequiredCapabilityNeverBlocksAnySurvivingCase() {
        for a in GatedPumpWrite.allCases {
            #expect(a.hasRequiredCapability(in: .full), "\(a.rawValue) must never require a capability")
        }
    }
}
