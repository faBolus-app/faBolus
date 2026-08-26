import Foundation
import faBolusCore

/// Phase 16 GO-1 Step 3 (REMED-16, CX-A-04): relocated out of `CgmCredentialsView` so `AppModel` no
/// longer depends on a View-layer type for the CGM "Test" flow — inverting the Data -> View
/// dependency. Same type name, same cases, same mapping logic as before the move (behavior-preserving
/// — see 16-03-PLAN.md Task 1); only the file/namespace changed.
///
/// Outcome of observing the selected source's live production probe (`AppModel.glucoseSourceProbe`)
/// for the "Test" flow — DETERMINATE: the caller (`AppModel.startCgmTest` / `CgmTestCoordinator`)
/// polls elapsed time on a timer and re-evaluates, rather than an indeterminate spinner. `.success`
/// when a reading is already buffered — an already-buffered reading always wins, even past the
/// timeout, so a late poll tick can never downgrade a real result to a timeout. `.timeout` once the
/// window has elapsed with nothing, OR immediately if the source reports a hard `.error` (nothing to
/// wait for — surfaced right away regardless of elapsed). `.waiting` otherwise.
enum CgmTestOutcome: Equatable {
    case waiting
    case success(GlucoseSample)
    case timeout(detail: String?)

    /// The pure Test-flow decision (change 3, D-13 UX) — kept pure and unit-testable, like
    /// `CgmCredentialsView.sourcesToTest` (`CgmSourceValidationTests`). See the case docs above for
    /// the priority order.
    static func testOutcome(latest: GlucoseSample?, status: GlucoseSourceStatus,
                             elapsed: TimeInterval, timeout: TimeInterval) -> CgmTestOutcome {
        if let latest { return .success(latest) }
        if case let .error(msg) = status { return .timeout(detail: msg) }
        if elapsed >= timeout { return .timeout(detail: nil) }
        return .waiting
    }
}
