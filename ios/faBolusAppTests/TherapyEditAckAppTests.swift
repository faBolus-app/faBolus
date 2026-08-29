import Testing
import Foundation
@testable import faBolus

/// §2.1(4) B1(e): the first-use therapy-edit acknowledgment persists once and is idempotent (keeps the
/// first timestamp), matching the S8 clinician-tier ack idiom. It never gates a write — this only pins the
/// per-install "shown once" marker the segment editor reads on appear.
@Suite(.serialized) @MainActor
struct TherapyEditAckAppTests {
    @Test func acknowledgeIsIdempotentAndPersists() {
        let s = AppSettings.shared
        let saved = s.therapyEditAckAt
        defer { s.therapyEditAckAt = saved }

        s.therapyEditAckAt = nil
        #expect(!s.hasAcknowledgedTherapyEdit)
        s.acknowledgeTherapyEdit()
        #expect(s.hasAcknowledgedTherapyEdit)
        let first = s.therapyEditAckAt
        s.acknowledgeTherapyEdit()  // idempotent — must keep the first timestamp
        #expect(s.therapyEditAckAt == first)
    }
}
