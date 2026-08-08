import Testing
import Foundation
@testable import faBolusCore

/// DIF-ux — the shared stale/unconfirmable calc-input decision (`StaleCalcInputPrompt`). Mirrors
/// `StaleBolusPromptTests`: pins the warn predicates, the two-way (never three-way) shape, that `cancel`
/// alone does not proceed, and — the load-bearing safety invariant — that there is NO drop / zero-IOB path
/// anywhere. Dates are chosen far from any plausible threshold so the test neither depends on nor mutates
/// the runtime `CalcInputFreshness` windows (avoids cross-suite flakiness).
struct StaleCalcInputPromptTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - The choices are two-way, with NO drop / zero-IOB case (the frozen owner decision)

    @Test func iobChoiceHasExactlyIncludeAndCancel_neverZero() {
        #expect(StaleIobChoice.allCases == [.includeLastKnownIob, .cancel])
        #expect(StaleIobChoice.allCases.count == 2)
        // Defensive: no case name hints at dropping / zeroing the subtracted IOB term.
        for c in StaleIobChoice.allCases {
            let name = c.rawValue.lowercased()
            #expect(!name.contains("drop"))
            #expect(!name.contains("zero"))
            #expect(!name.contains("ignore"))
        }
    }

    @Test func therapyChoiceHasExactlyUseAndCancel() {
        #expect(StaleTherapyChoice.allCases == [.useLastKnownSettings, .cancel])
        #expect(StaleTherapyChoice.allCases.count == 2)
    }

    // MARK: - shouldWarn: stale / unknown-age warns; fresh does not; future is stale

    @Test func iobShouldWarnOnlyWhenStaleOrUnknownOrFuture() {
        let fresh = now.addingTimeInterval(-10)              // 10 s old — fresh
        let stale = now.addingTimeInterval(-24 * 3600)       // 24 h old — stale
        let future = now.addingTimeInterval(60 * 60)         // 1 h ahead — beyond the 5-min future skew
        #expect(!StaleIobPrompt.shouldWarn(iobDate: fresh, now: now))
        #expect(StaleIobPrompt.shouldWarn(iobDate: stale, now: now))
        #expect(StaleIobPrompt.shouldWarn(iobDate: future, now: now))
        #expect(StaleIobPrompt.shouldWarn(iobDate: nil, now: now))   // unknown age ⇒ stale ⇒ warn (fail-closed)
    }

    @Test func therapyShouldWarnOnlyWhenStaleOrUnknownOrFuture() {
        let fresh = now.addingTimeInterval(-10)
        let stale = now.addingTimeInterval(-24 * 3600)
        let future = now.addingTimeInterval(60 * 60)
        #expect(!StaleTherapyPrompt.shouldWarn(therapyDate: fresh, now: now))
        #expect(StaleTherapyPrompt.shouldWarn(therapyDate: stale, now: now))
        #expect(StaleTherapyPrompt.shouldWarn(therapyDate: future, now: now))
        #expect(StaleTherapyPrompt.shouldWarn(therapyDate: nil, now: now))
    }

    // MARK: - proceeds: only cancel does not proceed

    @Test func onlyCancelDoesNotProceed() {
        #expect(StaleIobPrompt.proceeds(.includeLastKnownIob))
        #expect(!StaleIobPrompt.proceeds(.cancel))
        #expect(StaleTherapyPrompt.proceeds(.useLastKnownSettings))
        #expect(!StaleTherapyPrompt.proceeds(.cancel))
    }

    // MARK: - Warning copy names the SUBTRACT framing (never "ignore/zero the IOB")

    @Test func iobWarningNamesSubtractAndTheValueAndAge() {
        let stale = now.addingTimeInterval(-7 * 60)          // 7 min old
        let msg = StaleIobPrompt.warningMessage(iobUnits: 1.40, iobDate: stale, now: now)
        #expect(msg.contains("SUBTRACT"))                    // the framing is subtract, not drop/zero
        #expect(msg.contains("1.40"))                        // names the last-known value that stays subtracted
        #expect(msg.contains(CalcInputFreshness.ageLabel(for: stale, now: now)))
        #expect(!msg.lowercased().contains("ignore"))
    }

    @Test func iobWarningHandlesUnknownAge() {
        let msg = StaleIobPrompt.warningMessage(iobUnits: 0.75, iobDate: nil, now: now)
        #expect(msg.contains("unknown age"))
        #expect(msg.contains("0.75"))
    }

    @Test func therapyWarningNamesTheLastKnownProfileAndAge() {
        let stale = now.addingTimeInterval(-20 * 60)
        let profile = BolusMath.Profile(carbRatioGramsPerUnit: 12, isfMgdlPerUnit: 45, targetBgMgdl: 110, iobUnits: 0)
        let msg = StaleTherapyPrompt.warningMessage(profile: profile, therapyDate: stale, now: now)
        #expect(msg.contains("12"))     // carb ratio
        #expect(msg.contains("45"))     // ISF
        #expect(msg.contains("110"))    // target
        #expect(msg.contains(CalcInputFreshness.ageLabel(for: stale, now: now)))
    }
}
