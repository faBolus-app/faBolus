import Testing
import Foundation
@testable import faBolusCore

/// P16 S3 — the pure manual-precedence predicate. Pins the window semantics scheduled mode automation
/// relies on: a recent hands-on action defers the switch; nothing recent (or a skewed/future clock) does
/// not. A fixed `now` far from any real clock keeps the test deterministic.
struct ManualPrecedenceTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func nilTimestampNeverDefers() {
        #expect(!ManualPrecedence.shouldDeferAutomation(lastManualActionAt: nil, now: now))
    }

    @Test func recentManualActionDefers() {
        // 10 minutes ago — well inside the 60-min window.
        let tenMinAgo = now.addingTimeInterval(-10 * 60)
        #expect(ManualPrecedence.shouldDeferAutomation(lastManualActionAt: tenMinAgo, now: now))
        // 1 second ago — the freshest case still defers.
        let oneSecondAgo = now.addingTimeInterval(-1)
        #expect(ManualPrecedence.shouldDeferAutomation(lastManualActionAt: oneSecondAgo, now: now))
    }

    @Test func actionOlderThanWindowDoesNotDefer() {
        // 61 minutes ago — outside the 60-min window.
        let past = now.addingTimeInterval(-61 * 60)
        #expect(!ManualPrecedence.shouldDeferAutomation(lastManualActionAt: past, now: now))
    }

    @Test func exactlyAtTheWindowBoundaryDoesNotDefer() {
        // dt == window is EXCLUDED (`dt < window`), so the boundary reads as "not recent".
        let atBoundary = now.addingTimeInterval(-ManualPrecedence.defaultWindowSeconds)
        #expect(!ManualPrecedence.shouldDeferAutomation(lastManualActionAt: atBoundary, now: now))
    }

    @Test func futureTimestampDoesNotDefer() {
        // Clock skew (a manual action stamped in the future) must not defer.
        let future = now.addingTimeInterval(60)
        #expect(!ManualPrecedence.shouldDeferAutomation(lastManualActionAt: future, now: now))
    }

    @Test func customWindowIsHonored() {
        let fiveMinAgo = now.addingTimeInterval(-5 * 60)
        #expect(ManualPrecedence.shouldDeferAutomation(lastManualActionAt: fiveMinAgo, now: now, window: 10 * 60))
        #expect(!ManualPrecedence.shouldDeferAutomation(lastManualActionAt: fiveMinAgo, now: now, window: 2 * 60))
    }
}
