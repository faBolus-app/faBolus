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
        // Was 19: the 12 `.unverifiedAck` cases were removed together with `AccessPolicy` Gate 1 and
        // `AppModel.runGatedTherapy` (their sole caller), leaving the 7-case interim set — delivery,
        // childOnly, and the three `.controlInterlock` survivors (suspendDelivery/resumeDelivery held for
        // the ack-suite commit, syncTimeToNow held for the clock-sync commit).
        #expect(GatedPumpWrite.allCases.count == 7)
        for w in GatedPumpWrite.allCases { _ = w.gate }  // exhaustive switch → also proves no crash
    }

    @Test func gatePartitionsMatchTheAppModelFunnels() {
        #expect(names(.ledgeredDelivery) == ["deliverBolus", "deliverExtendedBolus"])
        // Both child-only writes are gated by child mode only (NOT read-only) — cancel is a safety STOP,
        // dismiss is low-risk. This locks the documented gap so a future BolusGate review can't forget it.
        #expect(names(.childOnly) == ["cancelBolus", "dismissNotification"])
        // suspendDelivery/resumeDelivery and syncTimeToNow are the interim survivors (see
        // declaredSetIsStableAndFullyClassified above).
        #expect(names(.controlInterlock) == ["suspendDelivery", "resumeDelivery", "syncTimeToNow"])
        // The partition is total and disjoint.
        let total = names(.ledgeredDelivery).count + names(.childOnly).count + names(.controlInterlock).count
        #expect(total == GatedPumpWrite.allCases.count)
    }

    /// Capability axis: syncTimeToNow declares its own dedicated `supportsTimeSync` capability; the rest
    /// of the `.controlInterlock` set requires any advanced capability; delivery + the child-only pair
    /// require none (so Gate 5 never blocks a bolus).
    @Test func hasRequiredCapabilitySplitsTimeSyncFromTheAdvancedSet() {
        #expect(GatedPumpWrite.syncTimeToNow.hasRequiredCapability(in: .mobiAdvanced))
        #expect(!GatedPumpWrite.syncTimeToNow.hasRequiredCapability(in: .full))  // t:slim: no timeSync
        for a in [GatedPumpWrite.suspendDelivery, .resumeDelivery] {
            #expect(a.hasRequiredCapability(in: .mobiAdvanced))
            #expect(!a.hasRequiredCapability(in: .full), "\(a.rawValue) needs an advanced capability")
        }
        // Never capability-gated — delivery must never be blocked by Gate 5 (no advanced capability).
        for a in [GatedPumpWrite.deliverBolus, .deliverExtendedBolus, .cancelBolus, .dismissNotification] {
            #expect(a.hasRequiredCapability(in: .full), "\(a.rawValue) must never require a capability")
        }
    }
}
