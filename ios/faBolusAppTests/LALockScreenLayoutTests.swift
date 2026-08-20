import Testing
import Foundation
@testable import faBolus

/// Phase 09.26 (UAT fix — the "Live Activity not appearing" regression). A Lock Screen Live Activity has a
/// HARD ~160pt maximum presentation height; content taller than that is SILENTLY not displayed (no crash,
/// no error). 09.26's Defect-1/3 layout fix pinned the full-bleed plot to a fixed `.frame(height: 190)` and
/// kept the body's `.padding(16)`, making the full-bleed Lock Screen content 190 + 2*16 = 222pt — 62pt over
/// budget — so the DEFAULT full-bleed style silently stopped appearing entirely.
///
/// This is the regression guard: the full-bleed Lock Screen body's total height MUST stay within the Lock
/// Screen maximum, or the whole card disappears. SwiftUI widget-extension LAYOUT can't be unit-tested, but
/// this pure height-budget CONTRACT can — and it's the exact invariant that was violated.
struct LALockScreenLayoutTests {

    /// The core regression assertion: full-bleed Lock Screen content (sized plot + top/bottom padding) must
    /// never exceed the documented Lock Screen Live Activity maximum height, or iOS silently drops the card.
    @Test func fullBleedLockScreenContentStaysWithinTheLockScreenHeightBudget() {
        #expect(LALockScreenLayout.fullBleedTotalHeight <= LALockScreenLayout.maxHeight)
    }

    /// Belt-and-suspenders: keep a margin under the hard limit (the system also adds its own margins around
    /// the LA content, so sitting exactly at 160 is risky). At least 8pt of headroom.
    @Test func fullBleedLockScreenContentKeepsMarginUnderTheHardLimit() {
        #expect(LALockScreenLayout.fullBleedTotalHeight <= LALockScreenLayout.maxHeight - 8)
    }

    /// The total is exactly the documented composition (plot + top+bottom padding) — guards against the
    /// constants drifting apart from what the view actually renders.
    @Test func fullBleedTotalHeightIsPlotPlusTopAndBottomPadding() {
        #expect(LALockScreenLayout.fullBleedTotalHeight
            == LALockScreenLayout.fullBleedPlotHeight + 2 * LALockScreenLayout.fullBleedContentPadding)
    }
}
