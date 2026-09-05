import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Drift guard. `WidgetShared.swift` carries `WidgetGlucoseUnit` — a mirror of the canonical
/// `faBolusCore.GlucoseUnit` that is intentionally RETAINED even though the widget extension target
/// transitively links `faBolusCore` (retiring the widget mirrors was deliberately left out of scope
/// when that link landed). This test target links BOTH, so it can assert the two never drift: same
/// guarantee `WidgetGlucoseThresholdsMirrorTests` gives the threshold trio. Both enums are
/// single-case (`.mgdl` only — mmol/L display was removed as dead code); this asserts they agree on
/// every SURVIVING case rather than assuming agreement from a stale two-case shape.
struct WidgetGlucoseUnitMirrorTests {

    /// The two mirrors expose exactly the same case set: `GlucoseUnit.allCases`' raw values equal
    /// the mirror's own single case, by rawValue (never a hardcoded literal on either side).
    @Test func mirrorCaseSetMatchesCanonical() {
        let canonicalRawValues = Set(GlucoseUnit.allCases.map(\.rawValue))
        #expect(canonicalRawValues == [WidgetGlucoseUnit.mgdl.rawValue])
    }

    /// The mirror's `format(mgdl:)` must be byte-identical to the canonical funnel's, across a
    /// spread of values (boundaries + midpoints + a value above the highest clinical threshold).
    @Test func widgetMirrorFormatMatchesCanonicalAcrossValueSpread() {
        let values = [54, 70, 100, 124, 180, 250, 400]
        for v in values {
            #expect(WidgetGlucoseUnit.mgdl.format(mgdl: v) == GlucoseUnit.mgdl.format(mgdl: v))
        }
    }

    /// The wire-token resolver defends the App-Group boundary: a legacy/absent token, or an
    /// unrecognized token — including a stale "mmol" written by a pre-sweep app version — must
    /// resolve to `.mgdl` (never crash, never silently mis-scale). This is the mechanism that makes
    /// it safe for `main` to have removed the mmol/L case entirely: an old on-disk token cannot resolve to
    /// a case that no longer exists.
    @Test func wireTokenResolverDefaultsToMgdlOnNilOrUnknownOrStaleMmol() {
        #expect(WidgetGlucoseUnit(wireToken: nil) == .mgdl)
        #expect(WidgetGlucoseUnit(wireToken: "garbage") == .mgdl)
        #expect(WidgetGlucoseUnit(wireToken: "mgdl") == .mgdl)
        #expect(WidgetGlucoseUnit(wireToken: "mmol") == .mgdl)
    }

    /// `WidgetSnapshot.displayUnit` is additive-optional: a snapshot built without it (as every
    /// pre-existing call site does) still decodes/encodes cleanly and defaults to mgdl via the
    /// mirror's resolver. A snapshot carrying a stale pre-sweep "mmol" token (e.g. written by an
    /// app build that predates this removal, sitting in the App Group until the next publish) also
    /// resolves to mgdl — never a stuck mmol render in the widget process.
    @Test func widgetSnapshotDisplayUnitDefaultsToNilOrStaleMmolAndResolvesToMgdl() {
        let legacy = WidgetSnapshot(glucose: 124)
        #expect(legacy.displayUnit == nil)
        #expect(WidgetGlucoseUnit(wireToken: legacy.displayUnit) == .mgdl)

        let stalePrePinSnap = WidgetSnapshot(glucose: 124, displayUnit: "mmol")
        #expect(WidgetGlucoseUnit(wireToken: stalePrePinSnap.displayUnit) == .mgdl)
    }
}
