import Testing
import Foundation
@testable import faBolus

/// Pure outcome-decision tests for the transient bolus-success
/// confirmation on the embedded `BolusEntryView`. `BolusConfirmation.banner(for:units:extended:)` is a
/// dependency-free mapping from an ALREADY-RESOLVED delivery outcome to display text — it must NEVER
/// synthesize a "delivered" banner for a pending or failed outcome (the core safety property).
///
/// Mirrors this repo's `RootTabView.resolveSelection` static-for-test idiom: no `AppModel`, no
/// async, no SwiftUI — just `Signal` in, `BolusSuccessBanner?` out.
@Suite
struct BolusConfirmationTests {

    // MARK: - Never-false-positive cases (core safety property)

    @Test func failedSignalProducesNoBanner() {
        let banner = BolusConfirmation.banner(for: .failed, units: 2.50)
        #expect(banner == nil, "a blocked/indeterminate/rejected/timed-out outcome must never show a success banner")
    }

    // MARK: - Truthful confirmation (only on real .delivered)

    @Test func deliveredStandardBolusProducesTruthfulBanner() {
        let banner = BolusConfirmation.banner(for: .delivered, units: 2.50)
        #expect(banner != nil)
        #expect(banner?.primary == "Bolus delivered")
        #expect(banner?.secondary == "2.50 U delivered")
    }

    @Test func deliveredExtendedBolusProducesNowTotalDurationSecondaryLine() {
        let banner = BolusConfirmation.banner(
            for: .delivered, units: 2.50,
            extended: BolusConfirmation.ExtendedDetail(nowUnits: 1.25, totalUnits: 2.50, durationMinutes: 120)
        )
        #expect(banner != nil)
        #expect(banner?.primary == "Bolus delivered")
        #expect(banner?.secondary == "1.25 U now, 2.50 U total over 120 min")
    }
}
