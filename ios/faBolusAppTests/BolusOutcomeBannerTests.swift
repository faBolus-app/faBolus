import Testing
import Foundation
@testable import faBolus

/// **Phase 17 D3-01 (non-frozen half).** Today `BolusConfirmation.banner` is silent for every
/// non-delivered outcome (`.failed`) — including the "sent but outcome unknown" indeterminate case,
/// which AppModel already resolves an accurate, truthful `lastError` string for (`AppModel.swift:1927-
/// 1936`). This suite pins the NEW contract: a non-nil `message` supplied alongside a non-delivered
/// signal must surface a truthful, non-success WARNING banner carrying that exact message — closing the
/// visible silent-outcome asymmetry (Codex HIGH finding #2's non-frozen half) without any `AppModel`
/// edit and without a new `.indeterminate` `Signal` case (the banner never needs to distinguish failed
/// from indeterminate itself; it just surfaces whatever message the caller — `BolusEntryView`, reading
/// `model.lastError` — already resolved).
///
/// RED: fails to build/pass until Task 3 adds the `message:` parameter to
/// `BolusConfirmation.banner(for:units:extended:message:)` and makes the non-delivered path return a
/// non-nil banner when `message` is supplied.
struct BolusOutcomeBannerTests {

    // MARK: - The new truthful non-success contract (D3-01, non-frozen)

    @Test func failedSignalWithMessageProducesNonNilWarningBanner() {
        let banner = BolusConfirmation.banner(for: .failed, units: 2.50, message: "The pump rejected the request.")
        #expect(banner != nil,
                "a non-delivered outcome with a known message must surface a truthful warning banner, not silence")
        #expect(banner?.secondary == "The pump rejected the request.")
        #expect(banner?.primary != "Bolus delivered",
                "a non-delivered outcome must never show the success banner's primary line")
    }

    /// The indeterminate outcome is distinguished only inside frozen `AppModel` (`:1927`) — this banner
    /// never needs an `.indeterminate` `Signal` case; AppModel's already-accurate copy just flows
    /// through the SAME `.failed` + `message` path unchanged.
    @Test func indeterminateCopyFlowsThroughUnchanged() {
        let indeterminateMessage = "Bolus sent but outcome is unknown — verify on the pump before retrying."
        let banner = BolusConfirmation.banner(for: .failed, units: 2.50, message: indeterminateMessage)
        #expect(banner != nil)
        #expect(banner?.secondary == indeterminateMessage,
                "the indeterminate copy (from AppModel's already-accurate lastError) must surface verbatim")
    }

    // MARK: - Regression pins (existing D-04/D-05 safety properties, unchanged)

    @Test func deliveredStillReportsAmountRegressionPin() {
        let banner = BolusConfirmation.banner(for: .delivered, units: 2.50)
        #expect(banner != nil)
        #expect(banner?.primary == "Bolus delivered")
        #expect(banner?.secondary == "2.50 U delivered")
    }

    @Test func stagedStillProducesNoBannerEvenWithAMessage() {
        // D-05: an awaiting-(child-mode)-approval bolus must never show a banner — not even if a
        // message happens to be supplied, since staged is never a terminal outcome.
        let banner = BolusConfirmation.banner(for: .staged, units: 2.50, message: "irrelevant")
        #expect(banner == nil, "an awaiting-approval bolus must never show a banner (D-05)")
    }

    // MARK: - WR-04 per-presentation identity token

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
        #expect(first?.token != second?.token,
                "each banner construction must have a unique per-presentation token (WR-04)")
    }
}
