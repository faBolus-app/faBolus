import Testing
import Foundation
import SwiftUI
import UIKit
import faBolusCore
import faBolusDesign
@testable import faBolus

/// P16 F4 / N12 — anti-drift pin for the accessibility contrast audit (`docs/accessibility-contrast-audit.md`).
///
/// This resolves the LIVE `AppTheme` glucose-band colors to their sRGB components and re-derives the WCAG
/// contrast ratios the doc reports (colored number vs the system background — white in light mode, black in
/// dark mode). If the §13-locked band tokens are ever recolored, these assertions fail, forcing the doc
/// (and the faBolusCore `WCAGContrastTests` pin) to be revisited. Presentation-only: nothing here changes
/// or recolors anything — it only measures.
struct AppThemeContrastAuditTests {

    /// sRGB components of a SwiftUI `Color`, via UIColor (the app runs on iOS).
    private func srgb(_ color: SwiftUI.Color) -> (r: Double, g: Double, b: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    // MARK: - The tokens still hold the audited RGB values

    @Test func bandTokensHoldDocumentedRGB() {
        let expected: [(SwiftUI.Color, (Double, Double, Double))] = [
            (AppTheme.inRange,    (0.30, 0.78, 0.36)),
            (AppTheme.high,       (0.98, 0.76, 0.18)),
            (AppTheme.urgentHigh, (0.95, 0.55, 0.15)),
            (AppTheme.low,        (0.90, 0.25, 0.22)),
        ]
        for (color, want) in expected {
            let c = srgb(color)
            #expect(abs(c.r - want.0) < 0.01)
            #expect(abs(c.g - want.1) < 0.01)
            #expect(abs(c.b - want.2) < 0.01)
        }
    }

    // MARK: - Live-resolved ratios match the documented figures

    @Test func liveBandContrastVsWhiteMatchesDoc() {
        let cases: [(SwiftUI.Color, Double)] = [
            (AppTheme.inRange, 2.18), (AppTheme.high, 1.64), (AppTheme.urgentHigh, 2.45), (AppTheme.low, 4.09),
        ]
        for (color, want) in cases {
            let c = srgb(color)
            #expect(abs(WCAGContrast.contrastVsWhite(red: c.r, green: c.g, blue: c.b) - want) < 0.05)
        }
    }

    @Test func liveBandContrastVsBlackMatchesDoc() {
        let cases: [(SwiftUI.Color, Double)] = [
            (AppTheme.inRange, 9.63), (AppTheme.high, 12.80), (AppTheme.urgentHigh, 8.58), (AppTheme.low, 5.13),
        ]
        for (color, want) in cases {
            let c = srgb(color)
            #expect(abs(WCAGContrast.contrastVsBlack(red: c.r, green: c.g, blue: c.b) - want) < 0.05)
        }
    }

    /// The finding that motivates the audit: in light mode the in-range/high/urgent numbers fall below
    /// even the 3:1 large-text floor. Locked so a recolor that fixes (or worsens) this is caught here.
    @Test func liveLightModeFailsLargeTextForColorBands() {
        for color in [AppTheme.inRange, AppTheme.high, AppTheme.urgentHigh] {
            let c = srgb(color)
            #expect(WCAGContrast.contrastVsWhite(red: c.r, green: c.g, blue: c.b) < WCAGContrast.largeTextMinimum)
        }
    }
}
