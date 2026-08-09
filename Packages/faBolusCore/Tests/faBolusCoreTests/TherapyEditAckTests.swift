import Testing
@testable import faBolusCore

/// §2.1(4) B1(e): the DRAFT therapy-edit copy — a first-use "affects AUTOMATED delivery" disclosure and
/// point-of-editing titration guidance. Pins the load-bearing content (so a future edit can't silently
/// drop the automated-delivery point or the one-at-a-time / ≥7-day / small-step guidance) without
/// asserting exact wording — the copy is §13-pending and will be reworded on clinical review.
struct TherapyEditAckTests {

    @Test func firstUseDisclosureNamesTheAutomatedDeliveryImpact() {
        let d = TherapyEditAck.firstUseDisclosure
        #expect(!d.isEmpty)
        #expect(d.contains("automated insulin delivery"))     // the distinct fact vs the S8 clinical-ownership ack
        #expect(d.contains("around the clock"))                // not just the next manual bolus
        #expect(d.contains("not medical advice"))
    }

    @Test func titrationGuidanceCoversOneAtATimeSevenDaysAndSmallSteps() {
        let g = TherapyEditAck.titrationGuidance
        #expect(!g.isEmpty)
        #expect(g.contains("one setting at a time"))
        #expect(g.contains("7 days"))
        #expect(g.contains("10–20%"))
    }
}
