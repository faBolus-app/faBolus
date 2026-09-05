import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Drift guard. `WidgetShared.swift` carries `WidgetGlucoseThresholds` — a mirror of the canonical
/// `faBolusCore.GlucoseThresholds` that is intentionally RETAINED even though the widget extension
/// target transitively links `faBolusCore` (retiring the widget mirrors was deliberately left out of
/// scope when that link landed). This test target links BOTH, so it can assert the two never drift:
/// the same guarantee the schema/Monkey-C drift checkers give the wire contract.
struct WidgetGlucoseThresholdsMirrorTests {

    @Test func widgetMirrorEqualsCanonicalThresholds() {
        #expect(WidgetGlucoseThresholds.low == GlucoseThresholds.low)
        #expect(WidgetGlucoseThresholds.high == GlucoseThresholds.high)
        #expect(WidgetGlucoseThresholds.veryHigh == GlucoseThresholds.veryHigh)
    }

    /// The widget's `rangeCategory` and the core's `GlucoseRange` classifier must agree on the band for
    /// every value — the widget colors and the app/remote colors are meant to be identical. Includes the
    /// exact closed-convention boundaries (180 in-range, 250 high) so a future one-sided edit fails here.
    @Test func rangeCategoryMatchesCoreClassifierAcrossTheRange() {
        for g in [40, 54, 69, 70, 120, 180, 181, 250, 251, 300] {
            #expect(WidgetSnapshot.rangeCategory(g) == GlucoseRange.classify(g).index)
        }
        #expect(WidgetSnapshot.rangeCategory(nil) == -1)  // unknown stays unknown
    }
}
