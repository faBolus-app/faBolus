import Testing
@testable import faBolusCore

/// §2.1(4) B1(e): the therapy-edit copy — a first-use "affects AUTOMATED delivery" disclosure and
/// point-of-editing titration guidance. Pins the load-bearing content (so a future edit can't silently
/// drop the automated-delivery point, the Control-IQ mechanism precision, the one-at-a-time / ≥7-day /
/// small-step guidance, or the acute-danger carve-out) without over-asserting exact wording. §13-cleared
/// 2026-08-23 (owner-accepted AI-panel clinical review); any wording change re-opens the sign-off.
struct TherapyEditAckTests {

    @Test func firstUseDisclosureNamesTheAutomatedDeliveryImpact() {
        let d = TherapyEditAck.firstUseDisclosure
        #expect(!d.isEmpty)
        #expect(d.contains("automated insulin delivery"))  // the distinct fact vs the S8 clinical-ownership ack
        #expect(d.contains("around the clock"))  // not just the next manual bolus
        #expect(d.contains("not medical advice"))
        // Mechanism precision (§13 review): only basal + correction factor drive Control-IQ automation;
        // carb ratio + target size the manually-entered doses.
        #expect(d.contains("basal rates and correction factor"))
        #expect(d.contains("size the doses you enter yourself"))
    }

    @Test func titrationGuidanceCoversOneAtATimeSevenDaysAndSmallSteps() {
        let g = TherapyEditAck.titrationGuidance
        #expect(!g.isEmpty)
        #expect(g.contains("one setting at a time"))
        #expect(g.contains("7 days"))
        #expect(g.contains("10–20%"))
        // Acute-danger carve-out (§13 review): "wait 7 days" applies only to judging the trend.
        #expect(g.contains("ketones need prompt action"))
    }
}
