import Testing
import Foundation
@testable import faBolus

/// SG1/SG2/SG3a advisory disclosure text must not reach either `BolusEntryView` presentation seam;
/// stacking computation and friction routing stay unchanged.
@Suite(.serialized) @MainActor
struct StackingGuardDisclosureHiddenBoundaryTests {

    /// Resolve the repo root by walking up from this file's own `#filePath`.
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

    // MARK: - (1) value-level: rankedWarnings still renders SG items when asked to,
    // but BolusEntryView's actual nil-message call shape yields none

    @Test func rankedWarningsStillRendersSGItemsWhenGivenNonNilMessages() {
        // The function's own SG-rendering logic is untouched — the nil-message result below is a
        // caller choice, not a broken function.
        let items = BolusEntryView.rankedWarnings(
            overMax: false, maxUnits: 25, sg2Message: "sg2 disclosure text", childBlocked: false,
            pumpNotLinked: false, bolusInFlight: false, carbOverride: nil,
            sg1Message: "sg1 disclosure text",
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
            sg1Message: nil, sg3aMessage: nil)
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
            sg1Message: nil, sg3aMessage: nil)
        let ids = Set(items.map(\.id))
        #expect(ids.contains("overMax"))
        #expect(ids.contains("carbOverride"))
        #expect(!ids.contains("sg1"))
        #expect(!ids.contains("sg2"))
        #expect(!ids.contains("sg3a"))
    }

    // MARK: - (2) source-level: both known render sites pass no SG disclosure message live

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
        // Hiding the SG disclosures must not drop HOW sg1/sg2/sg3a disclosure or sg3a friction compute —
        // only nilling what's passed at the presentation seam. Pins that the computed-property
        // declarations (and the friction-capping line) still exist verbatim in source.
        let source = Self.bolusEntryViewSource
        #expect(source.contains("private var sg1Disclosure: StackingGuard.Disclosure?"))
        #expect(source.contains("private var sg2Disclosure: StackingGuard.Disclosure?"))
        #expect(source.contains("private var sg3aDisclosure: StackingGuard.Disclosure?"))
        #expect(source.contains("private var sg3aAppliedFriction: StackingGuard.Friction"))
        #expect(source.contains("return settings.stackingGuardFrictionEnabled ? f : .disclose"))
    }
}
