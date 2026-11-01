import Testing
import Foundation
@testable import faBolusCore

/// The "Pump disconnected" schedule (pure). Pins what the alert engine depends on: the follow-ups are
/// ordered with strictly increasing positive delays, ids are unique and stable, every body tells the user
/// to use the pump's own buttons, the schedule is finite, and the first notice comes at the user's delay
/// with no follow-up at or before it.
@Suite struct DisconnectEscalationTests {

    @Test func ladderIsFiniteAndNonEmpty() {
        #expect(!DisconnectEscalation.steps.isEmpty)
        #expect(DisconnectEscalation.steps.count <= 5)
    }

    @Test func delaysArePositiveAndStrictlyIncreasing() {
        let delays = DisconnectEscalation.steps.map(\.afterSeconds)
        #expect(delays.allSatisfy { $0 > 0 })
        for (a, b) in zip(delays, delays.dropFirst()) { #expect(b > a) }
    }

    @Test func idsAreUnique() {
        let ids = DisconnectEscalation.allIds
        #expect(Set(ids).count == ids.count)
        #expect(ids == [DisconnectEscalation.firstNoticeId] + DisconnectEscalation.steps.map(\.id))
    }

    @Test func everyBodyCarriesThePumpButtonsInstruction() {
        for step in DisconnectEscalation.steps + [DisconnectEscalation.firstNotice(afterSeconds: 0)] {
            #expect(
                step.body.contains(DisconnectEscalation.pumpButtonsInstruction),
                "step \(step.id) must tell the user to use the pump's own buttons")
            #expect(!step.title.isEmpty)
        }
        #expect(DisconnectEscalation.pumpButtonsInstruction.lowercased().contains("pump's own buttons"))
    }

    /// The first notice at the user's delay, then each follow-up after it. With the owner's 15-minute
    /// default the 15-minute follow-up is left out (it would duplicate the first notice).
    @Test func scheduleStartsAtTheUsersDelayAndSkipsEarlierFollowUps() {
        func offsets(_ d: AlertPolicy.PumpDisconnectDelay) -> [TimeInterval] {
            DisconnectEscalation.schedule(delay: d).map(\.afterSeconds)
        }
        let m: TimeInterval = 60
        #expect(offsets(.immediately) == [0, 15 * m, 30 * m])
        #expect(offsets(.fiveMinutes) == [5 * m, 15 * m, 30 * m])
        #expect(offsets(.fifteenMinutes) == [15 * m, 30 * m])
        #expect(offsets(.thirtyMinutes) == [30 * m])
        #expect(offsets(.never).isEmpty)
        #expect(DisconnectEscalation.schedule(delay: .fifteenMinutes).first?.id == DisconnectEscalation.firstNoticeId)
    }
}
