import Testing
@testable import faBolusCore

/// The authoritative therapy-write declared set. Pins the enumeration and its
/// gate classification so a new `PumpBackend` write can't be added without a decided gate, and so the
/// app-test `everyTherapyWriteEntryPointIsCentrallyGated` stays in lockstep with the `.unverifiedAck` set.
@Suite struct GatedPumpWriteTests {

    private func names(_ g: GatedPumpWrite.Gate) -> Set<String> {
        Set(GatedPumpWrite.allCases.filter { $0.gate == g }.map(\.rawValue))
    }

    @Test func declaredSetIsStableAndFullyClassified() {
        // Pin the size: adding a reachable pump-write entry point without classifying it here fails visibly.
        #expect(GatedPumpWrite.allCases.count == 38)
        for w in GatedPumpWrite.allCases { _ = w.gate }  // exhaustive switch → also proves no crash
    }

    @Test func gatePartitionsMatchTheAppModelFunnels() {
        #expect(names(.ledgeredDelivery) == ["deliverBolus", "deliverExtendedBolus"])
        // Both child-only writes are gated by child mode only (NOT read-only) — cancel is a safety STOP,
        // dismiss is low-risk. This locks the documented gap so a future BolusGate review can't forget it.
        #expect(names(.childOnly) == ["cancelBolus", "dismissNotification"])
        #expect(
            names(.unverifiedAck) == [
                "createProfile", "setActiveProfile", "renameProfile", "deleteProfile",
                "addProfileSegment", "modifyProfileSegment", "deleteProfileSegment", "setCgmHighLowAlert",
                // The therapy-defining writes that previously bypassed the ack.
                "setControlIQ", "setMaxBolus", "setMaxBasal",
                // The Mobi native Sleep-schedule write — flag semantics + slots 1-3 unverified.
                "setSleepSchedule"
            ])
        #expect(names(.controlInterlock).count == 22)  // was 25, three moved to .unverifiedAck
        // The partition is total and disjoint.
        let total =
            names(.ledgeredDelivery).count + names(.unverifiedAck).count
            + names(.childOnly).count + names(.controlInterlock).count
        #expect(total == GatedPumpWrite.allCases.count)
    }

    /// Capability axis: `hasRequiredCapability` is the split-out counterpart. syncTimeToNow declares
    /// `supportsTimeSync` (removing the old special-case); the advanced writes require any advanced
    /// capability; delivery + the child-only pair require none (so Gate 5 never blocks a bolus).
    @Test func hasRequiredCapabilitySplitsTimeSyncFromTheAdvancedSet() {
        #expect(GatedPumpWrite.syncTimeToNow.hasRequiredCapability(in: .mobiAdvanced))
        #expect(!GatedPumpWrite.syncTimeToNow.hasRequiredCapability(in: .full))  // t:slim: no timeSync
        // setSleepSchedule declares its OWN dedicated capability (supportsSleepScheduleWrite),
        // not the coarse supportsAnyAdvancedControl set — mirrors the pump protocol's own MOBI_ONLY scope.
        #expect(GatedPumpWrite.setSleepSchedule.hasRequiredCapability(in: .mobiAdvanced))
        #expect(!GatedPumpWrite.setSleepSchedule.hasRequiredCapability(in: .full))  // t:slim: no sleep-schedule write
        for a in [GatedPumpWrite.setTempBasal, .suspendDelivery, .setMode, .setControlIQ] {
            #expect(a.hasRequiredCapability(in: .mobiAdvanced))
            #expect(!a.hasRequiredCapability(in: .full), "\(a.rawValue) needs an advanced capability")
        }
        // Never capability-gated — delivery must never be blocked by Gate 5 (no advanced capability).
        for a in [GatedPumpWrite.deliverBolus, .deliverExtendedBolus, .cancelBolus, .dismissNotification] {
            #expect(a.hasRequiredCapability(in: .full), "\(a.rawValue) must never require a capability")
        }
    }

    /// `.setMaxBolus`/`.setMaxBasal` are the two limit-set writes —
    /// they must require the DEDICATED `supportsLimits` capability, not the coarser
    /// `supportsAnyAdvancedControl` set. A capability set that has SOME advanced control (e.g. Control-IQ
    /// settings) but NOT the basal/bolus-limit feature bit must deny both; a set WITH `supportsLimits` must
    /// allow both. The rest of the `.unverifiedAck` set (e.g. `.setControlIQ`) is untouched by this
    /// tightening, per `hasRequiredCapabilitySplitsTimeSyncFromTheAdvancedSet` above.
    @Test func setMaxBolusRequiresSupportsLimits() {
        let advancedButNoLimits = PumpCapabilities(supportsControlIQSettings: true, supportsLimits: false)
        #expect(advancedButNoLimits.supportsAnyAdvancedControl)  // sanity: the coarse check WOULD pass
        for a in [GatedPumpWrite.setMaxBolus, .setMaxBasal] {
            #expect(
                !a.hasRequiredCapability(in: advancedButNoLimits),
                "\(a.rawValue) must deny when supportsLimits is false, even with other advanced control present")
        }
        let withLimits = PumpCapabilities(supportsLimits: true)
        for a in [GatedPumpWrite.setMaxBolus, .setMaxBasal] {
            #expect(
                a.hasRequiredCapability(in: withLimits),
                "\(a.rawValue) must allow when supportsLimits is true")
        }
        // .mobiAdvanced already carries supportsLimits: true — stays allowed (no shipped-path regression).
        #expect(GatedPumpWrite.setMaxBolus.hasRequiredCapability(in: .mobiAdvanced))
        #expect(GatedPumpWrite.setMaxBasal.hasRequiredCapability(in: .mobiAdvanced))
    }
}
