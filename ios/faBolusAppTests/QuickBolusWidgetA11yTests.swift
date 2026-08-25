import Testing
import Foundation
import faBolusDesign

/// **D2-05/07/10 (Phase 17-05).** Proves the interactive Quick-Bolus widget's dose ± steppers and
/// 1-2-3 in-place confirm circles meet Apple's 44×44pt minimum hit-target, carry VoiceOver
/// labels/hints, route their accent through `AppTheme.insulin` instead of a raw literal, and scale
/// their numeric readouts at large Dynamic Type instead of truncating.
///
/// **Target-membership constraint (Codex MEDIUM, 17-05-PLAN.md Task 1):** `faBolusAppTests` links
/// `target: faBolus` + `package: faBolusCore`/`faBolusDesign` (project.yml) but NOT the
/// `faBolusWidgets` app-extension target — the widget's SwiftUI views (`QuickBolusView`,
/// `stepper(delta:symbol:)`, `stepButton(_:)`, `circle(_:)`) are not directly reachable/behaviorally
/// testable from this suite. Two independent prongs close that gap without a rendered-view harness:
///
/// 1. **Shared-token prong** — `WidgetA11y` (`faBolusDesign`) holds the ONE hit-target size constant
///    + VoiceOver label/hint builders. Both the widget and this suite consume the SAME values, so a
///    change to the constant can't silently drift between "what the widget renders" and "what this
///    suite asserts" (unlike a duplicated test-only literal).
/// 2. **Source-scan prong** — mirrors this repo's `BandDriftGuardTests`/`NudgeDeliveryBoundaryTests`
///    idiom: locate the widget's function bodies via balanced-brace slicing and assert they actually
///    WIRE UP `WidgetA11y`'s constant/builders (not just that the constant itself exists and equals
///    44 — a pure-logic assertion on `WidgetA11y` alone would stay green even if the widget file
///    never adopted it). This is what fails RED today (34pt frame, zero `.accessibility*` calls, raw
///    `Color(red:` accent literal, no `.minimumScaleFactor` on the delivering/done readouts) and
///    flips GREEN once Task 2 wires the widget through these tokens.
///
/// **Not proven here (17-05-PLAN.md `<verification>`):** that the RENDERED control is actually
/// ≥44×44pt on screen — a source-scan can't observe SwiftUI's actual layout pass. That is proven
/// ONLY by the manual Accessibility Inspector check recorded in the plan/summary, non-gating.
struct QuickBolusWidgetA11yTests {

    // MARK: - Shared-token prong (WidgetA11y itself)

    @Test func minHitTargetMeetsAppleFortyFourPointMinimum() {
        #expect(WidgetA11y.minHitTarget >= 44)
    }

    @Test func stepperLabelNamesTheActionAndAmount() {
        let up = WidgetA11y.stepperLabel(increasing: true, step: 0.05, unitLabel: "units")
        let down = WidgetA11y.stepperLabel(increasing: false, step: 5, unitLabel: "grams")
        #expect(up.contains("Increase"))
        #expect(up.contains("0.05"))
        #expect(up.contains("units"))
        #expect(down.contains("Decrease"))
        #expect(down.contains("5"))
        #expect(down.contains("grams"))
        #expect(!WidgetA11y.stepperHint.isEmpty)
    }

    @Test func confirmStepLabelAndHintDescribeEachStepDistinctly() {
        for step in 1...3 {
            let notDone = WidgetA11y.confirmStepLabel(step: step, done: false)
            let done = WidgetA11y.confirmStepLabel(step: step, done: true)
            #expect(!notDone.isEmpty)
            #expect(!done.isEmpty)
            #expect(notDone != done, "step \(step) label should differ by completed state")
            #expect(!WidgetA11y.confirmStepHint(step: step).isEmpty)
        }
        // Step 3 (the delivering tap) must be distinguishable from a plain "advance" step in its hint.
        #expect(WidgetA11y.confirmStepHint(step: 3).localizedCaseInsensitiveContains("deliver"))
        #expect(!WidgetA11y.confirmStepHint(step: 1).localizedCaseInsensitiveContains("deliver"))
    }

    // MARK: - Source-scan prong (does the widget actually wire these tokens up?)

    /// Resolve the repo root by walking up from `#filePath` until `project.yml` is found — same
    /// technique as `BandDriftGuardTests.repoRootURL()`.
    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("project.yml")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    private static func widgetSource() throws -> String {
        let root = try #require(Self.repoRootURL(), "could not resolve repo root from #filePath=\(#filePath)")
        let url = root.appendingPathComponent("ios/faBolusWidgets/QuickBolusWidget.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Balanced-brace slice of a declaration located by its signature-line substring — same idiom as
    /// `BandDriftGuardTests.functionSlice(signaturePrefix:in:file:)`.
    private static func functionSlice(signaturePrefix: String, in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let startIdx = lines.firstIndex(where: { $0.contains(signaturePrefix) }) else {
            throw SliceError.signatureNotFound(signaturePrefix)
        }
        var depth = 0
        var opened = false
        var collected: [String] = []
        for line in lines[startIdx...] {
            collected.append(line)
            for ch in line {
                if ch == "{" { depth += 1; opened = true }
                else if ch == "}" { depth -= 1 }
            }
            if opened && depth <= 0 { break }
        }
        return collected.joined(separator: "\n")
    }

    private enum SliceError: Error, CustomStringConvertible {
        case signatureNotFound(String)
        var description: String {
            switch self {
            case .signatureNotFound(let sig): return "Signature not found while scanning QuickBolusWidget.swift: \(sig)"
            }
        }
    }

    @Test func stepperFunctionUsesFortyFourPointHitTargetNotThirtyFour() throws {
        let slice = try Self.functionSlice(signaturePrefix: "func stepper(delta:", in: try Self.widgetSource())
        #expect(!slice.contains("width: 34"), "stepper still frames at the old 34pt size")
        #expect(!slice.contains("height: 34"), "stepper still frames at the old 34pt size")
        #expect(slice.contains("WidgetA11y.minHitTarget"),
                "stepper should size itself off the shared WidgetA11y.minHitTarget constant, not a re-literaled 44")
    }

    @Test func stepperFunctionCarriesVoiceOverLabelAndHint() throws {
        let slice = try Self.functionSlice(signaturePrefix: "func stepper(delta:", in: try Self.widgetSource())
        #expect(slice.contains(".accessibilityLabel("), "stepper is missing a VoiceOver label")
        #expect(slice.contains(".accessibilityHint("), "stepper is missing a VoiceOver hint")
        #expect(slice.contains("WidgetA11y.stepperLabel("), "stepper should build its label via WidgetA11y")
    }

    @Test func stepButtonFunctionCarriesVoiceOverLabelAndHint() throws {
        let slice = try Self.functionSlice(signaturePrefix: "func stepButton(", in: try Self.widgetSource())
        #expect(slice.contains(".accessibilityLabel("), "1-2-3 confirm button is missing a VoiceOver label")
        #expect(slice.contains(".accessibilityHint("), "1-2-3 confirm button is missing a VoiceOver hint")
        #expect(slice.contains("WidgetA11y.confirmStepLabel("),
                "confirm button should build its label via WidgetA11y")
        #expect(slice.contains("WidgetA11y.minHitTarget"),
                "confirm circle should also be floored at the shared 44pt hit-target constant")
    }

    @Test func widgetAccentRoutesThroughAppThemeInsteadOfRawLiteral() throws {
        let source = try Self.widgetSource()
        #expect(!source.contains("Color(red: 0.24, green: 0.28, blue: 0.75)"),
                "the activated/insulin accent should no longer be a raw Color(red:) literal")
        #expect(source.contains("AppTheme.insulin"), "widget accent should route through AppTheme.insulin (D2-07)")
    }

    @Test func deliveringAndDoneReadoutsApplyMinimumScaleFactor() throws {
        let source = try Self.widgetSource()
        let delivering = try Self.functionSlice(signaturePrefix: "var deliveringBody:", in: source)
        #expect(delivering.contains(".minimumScaleFactor("),
                "deliveringBody's numeric dose readout should scale instead of truncating (D2-10)")
        let done = try Self.functionSlice(signaturePrefix: "func doneBody(", in: source)
        #expect(done.contains(".minimumScaleFactor("),
                "doneBody's numeric dose readout should scale instead of truncating (D2-10)")
    }

    @Test func fileResolutionActuallyFoundTheWidgetSource() throws {
        let source = try Self.widgetSource()
        #expect(!source.isEmpty, "widget source resolution broke — scan would otherwise pass vacuously")
    }
}
