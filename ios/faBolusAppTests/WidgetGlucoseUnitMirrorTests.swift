import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 04-03 drift guard (T-04-06). The widget/complication extension targets don't link
/// faBolusCore, so `WidgetShared.swift` carries `WidgetGlucoseUnit` — a mirror of the canonical
/// `faBolusCore.GlucoseUnit`. This test target links BOTH, so it can assert the two never drift:
/// same guarantee `WidgetGlucoseThresholdsMirrorTests` gives the threshold trio.
struct WidgetGlucoseUnitMirrorTests {

    /// The mirror's `format(mgdl:)` must be byte-identical to the canonical funnel's, for both
    /// units, across a spread of values (boundaries + midpoints + a value above the highest
    /// clinical threshold).
    @Test func widgetMirrorFormatMatchesCanonicalAcrossValueSpread() {
        let values = [54, 70, 100, 124, 180, 250, 400]
        for v in values {
            #expect(WidgetGlucoseUnit.mgdl.format(mgdl: v) == GlucoseUnit.mgdl.format(mgdl: v))
            #expect(WidgetGlucoseUnit.mmol.format(mgdl: v) == GlucoseUnit.mmol.format(mgdl: v))
        }
    }

    /// The wire-token resolver defends the App-Group boundary: a legacy/absent token, or an
    /// unrecognized future token, must resolve to `.mgdl` (never crash, never silently mis-scale).
    @Test func wireTokenResolverDefaultsToMgdlOnNilOrUnknown() {
        #expect(WidgetGlucoseUnit(wireToken: nil) == .mgdl)
        #expect(WidgetGlucoseUnit(wireToken: "garbage") == .mgdl)
        #expect(WidgetGlucoseUnit(wireToken: "mgdl") == .mgdl)
        #expect(WidgetGlucoseUnit(wireToken: "mmol") == .mmol)
    }

    /// `WidgetSnapshot.displayUnit` is additive-optional: a snapshot built without it (as every
    /// pre-existing call site does) still decodes/encodes cleanly and defaults to mgdl via the
    /// mirror's resolver.
    @Test func widgetSnapshotDisplayUnitDefaultsToNilAndResolvesToMgdl() {
        let legacy = WidgetSnapshot(glucose: 124)
        #expect(legacy.displayUnit == nil)
        #expect(WidgetGlucoseUnit(wireToken: legacy.displayUnit) == .mgdl)

        let mmolSnap = WidgetSnapshot(glucose: 124, displayUnit: "mmol")
        #expect(WidgetGlucoseUnit(wireToken: mmolSnap.displayUnit) == .mmol)
    }
}
