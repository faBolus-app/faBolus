import Testing
import Foundation
@testable import faBolus

/// FLAG-4 (§1.5, REQ-D16-flags): the one-time DosingSafetyKit→SG advisory-behavior-change notice persists
/// once and is idempotent (keeps the first timestamp), matching the `TherapyEditAck` idiom
/// (`TherapyEditAckAppTests`). It never gates a write — this only pins the per-install "shown once" marker
/// the bolus screen reads on appear.
@Suite(.serialized) @MainActor
struct StackingGuardNoticeAckTests {
    @Test func acknowledgeIsIdempotentAndPersists() {
        let s = AppSettings.shared
        let saved = s.stackingGuardNoticeAckAt
        defer { s.stackingGuardNoticeAckAt = saved }

        s.stackingGuardNoticeAckAt = nil
        #expect(!s.hasAcknowledgedStackingGuardNotice)
        s.acknowledgeStackingGuardNotice()
        #expect(s.hasAcknowledgedStackingGuardNotice)
        let first = s.stackingGuardNoticeAckAt
        s.acknowledgeStackingGuardNotice()                 // idempotent — must keep the first timestamp
        #expect(s.stackingGuardNoticeAckAt == first)
    }
}
