import Foundation

/// Pure WCAG 2.x contrast math — no SwiftUI, no platform color types. Used by the accessibility
/// contrast audit (P16 F4 / N12) to compute the ratio of a foreground color against its background so
/// the documented figures in `docs/accessibility-contrast-audit.md` can be pinned by a test and can't
/// silently drift.
///
/// This is an **audit / measurement** utility. It does NOT recolor anything: the §13-locked glucose
/// band tokens (`AppTheme` and the system-color surfaces) are unchanged. Any recolor or redundancy
/// channel is an owner/designer decision — this only measures.
///
/// Formulas follow WCAG 2.1 §1.4.3 (relative luminance and the (L1+0.05)/(L2+0.05) contrast ratio).
/// Components are sRGB in 0...1 (the same numbers `SwiftUI.Color(red:green:blue:)` takes).
public enum WCAGContrast {
    /// sRGB component (0...1) → linear-light value, per the WCAG relative-luminance definition.
    public static func linearize(_ component: Double) -> Double {
        component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance (0 = black, 1 = white) of an sRGB color.
    public static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    /// WCAG contrast ratio between two relative luminances (order-independent), in 1...21.
    public static func contrastRatio(luminance a: Double, luminance b: Double) -> Double {
        let hi = max(a, b), lo = min(a, b)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// WCAG contrast ratio between two sRGB colors (components 0...1).
    public static func contrastRatio(red r1: Double, green g1: Double, blue b1: Double,
                                     red r2: Double, green g2: Double, blue b2: Double) -> Double {
        contrastRatio(luminance: relativeLuminance(red: r1, green: g1, blue: b1),
                      luminance: relativeLuminance(red: r2, green: g2, blue: b2))
    }

    /// Contrast of an sRGB color against opaque white (#FFFFFF) — the iOS light-mode background.
    public static func contrastVsWhite(red: Double, green: Double, blue: Double) -> Double {
        contrastRatio(luminance: relativeLuminance(red: red, green: green, blue: blue), luminance: 1.0)
    }

    /// Contrast of an sRGB color against opaque black (#000000) — the iOS dark-mode background.
    public static func contrastVsBlack(red: Double, green: Double, blue: Double) -> Double {
        contrastRatio(luminance: relativeLuminance(red: red, green: green, blue: blue), luminance: 0.0)
    }

    /// WCAG 1.4.3 minimums: 3:1 for large text (≥ 18 pt, or ≥ 14 pt bold) and non-text UI, 4.5:1 for
    /// normal text. Convenience predicates so a test/doc reads the same thresholds it asserts.
    public static let largeTextMinimum = 3.0
    public static let normalTextMinimum = 4.5
}
