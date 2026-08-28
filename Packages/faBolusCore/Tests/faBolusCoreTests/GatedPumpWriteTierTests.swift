import Testing
@testable import faBolusCore

/// P14 S8 (§2.1(2)): the clinical-editability TIER axis on pump writes. Pins the clinician-tier set (the
/// §2.1 clinical-ownership settings), that it's a total non-`.fixed` partition, and the disclosure copy.
struct GatedPumpWriteTierTests {

    @Test func clinicianTierSetIsExactlyTheClinicalParameters() {
        let clinician = Set(GatedPumpWrite.clinicianTierWrites.map(\.rawValue))
        #expect(
            clinician == [
                "setControlIQ", "setMaxBolus", "setMaxBasal",
                "createProfile", "setActiveProfile", "deleteProfile",
                "addProfileSegment", "modifyProfileSegment", "deleteProfileSegment",
                "setCgmHighLowAlert"
            ])
    }

    @Test func everythingElseIsUserTierAndNoReachableWriteIsFixed() {
        // A `.fixed` setting is uneditable, so no reachable WRITE can be fixed-tier.
        for w in GatedPumpWrite.allCases {
            #expect(w.requiredTier != .fixed, "\(w.rawValue): a reachable write can't be .fixed")
        }
        // Delivery + operational + the cosmetic rename are user-tier (the person owns them day to day).
        for w in [
            GatedPumpWrite.deliverBolus, .cancelBolus, .dismissNotification, .suspendDelivery,
            .resumeDelivery, .setTempBasal, .setMode, .renameProfile, .syncTimeToNow,
            .setLowInsulinAlert, .startG7Session
        ] {
            #expect(w.requiredTier == .user, "\(w.rawValue) should be user-tier")
        }
    }

    @Test func disclosureAndProvenanceLabelsCoverTheVocabulary() {
        #expect(ClinicianTierAck.label(for: .consensusDefault) == "Consensus default")
        #expect(ClinicianTierAck.label(for: .clinicianSet) == "Set with clinician")
        #expect(ClinicianTierAck.label(for: .selfSet) == "Set by you")
        #expect(!ClinicianTierAck.disclosure.isEmpty)
        #expect(!ClinicianTierAck.sectionLabel.isEmpty)
    }
}
