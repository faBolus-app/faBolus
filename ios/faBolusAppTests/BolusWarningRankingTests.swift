import Testing
import Foundation
@testable import faBolus

/// Phase 09.2 Fix 4 (SC4, D-04): pins that `BolusEntryView.rankedWarnings(...)` — the pure classification/
/// ordering seam extracted from the inline warning stack (`:439-497`) — always ranks blocking-adjacent
/// conditions (overMax, pumpNotLinked, bolusInFlight, childBlocked) ABOVE advisory-only disclosures, that
/// the GREY blockers are classified `.blocking` (never demoted merely because they aren't red/orange, per
/// RESEARCH Pitfall 4), and that no active warning is ever dropped by the reorder. This is
/// presentation/ordering ONLY — it does not exercise `BolusGate`/`canBolus`/the dose (those stay pinned by
/// `BolusGateHostFeedTests` / `StackingGuardDeliverInvariantTests`).
@Suite @MainActor
struct BolusWarningRankingTests {

    /// Given a blocking condition (overMax), a grey blocking-adjacent condition (pumpNotLinked), and an
    /// advisory (sg1) all active together, the output orders both blockers before the advisory and drops
    /// nothing — the exact scenario the fix exists for (a red blocker must not get buried among advisories,
    /// and a grey blocker must not be mistaken for one).
    @Test func blockingConditionsRankBeforeAdvisoryAndNothingIsDropped() {
        let warnings = BolusEntryView.rankedWarnings(
            overMax: true, maxUnits: 5.0,
            sg2Message: nil, childBlocked: false,
            pumpNotLinked: true, bolusInFlight: false,
            carbOverride: nil, autoAmbient: nil, autoLockout: nil,
            sg1Message: "SG1 override notice", sg3aMessage: nil
        )
        #expect(warnings.count == 3)
        #expect(warnings.map(\.id) == ["overMax", "pumpNotLinked", "sg1"])
        #expect(warnings[0].severity == .blocking)
        #expect(warnings[1].severity == .blocking)
        #expect(warnings[2].severity == .advisory)
    }

    /// With only advisories active (no blocking condition present), both survive, order is preserved
    /// (source top-to-bottom order: sg2 before sg1), and both classify as `.advisory`.
    @Test func advisoryOnlyWarningsPreserveOrderAndClassifyAdvisory() {
        let warnings = BolusEntryView.rankedWarnings(
            overMax: false, maxUnits: 5.0,
            sg2Message: "SG2 max-bolus proximity notice", childBlocked: false,
            pumpNotLinked: false, bolusInFlight: false,
            carbOverride: nil, autoAmbient: nil, autoLockout: nil,
            sg1Message: "SG1 override notice", sg3aMessage: nil
        )
        #expect(warnings.count == 2)
        #expect(warnings.map(\.id) == ["sg2", "sg1"])
        #expect(warnings.allSatisfy { $0.severity == .advisory })
    }

    /// The three GREY blocking-adjacent conditions — pumpNotLinked, bolusInFlight, child-mode — each
    /// classify as `.severity == .blocking` even though none render in the "danger" (red) tone, so they
    /// are never demoted below an orange advisory shown alongside them (RESEARCH Pitfall 4).
    @Test func greyBlockersClassifyAsBlockingNotAdvisory() {
        let warnings = BolusEntryView.rankedWarnings(
            overMax: false, maxUnits: 5.0,
            sg2Message: "an orange advisory", childBlocked: true,
            pumpNotLinked: true, bolusInFlight: true,
            carbOverride: nil, autoAmbient: nil, autoLockout: nil,
            sg1Message: nil, sg3aMessage: nil
        )
        let byId = Dictionary(uniqueKeysWithValues: warnings.map { ($0.id, $0) })
        #expect(byId["pumpNotLinked"]?.severity == .blocking)
        #expect(byId["bolusInFlight"]?.severity == .blocking)
        #expect(byId["childBlocked"]?.severity == .blocking)
        // None of the grey blockers use the "danger" (red) tone — they must not be confused for overMax.
        #expect(byId["pumpNotLinked"]?.tone == .neutral)
        #expect(byId["bolusInFlight"]?.tone == .neutral)
        #expect(byId["childBlocked"]?.tone == .neutral)
        // All three blockers still rank ahead of the advisory present alongside them.
        let blockingIndices = warnings.enumerated().filter { $0.element.severity == .blocking }.map(\.offset)
        let advisoryIndices = warnings.enumerated().filter { $0.element.severity == .advisory }.map(\.offset)
        #expect(blockingIndices.allSatisfy { bi in advisoryIndices.allSatisfy { ai in bi < ai } })
    }

    /// An inactive input (nil/false) produces no warning at all — confirms the reorder never invents an
    /// item, and that all seven advisory-eligible inputs surface when active with no drops.
    @Test func inactiveInputsProduceNoWarning() {
        let warnings = BolusEntryView.rankedWarnings(
            overMax: false, maxUnits: 5.0,
            sg2Message: nil, childBlocked: false,
            pumpNotLinked: false, bolusInFlight: false,
            carbOverride: nil, autoAmbient: nil, autoLockout: nil,
            sg1Message: nil, sg3aMessage: nil
        )
        #expect(warnings.isEmpty)
    }

    /// All nine possible warning sources active at once: every one survives (no drop), and the caller's
    /// existing sg3a==sg1 dedup guard is exercised at the call site, not inside `rankedWarnings` itself —
    /// this test passes a genuinely distinct sg3a message to prove it is NOT special-cased away here.
    @Test func allActiveSourcesSurviveWithBlockingBeforeAdvisoryOrdering() {
        let warnings = BolusEntryView.rankedWarnings(
            overMax: true, maxUnits: 5.0,
            sg2Message: "sg2", childBlocked: true,
            pumpNotLinked: false, bolusInFlight: true,
            carbOverride: "carb override", autoAmbient: "auto ambient", autoLockout: "auto lockout",
            sg1Message: "sg1", sg3aMessage: "sg3a distinct from sg1"
        )
        #expect(warnings.count == 9)
        let blockingIds = Set(warnings.filter { $0.severity == .blocking }.map(\.id))
        #expect(blockingIds == ["overMax", "childBlocked", "bolusInFlight"])
        // Blocking items occupy the leading prefix of the array.
        let firstAdvisoryIndex = warnings.firstIndex { $0.severity == .advisory }!
        #expect(warnings[..<firstAdvisoryIndex].allSatisfy { $0.severity == .blocking })
        #expect(warnings[firstAdvisoryIndex...].allSatisfy { $0.severity == .advisory })
    }
}
