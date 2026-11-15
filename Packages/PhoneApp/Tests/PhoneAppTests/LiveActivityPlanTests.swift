import Foundation
import Testing
import WidgetContent

@testable import PhoneApp

@Suite struct LiveActivityPlanTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ id: String, live: Bool, hoursAgo: Double?) -> LiveActivityPlan.Listed {
        .init(id: id, isLive: live, startedAt: hoursAgo.map { now.addingTimeInterval(-$0 * 3600) })
    }

    /// The reported bug: iOS ended the card at 8 hours but still shows it; opening the app started a second
    /// one beside it. Now the ended one goes first.
    @Test func anEndedCardStillShowingIsEndedBeforeANewOneStarts() {
        let plan = LiveActivityPlan.decide([card("old", live: false, hoursAgo: 8.5)], appActive: true, now: now)
        #expect(plan == .init(update: nil, end: ["old"], start: true))
    }

    /// In the background nothing can be started, so the ended card stays rather than leaving nothing.
    @Test func anEndedCardStaysInTheBackground() {
        let plan = LiveActivityPlan.decide([card("old", live: false, hoursAgo: 8.5)], appActive: false, now: now)
        #expect(plan == .init(update: nil, end: [], start: false))
    }

    @Test func oneLiveCardIsUpdated() {
        let plan = LiveActivityPlan.decide([card("a", live: true, hoursAgo: 1)], appActive: false, now: now)
        #expect(plan == .init(update: "a", end: [], start: false))
    }

    /// A duplicate, however it arose, doesn't stay: the newest live card is kept and the rest end.
    @Test func extraCardsEndAndTheNewestLiveOneIsKept() {
        let plan = LiveActivityPlan.decide(
            [
                card("older", live: true, hoursAgo: 3), card("ended", live: false, hoursAgo: 9),
                card("newest", live: true, hoursAgo: 0.1)
            ],
            appActive: false, now: now)
        #expect(plan.update == "newest")
        #expect(Set(plan.end) == ["older", "ended"])
        #expect(!plan.start)
    }

    /// While the app is open, a card nearing iOS's 8-hour end is replaced before iOS freezes it.
    @Test func aCardNearingEightHoursIsReplacedInTheForeground() {
        let old = card("a", live: true, hoursAgo: 7.2)
        #expect(
            LiveActivityPlan.decide([old], appActive: true, now: now) == .init(update: nil, end: ["a"], start: true))
        #expect(LiveActivityPlan.decide([old], appActive: false, now: now) == .init(update: "a", end: [], start: false))
        let young = card("b", live: true, hoursAgo: 6.9)
        #expect(LiveActivityPlan.decide([young], appActive: true, now: now).update == "b")
    }

    /// A card started before its time was recorded (an earlier build) is kept until iOS ends it.
    @Test func aCardWithNoStartTimeIsKept() {
        let plan = LiveActivityPlan.decide([card("a", live: true, hoursAgo: nil)], appActive: true, now: now)
        #expect(plan == .init(update: "a", end: [], start: false))
    }

    @Test func nothingListedStartsOnlyInTheForeground() {
        #expect(LiveActivityPlan.decide([], appActive: true, now: now) == .init(update: nil, end: [], start: true))
        #expect(LiveActivityPlan.decide([], appActive: false, now: now) == .init(update: nil, end: [], start: false))
    }
}

/// A Live Activity host with only an ended card on screen: iOS ended it, but it's still listed.
@MainActor
private final class EndedCardHost: LiveActivityHosting {
    var isRunning: Bool { false }
    private(set) var anyListed = true
    private(set) var ended = 0
    func show(_ content: LiveActivityContent, staleDate: Date?, appActive: Bool) {}
    func end() {
        ended += 1
        anyListed = false
    }
}

@Suite @MainActor struct LiveActivitySwitchOffTests {
    /// Switching the Live Activity off takes an ended card off the Lock Screen too.
    @Test func switchingOffEndsAnEndedCardStillShowing() async {
        let phone = Phone()
        let host = EndedCardHost()
        let model = await phone.launch(liveActivity: host)
        _ = await phone.until(model) { model.pump.link == .connected }
        model.settings.liveActivityEnabled = false
        await phone.settle(model)
        #expect(host.ended >= 1)
        #expect(!host.anyListed)
        await model.shutdown()
    }
}
