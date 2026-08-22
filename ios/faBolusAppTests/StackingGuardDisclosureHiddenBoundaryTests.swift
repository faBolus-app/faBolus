import Testing
import Foundation
@testable import faBolus

/// **LOCK-06 disclosure-hidden boundary test (Phase 8, 08-02).** Proves the SG1/SG2/SG3a advisory
/// disclosure TEXT never reaches either `BolusEntryView` presentation seam, while the underlying
/// `StackingGuard` computation and the escalation/friction routing (`StackingGuardDeliverInvariantTests`)
/// stay completely unchanged — this suite makes ZERO assertions about delivery or friction tiers, only
/// about what disclosure TEXT is presented.
///
/// Two coupled proofs, mirroring `StackingGuardDeliverInvariantTests`' "prove it fires, then prove the
/// invariant holds anyway" idiom:
///  1. Value-level: `rankedWarnings` DOES still render sg1/sg2/sg3a items when given non-nil messages (the
///     function itself is untouched, not silently broken/dead) — but returns NO sg1/sg2/sg3a items for the
///     exact nil-message call shape `BolusEntryView`'s real call site now uses.
///  2. Source-level: the two known SG disclosure render sites in `BolusEntryView.swift` — the
///     `rankedWarnings(...)` call and the separate `confirmMessage` `parts.append` site — no longer read
///     `sg1Disclosure?.message` / `sg2Disclosure?.message` / `sg3aDisclosure?.message` as a live value fed
///     into either presentation site (re-grepped live against the checked-in source, so a regression that
///     re-wires the message back in fails this test even without exercising the SwiftUI view itself).
@Suite(.serialized) @MainActor
struct StackingGuardDisclosureHiddenBoundaryTests {

    /// Resolve the repo root by walking up from this file's own `#filePath`
    /// (`<root>/ios/faBolusAppTests/StackingGuardDisclosureHiddenBoundaryTests.swift`) — same idiom as
    /// `RetrospectiveAbsenceGuardTests`/`FeatureSurfaceAbsenceGuardTests`.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()   // → .../ios
            .deletingLastPathComponent()   // → repo root
    }

    private static var bolusEntryViewSource: String {
        let url = repoRoot.appendingPathComponent("ios/faBolus/Views/BolusEntryView.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - (1) value-level: rankedWarnings itself is unchanged (still renders SG items when asked to),
    // but BolusEntryView's actual nil-message call shape yields none

    @Test func rankedWarningsStillRendersSGItemsWhenGivenNonNilMessages() {
        // The function's own SG-rendering logic is untouched — this is NOT the regression this task
        // suppresses; it proves the nil-message result below is a caller choice, not a broken function.
        let items = BolusEntryView.rankedWarnings(
            overMax: false, maxUnits: 25, sg2Message: "sg2 disclosure text", childBlocked: false,
            pumpNotLinked: false, bolusInFlight: false, carbOverride: nil,
            autoAmbient: nil, autoLockout: nil, sg1Message: "sg1 disclosure text",
            sg3aMessage: "sg3a disclosure text")
        let ids = Set(items.map(\.id))
        #expect(ids.contains("sg1"))
        #expect(ids.contains("sg2"))
        #expect(ids.contains("sg3a"))
    }

    @Test func rankedWarningsReturnsNoSGItemsForBolusEntryViewsActualCallShape() {
        // Mirrors BolusEntryView's real call site exactly: nil for all three SG message arguments.
        let items = BolusEntryView.rankedWarnings(
            overMax: false, maxUnits: 25, sg2Message: nil, childBlocked: false,
            pumpNotLinked: false, bolusInFlight: false, carbOverride: nil,
            autoAmbient: nil, autoLockout: nil, sg1Message: nil, sg3aMessage: nil)
        let ids = Set(items.map(\.id))
        #expect(!ids.contains("sg1"))
        #expect(!ids.contains("sg2"))
        #expect(!ids.contains("sg3a"))
        #expect(items.isEmpty)
    }

    @Test func rankedWarningsStillSurfacesNonSGWarningsAlongsideNilSGMessages() {
        // Hiding the SG disclosures must not silently drop unrelated blocking/advisory warnings — the
        // overMax blocker and an unrelated carb-override advisory both still render.
        let items = BolusEntryView.rankedWarnings(
            overMax: true, maxUnits: 10, sg2Message: nil, childBlocked: false,
            pumpNotLinked: false, bolusInFlight: false, carbOverride: "carb override text",
            autoAmbient: nil, autoLockout: nil, sg1Message: nil, sg3aMessage: nil)
        let ids = Set(items.map(\.id))
        #expect(ids.contains("overMax"))
        #expect(ids.contains("carbOverride"))
        #expect(!ids.contains("sg1"))
        #expect(!ids.contains("sg2"))
        #expect(!ids.contains("sg3a"))
    }

    // MARK: - (2) source-level: both known render sites pass no SG disclosure message live, re-grepped
    // against the checked-in source (RED against pre-Plan-2 main, GREEN once this task's edits land)

    @Test func sourceCompiles() {
        #expect(!Self.bolusEntryViewSource.isEmpty,
                "could not read BolusEntryView.swift at the resolved repo-root path — check #filePath resolution")
    }

    @Test func rankedWarningsCallSiteNoLongerPassesLiveSGDisclosureMessages() {
        let source = Self.bolusEntryViewSource
        #expect(!source.contains("sg2Message: sg2Disclosure?.message"),
                "the rankedWarnings call must not pass sg2Disclosure's live message (LOCK-06)")
        #expect(!source.contains("sg1Message: sg1Disclosure?.message"),
                "the rankedWarnings call must not pass sg1Disclosure's live message (LOCK-06)")
        #expect(!source.contains("sg3aMessage: sg3aDisclosure?.message"),
                "the rankedWarnings call must not pass sg3aDisclosure's live message (LOCK-06)")
    }

    @Test func confirmMessageNoLongerAppendsTheSG3aDisclosureMessage() {
        let source = Self.bolusEntryViewSource
        #expect(!source.contains("let sg3a = sg3aDisclosure, let message = sg3a.message"),
                "confirmMessage must not append the SG3a disclosure message (LOCK-06, the separate SG3a render site)")
    }

    @Test func sg3aDisclosureComputationAndFrictionRoutingAreUntouched() {
        // Read-only guard: the plan forbids changing HOW sg1Disclosure/sg2Disclosure/sg3aDisclosure or
        // sg3aAppliedFriction compute — only nilling what's PASSED at the presentation seam. Pins that the
        // computed-property declarations (and the friction-capping line) still exist verbatim in source.
        let source = Self.bolusEntryViewSource
        #expect(source.contains("private var sg1Disclosure: StackingGuard.Disclosure?"))
        #expect(source.contains("private var sg2Disclosure: StackingGuard.Disclosure?"))
        #expect(source.contains("private var sg3aDisclosure: StackingGuard.Disclosure?"))
        #expect(source.contains("private var sg3aAppliedFriction: StackingGuard.Friction"))
        #expect(source.contains("return settings.stackingGuardFrictionEnabled ? f : .disclose"))
    }
}
