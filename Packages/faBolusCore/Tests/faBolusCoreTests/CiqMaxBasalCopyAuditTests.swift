import Testing
import Foundation
@testable import faBolusCore

/// Phase 09.15-08 (T1-8, D-03): pins the pure `MaxBasalFraction` fraction fn + its LOCKED label pair
/// against the D-03 anti-misconstrual guardrails BEFORE any UI consumes it. This is faBolus's OWN
/// construct (Tandem ships no such gauge) — `basalRateUnitsPerHour ÷ maxBasalUnitsPerHour`, both already
/// decoded from the pump (`BasalLimitSettingsResponse`/`CurrentBasalStatusResponse`), computed and
/// LABELED honestly as the pump's CONFIGURED max-basal delivery limit (a cap on ALL basal delivery) —
/// NEVER a Control-IQ/auto-bolus figure. D-03(iv) is the load-bearing rule: this suite FAILS the build
/// if the label ever contains a bolus/correction/ceiling/maxed word, case-insensitive.
struct CiqMaxBasalCopyAuditTests {

    // MARK: fraction — D-06 guardrail #1 (a fraction, NEVER a dose/units value)

    @Test func typicalReadingComputesTheExpectedFraction() {
        let fraction = MaxBasalFraction.fraction(currentUnitsPerHour: 0.85, maxUnitsPerHour: 1.60)
        #expect(fraction != nil)
        #expect(abs(fraction! - 0.53125) < 0.001)
    }

    @Test func zeroMaxIsFailClosedNil() {
        // maxBasalUnitsPerHour == 0 means "unknown / not read" — never render a 0/0 or divide-by-zero
        // artifact; the readout must be HIDDEN, not zero/dash (D-03 explicit).
        let fraction = MaxBasalFraction.fraction(currentUnitsPerHour: 0.85, maxUnitsPerHour: 0)
        #expect(fraction == nil)
    }

    @Test func negativeMaxIsAlsoFailClosedNil() {
        let fraction = MaxBasalFraction.fraction(currentUnitsPerHour: 0.85, maxUnitsPerHour: -1)
        #expect(fraction == nil)
    }

    @Test func currentExceedingMaxClampsToOneNeverOverflows() {
        // A transient current > configured max reading (e.g. a temp rate above the configured basal
        // limit) must never render past 100% — clamp, don't overflow.
        let fraction = MaxBasalFraction.fraction(currentUnitsPerHour: 2.0, maxUnitsPerHour: 1.60)
        #expect(fraction != nil)
        #expect(abs(fraction! - 1.0) < 0.001)
    }

    @Test func zeroCurrentIsAValidZeroFractionNotNil() {
        // Zero basal delivery right now (e.g. suspended) is a real, known fact — distinct from "unknown
        // max" — so it must compute a real 0.0 fraction, not fail-closed to nil.
        let fraction = MaxBasalFraction.fraction(currentUnitsPerHour: 0.0, maxUnitsPerHour: 1.60)
        #expect(fraction != nil)
        #expect(abs(fraction! - 0.0) < 0.001)
    }

    @Test func fractionIsAlwaysBoundedZeroToOne() {
        // Compile-time + runtime proof this is a FRACTION, never a units/dose value.
        let fraction: Double? = MaxBasalFraction.fraction(currentUnitsPerHour: 0.85, maxUnitsPerHour: 1.60)
        #expect(fraction != nil)
        #expect(fraction! >= 0.0 && fraction! <= 1.0)
    }

    // MARK: label — D-03(i)/(ii) LOCKED wording (always "basal", always the U/hr pair together)

    @Test func labelAlwaysContainsTheWordBasal() {
        let label = MaxBasalFraction.label(currentUnitsPerHour: 0.85, maxUnitsPerHour: 1.60)
        #expect(label != nil)
        #expect(label!.headline.localizedCaseInsensitiveContains("basal"))
    }

    @Test func labelHeadlineMatchesTheLockedWordingWithThePercent() {
        let label = MaxBasalFraction.label(currentUnitsPerHour: 0.85, maxUnitsPerHour: 1.60)
        #expect(label != nil)
        #expect(label!.headline == "53% of your configured max basal rate")
    }

    @Test func labelDetailAlwaysShowsBothCurrentAndMaxUnitsPerHourTogether() {
        // D-03(ii): the absolute U/hr must ALWAYS accompany the %, never the % alone.
        let label = MaxBasalFraction.label(currentUnitsPerHour: 0.85, maxUnitsPerHour: 1.60)
        #expect(label != nil)
        #expect(label!.detail.contains("0.85"))
        #expect(label!.detail.contains("1.60"))
        #expect(label!.detail.localizedCaseInsensitiveContains("U/hr"))
    }

    @Test func labelIsNilWhenFractionIsFailClosed() {
        // The label must never render on its own if the underlying fraction is fail-closed (max == 0) —
        // there is no "% of configured max basal" to disclose when the max itself is unknown.
        let label = MaxBasalFraction.label(currentUnitsPerHour: 0.85, maxUnitsPerHour: 0)
        #expect(label == nil)
    }

    // MARK: D-03(iv) copy-audit — the load-bearing guardrail. FAILS the build if a forbidden word ever
    // appears in the label, case-insensitive. The four words below are figures/framings that would
    // misconstrue this faBolus-computed configured-basal-cap readout as a bolus, an automatic
    // correction, a hard ceiling override, or "maxed out" delivery — none of which this feature is.

    @Test func labelNeverContainsAnyOfTheFourForbiddenMisconstrualWords() {
        let label = MaxBasalFraction.label(currentUnitsPerHour: 0.85, maxUnitsPerHour: 1.60)
        #expect(label != nil)
        for forbidden in MaxBasalFraction.forbiddenMisconstrualWords {
            #expect(!label!.headline.localizedCaseInsensitiveContains(forbidden),
                    "headline must never contain '\(forbidden)'")
            #expect(!label!.detail.localizedCaseInsensitiveContains(forbidden),
                    "detail must never contain '\(forbidden)'")
        }
    }

    @Test func forbiddenWordListIsExactlyTheFourD03Words() {
        // Pins the exact D-03(iv) vocabulary so a future edit can't silently narrow the audit.
        let expected: Set<String> = ["bolus", "correction", "ceiling", "maxed"]  // <!-- planner-discipline-allow: bolus correction ceiling maxed -->
        #expect(Set(MaxBasalFraction.forbiddenMisconstrualWords.map { $0.lowercased() }) == expected)
    }

    @Test func hasForbiddenWordDetectsEachWordCaseInsensitively() {
        for word in ["Bolus", "CORRECTION", "Ceiling", "maxed"] {  // <!-- planner-discipline-allow: bolus correction ceiling maxed -->
            #expect(MaxBasalFraction.hasForbiddenWord("this mentions \(word) somewhere"))
        }
        #expect(!MaxBasalFraction.hasForbiddenWord("53% of your configured max basal rate"))
    }

    @Test func variousFractionsAllProduceLabelsThatPassTheAudit() {
        // Sweep a handful of realistic current/max pairs to make sure no rounding or formatting path
        // ever accidentally introduces a forbidden word.
        let pairs: [(Double, Double)] = [(0.0, 1.6), (0.85, 1.6), (1.6, 1.6), (2.0, 1.6), (0.05, 0.35)]
        for (current, max) in pairs {
            let label = MaxBasalFraction.label(currentUnitsPerHour: current, maxUnitsPerHour: max)
            #expect(label != nil)
            for forbidden in MaxBasalFraction.forbiddenMisconstrualWords {
                #expect(!label!.headline.localizedCaseInsensitiveContains(forbidden))
                #expect(!label!.detail.localizedCaseInsensitiveContains(forbidden))
            }
        }
    }
}
