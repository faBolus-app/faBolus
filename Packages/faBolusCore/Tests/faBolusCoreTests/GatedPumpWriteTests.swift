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
            // P14 S6: the therapy-defining writes that previously bypassed the ack.
            "setControlIQ", "setMaxBolus", "setMaxBasal",
        ])
        #expect(names(.controlInterlock).count == 22)   // P14 S6: was 25, three moved to .unverifiedAck
        // The partition is total and disjoint.
        let total = names(.ledgeredDelivery).count + names(.unverifiedAck).count
            + names(.childOnly).count + names(.controlInterlock).count
        #expect(total == GatedPumpWrite.allCases.count)
    }

    /// P13 opt-in axis: `requiresAdvancedControlOptIn` must match, exactly, the set of actions the app
    /// reaches ONLY behind `advancedControlAllowed` — verified against the live UI 2026-08-05 — so
    /// routing it through the funnel changes no shipped t:slim behavior. The one trap this pins:
    /// `syncTimeToNow` is reachable on Mobi from Settings WITHOUT the opt-in, so it must be EXCLUDED, or
    /// the funnel would regress Mobi time-sync.
    @Test func requiresAdvancedControlOptInMatchesTheOptInGatedSet() {
        // Never opt-in-gated: delivery + the child-only pair.
        for a in [GatedPumpWrite.deliverBolus, .deliverExtendedBolus, .cancelBolus, .dismissNotification] {
            #expect(!a.requiresAdvancedControlOptIn, "\(a.rawValue) must not require the advanced opt-in")
        }
        // The deliberate exclusion — Settings → Pump clock reaches this on Mobi without the opt-in.
        #expect(!GatedPumpWrite.syncTimeToNow.requiresAdvancedControlOptIn,
                "syncTimeToNow is capability-gated (supportsTimeSync), NOT opt-in-gated — must be excluded")
        // Every other control / unverified-ack write DOES require it (opt-in-gated in the UI).
        let advanced = Set(GatedPumpWrite.allCases.filter { $0.requiresAdvancedControlOptIn }.map(\.rawValue))
        let expected = names(.controlInterlock).union(names(.unverifiedAck)).subtracting(["syncTimeToNow"])
        #expect(advanced == expected)
        #expect(!advanced.contains("syncTimeToNow"))
        // Sanity on the count: 22 controlInterlock + 11 unverifiedAck − 1 (syncTimeToNow) = 32. (P14 S6
        // moved 3 writes between the two gates; the opt-in-gated UNION is unchanged, so the total holds.)
        #expect(advanced.count == 32)
    }

    /// P13 capability axis: `hasRequiredCapability` is the split-out counterpart. syncTimeToNow declares
    /// `supportsTimeSync` (removing the old special-case); the advanced writes require any advanced
    /// capability; delivery + the child-only pair require none (so Gate 5 never blocks a bolus).
    @Test func hasRequiredCapabilitySplitsTimeSyncFromTheAdvancedSet() {
        #expect(GatedPumpWrite.syncTimeToNow.hasRequiredCapability(in: .mobiAdvanced))
        #expect(!GatedPumpWrite.syncTimeToNow.hasRequiredCapability(in: .full))   // t:slim: no timeSync
        for a in [GatedPumpWrite.setTempBasal, .suspendDelivery, .setMode, .setControlIQ] {
            #expect(a.hasRequiredCapability(in: .mobiAdvanced))
            #expect(!a.hasRequiredCapability(in: .full), "\(a.rawValue) needs an advanced capability")
        }
        // Never capability-gated — delivery must never be blocked by Gate 5 (no advanced capability).
        for a in [GatedPumpWrite.deliverBolus, .deliverExtendedBolus, .cancelBolus, .dismissNotification] {
            #expect(a.hasRequiredCapability(in: .full), "\(a.rawValue) must never require a capability")
        }
    }
}
