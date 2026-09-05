import Testing
@testable import faBolusCore

/// P14 S8 (§2.1(2)): `ClinicianTierAck`'s copy API — the disclosure body, the section label, and the
/// per-provenance label lookup that renders the provenance badge in the exported change log
/// (`StoredSettingChange.label(for:)` at `StoredSettingChangeStore`'s formatting site). Relocated from
/// `GatedPumpWriteTierTests` (whose subject, `GatedPumpWriteTier`, is retired whole): `label(for:)` is
/// live in production, so its only coverage must survive the tier axis it used to sit alongside.
@Suite struct ClinicianTierAckCopyTests {
    @Test func disclosureAndProvenanceLabelsCoverTheVocabulary() {
        #expect(ClinicianTierAck.label(for: .consensusDefault) == "Consensus default")
        #expect(ClinicianTierAck.label(for: .clinicianSet) == "Set with clinician")
        #expect(ClinicianTierAck.label(for: .selfSet) == "Set by you")
        #expect(!ClinicianTierAck.disclosure.isEmpty)
        #expect(!ClinicianTierAck.sectionLabel.isEmpty)
    }
}
