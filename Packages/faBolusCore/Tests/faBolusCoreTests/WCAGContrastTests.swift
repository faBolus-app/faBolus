import Testing
import Foundation
@testable import faBolusCore

/// Pins WCAG contrast math and the documented AppTheme band ratios so a recolor cannot silently fail
/// accessibility. RGB tuples are copied from faBolusDesign because this package cannot import it.
struct WCAGContrastTests {

    // MARK: - Math sanity

    @Test func whiteOnBlackIsTheMaximum21() {
        #expect(abs(WCAGContrast.contrastVsWhite(red: 0, green: 0, blue: 0) - 21.0) < 0.001)
        #expect(abs(WCAGContrast.contrastVsBlack(red: 1, green: 1, blue: 1) - 21.0) < 0.001)
    }

    @Test func identicalColorsHaveRatioOne() {
        #expect(abs(WCAGContrast.contrastVsWhite(red: 1, green: 1, blue: 1) - 1.0) < 0.001)
    }

    @Test func ratioIsOrderIndependent() {
        let a = WCAGContrast.relativeLuminance(red: 0.9, green: 0.25, blue: 0.22)
        let b = WCAGContrast.relativeLuminance(red: 1, green: 1, blue: 1)
        #expect(WCAGContrast.contrastRatio(luminance: a, luminance: b)
                == WCAGContrast.contrastRatio(luminance: b, luminance: a))
    }

    /// The canonical WCAG reference: #767676 gray on white is right at the 4.5:1 normal-text boundary.
    @Test func referenceGrayMatchesKnownValue() {
        let g = 0x76 / 255.0
        #expect(abs(WCAGContrast.contrastVsWhite(red: g, green: g, blue: g) - 4.54) < 0.02)
    }

    // MARK: - AppTheme band colors — the documented figures (MUST MATCH the audit doc)

    // sRGB literals copied from AppTheme.swift (band tokens).
    private static let inRange = (r: 0.30, g: 0.78, b: 0.36)   // green
    private static let high    = (r: 0.98, g: 0.76, b: 0.18)   // yellow
    private static let urgent  = (r: 0.95, g: 0.55, b: 0.15)   // orange
    private static let low     = (r: 0.90, g: 0.25, b: 0.22)   // red

    @Test func bandContrastVsWhiteMatchesDoc() {
        #expect(abs(WCAGContrast.contrastVsWhite(red: Self.inRange.r, green: Self.inRange.g, blue: Self.inRange.b) - 2.18) < 0.02)
        #expect(abs(WCAGContrast.contrastVsWhite(red: Self.high.r,    green: Self.high.g,    blue: Self.high.b)    - 1.64) < 0.02)
        #expect(abs(WCAGContrast.contrastVsWhite(red: Self.urgent.r,  green: Self.urgent.g,  blue: Self.urgent.b)  - 2.45) < 0.02)
        #expect(abs(WCAGContrast.contrastVsWhite(red: Self.low.r,     green: Self.low.g,     blue: Self.low.b)     - 4.09) < 0.02)
    }

    @Test func bandContrastVsBlackMatchesDoc() {
        #expect(abs(WCAGContrast.contrastVsBlack(red: Self.inRange.r, green: Self.inRange.g, blue: Self.inRange.b) - 9.63) < 0.03)
        #expect(abs(WCAGContrast.contrastVsBlack(red: Self.high.r,    green: Self.high.g,    blue: Self.high.b)    - 12.80) < 0.03)
        #expect(abs(WCAGContrast.contrastVsBlack(red: Self.urgent.r,  green: Self.urgent.g,  blue: Self.urgent.b)  - 8.58) < 0.03)
        #expect(abs(WCAGContrast.contrastVsBlack(red: Self.low.r,     green: Self.low.g,     blue: Self.low.b)     - 5.13) < 0.03)
    }

    /// The documented finding: in LIGHT mode three of four bands fail even the lenient 3:1 large-text
    /// floor, and all four fail 4.5:1 normal text; in DARK mode all four pass. This test locks that
    /// conclusion so a future color tweak that changes the pass/fail picture is caught.
    @Test func lightModeFailsLargeTextForThreeBands() {
        let min3 = WCAGContrast.largeTextMinimum
        #expect(WCAGContrast.contrastVsWhite(red: Self.inRange.r, green: Self.inRange.g, blue: Self.inRange.b) < min3)  // green FAIL
        #expect(WCAGContrast.contrastVsWhite(red: Self.high.r,    green: Self.high.g,    blue: Self.high.b)    < min3)  // yellow FAIL
        #expect(WCAGContrast.contrastVsWhite(red: Self.urgent.r,  green: Self.urgent.g,  blue: Self.urgent.b)  < min3)  // orange FAIL
        #expect(WCAGContrast.contrastVsWhite(red: Self.low.r,     green: Self.low.g,     blue: Self.low.b)     >= min3) // red PASSES large only
    }

    @Test func darkModePassesAllBands() {
        let min3 = WCAGContrast.largeTextMinimum
        for c in [Self.inRange, Self.high, Self.urgent, Self.low] {
            #expect(WCAGContrast.contrastVsBlack(red: c.r, green: c.g, blue: c.b) >= min3)
        }
    }
}
