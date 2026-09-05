import Testing
import Foundation
@testable import faBolusCore

/// DIF-ux — the shared stale/unconfirmable calc-input decision (`StaleCalcInputPrompt`). Mirrors
/// `StaleBolusPromptTests`: pins the shared warning COPY for the two-way (never three-way) stale-IOB /
/// stale-therapy overrides. Dates are chosen far from any plausible threshold so the test neither depends
/// on nor mutates the runtime `CalcInputFreshness` windows (avoids cross-suite flakiness).
///
/// The two-way, no-drop/zero-IOB SHAPE invariant is pinned on `CalcInputGateTests` (the pure gate the
/// production deliver path actually calls), not here — the two standalone choice enums this suite used to
/// pin were unused by any production path and were removed together with those tests.
struct StaleCalcInputPromptTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Warning copy names the SUBTRACT framing (never "ignore/zero the IOB")

    @Test func iobWarningNamesSubtractAndTheValueAndAge() {
        let stale = now.addingTimeInterval(-7 * 60)  // 7 min old
        let msg = StaleIobPrompt.warningMessage(iobUnits: 1.40, iobDate: stale, now: now)
        #expect(msg.contains("SUBTRACT"))  // the framing is subtract, not drop/zero
        #expect(msg.contains("1.40"))  // names the last-known value that stays subtracted
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
        #expect(msg.contains("12"))  // carb ratio
        #expect(msg.contains("45"))  // ISF
        #expect(msg.contains("110"))  // target
        #expect(msg.contains(CalcInputFreshness.ageLabel(for: stale, now: now)))
    }

    // MARK: - StaleTherapyPrompt's "target %d mg/dL" literal (mg/dL is the app's only display unit)

    @Test func therapyWarningDefaultUnitTextIsUnchanged() {
        let stale = now.addingTimeInterval(-20 * 60)
        let profile = BolusMath.Profile(carbRatioGramsPerUnit: 12, isfMgdlPerUnit: 45, targetBgMgdl: 110, iobUnits: 0)
        // No `unit:` argument — must be byte-identical to the pre-existing "target %d mg/dL" wording.
        let msg = StaleTherapyPrompt.warningMessage(profile: profile, therapyDate: stale, now: now)
        #expect(msg.contains("target 110 mg/dL"))
    }
}
