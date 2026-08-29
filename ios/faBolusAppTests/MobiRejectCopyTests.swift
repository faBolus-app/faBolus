import Testing
@testable import faBolus

/// Guards the Mobi reject-at-pairing DRAFT copy against the one banned phrase REQUIREMENTS.md names.
/// Mirrors `RegulatoryCopyTests.swift`'s exact intent — this does NOT bless the exact wording (that
/// still needs owner + a §13 clinician sign-off, per BRANCHES.md §13, before an `experimental` build is
/// distributed); it only prevents the copy from silently regressing to the banned phrase.
@Suite struct MobiRejectCopyTests {
    @Test func rejectCopyDoesNotMentionExperimentalBranch() {
        let s = MobiRejectCopy.mobiNotSupported.lowercased()
        #expect(!s.contains("experimental branch"))
    }
}
