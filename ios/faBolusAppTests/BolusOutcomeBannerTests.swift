import Testing
import Foundation
@testable import faBolus

/// Pins that a non-delivered bolus with a known message shows a warning banner carrying that copy, not
/// silence. A failed or unknown-outcome dose must never look like success or like nothing happened.
struct BolusOutcomeBannerTests {

    // MARK: - Truthful non-success contract

    @Test func failedSignalWithMessageProducesNonNilWarningBanner() {
        let banner = BolusConfirmation.banner(for: .failed, units: 2.50, message: "The pump rejected the request.")
        #expect(
            banner != nil,
            "a non-delivered outcome with a known message must surface a truthful warning banner, not silence")
        #expect(banner?.secondary == "The pump rejected the request.")
        #expect(
            banner?.primary != "Bolus delivered",
            "a non-delivered outcome must never show the success banner's primary line")
    }

    /// The indeterminate outcome is distinguished only inside AppModel — this banner surfaces the same `.failed` + `message` path.
    @Test func indeterminateCopyFlowsThroughUnchanged() {
        let indeterminateMessage = "Bolus sent but outcome is unknown — verify on the pump before retrying."
        let banner = BolusConfirmation.banner(for: .failed, units: 2.50, message: indeterminateMessage)
        #expect(banner != nil)
        #expect(
            banner?.secondary == indeterminateMessage,
            "the indeterminate copy (from AppModel's already-accurate lastError) must surface verbatim")
    }

    // MARK: - Regression pins (existing safety properties)

    @Test func deliveredStillReportsAmountRegressionPin() {
        let banner = BolusConfirmation.banner(for: .delivered, units: 2.50)
        #expect(banner != nil)
        #expect(banner?.primary == "Bolus delivered")
        #expect(banner?.secondary == "2.50 U delivered")
    }

    @Test func stagedStillProducesNoBannerEvenWithAMessage() {
        // An awaiting-approval bolus must never show a banner — staged is never a terminal outcome.
        let banner = BolusConfirmation.banner(for: .staged, units: 2.50, message: "irrelevant")
        #expect(banner == nil, "an awaiting-approval bolus must never show a banner (D-05)")
    }

    // MARK: - Per-presentation identity token

    /// Two back-to-back deliveries of the SAME amount produce byte-identical content. They must still
    /// carry DISTINCT identity tokens so `present(_:)`'s auto-dismiss timer can't clear a later
    /// presentation early — while `==` continues to report them equal by displayed content.
    @Test func identicalBannersShareContentEqualityButHaveDistinctTokens() {
        let first = BolusConfirmation.banner(for: .delivered, units: 2.50)
        let second = BolusConfirmation.banner(for: .delivered, units: 2.50)
        #expect(first != nil && second != nil)
        // Content equality is preserved (kind/primary/secondary) for any consumer relying on it.
        #expect(first == second)
        // …but each construction gets its own presentation token.
        #expect(
            first?.token != second?.token,
            "each banner construction must have a unique per-presentation token (WR-04)")
    }
}
