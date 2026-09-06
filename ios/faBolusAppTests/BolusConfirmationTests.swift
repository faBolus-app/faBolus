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
        #expect(banner == nil, "a blocked/rejected/timed-out outcome must never show a success banner")
    }

    // MARK: - Unconfirmed outcome (honest, never-silent disclosure)

    /// An unconfirmed outcome is a GUARANTEED disclosure — unlike `.failed` it is never silent even
    /// without a message. Its primary claims neither delivery nor non-delivery; the secondary directs
    /// the user to the pump's own history/IOB before dosing again.
    @Test func unconfirmedSignalProducesNonNilWarningBanner() {
        let banner = BolusConfirmation.banner(for: .unconfirmed, units: 2.50)
        #expect(banner != nil, "an unconfirmed outcome is a guaranteed disclosure — never silent")
        #expect(banner?.kind == .warning)
        #expect(banner?.primary != "Bolus delivered", "must not claim the dose was delivered")
        #expect(banner?.primary != "Bolus not delivered", "must not claim the dose was not delivered")
        #expect(
            banner?.secondary.contains("verify on the pump") == true,
            "the unconfirmed banner must direct the user to verify on the pump")
    }

    /// When the caller supplies the already-resolved copy (`AppModel.lastError`), it surfaces verbatim.
    @Test func unconfirmedSignalSurfacesSuppliedMessage() {
        let msg = "Bolus sent but outcome is unknown — verify on the pump before retrying."
        let banner = BolusConfirmation.banner(for: .unconfirmed, units: 2.50, message: msg)
        #expect(banner != nil)
        #expect(banner?.kind == .warning)
        #expect(banner?.secondary == msg)
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
