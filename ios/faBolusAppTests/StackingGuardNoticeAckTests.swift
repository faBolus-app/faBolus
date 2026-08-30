import Testing
import Foundation
@testable import faBolus

/// Pins ack-state persistence for the stacking-guard notice (`stackingGuardNoticeAckAt` is
/// idempotent — keeps the first timestamp). The notice UI is gone from `BolusEntryView`; this
/// suite also greps that source so `showStackingGuardNotice` / `stackingGuardNoticeCopy` cannot
/// return without a test failure.
@Suite(.serialized) @MainActor
struct StackingGuardNoticeAckTests {

    /// Resolve the repo root by walking up from this file's own `#filePath`
    /// (`<root>/ios/faBolusAppTests/StackingGuardNoticeAckTests.swift`).
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()  // → .../ios
            .deletingLastPathComponent()  // → repo root
    }

    private static var bolusEntryViewSource: String {
        let url = repoRoot.appendingPathComponent("ios/faBolus/Views/BolusEntryView.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Ack-state persistence (independent of the notice UI — kept as before)

    @Test func acknowledgeIsIdempotentAndPersists() {
        let s = AppSettings.shared
        let saved = s.stackingGuardNoticeAckAt
        defer { s.stackingGuardNoticeAckAt = saved }

        s.stackingGuardNoticeAckAt = nil
        #expect(!s.hasAcknowledgedStackingGuardNotice)
        s.acknowledgeStackingGuardNotice()
        #expect(s.hasAcknowledgedStackingGuardNotice)
        let first = s.stackingGuardNoticeAckAt
        s.acknowledgeStackingGuardNotice()  // idempotent — must keep the first timestamp
        #expect(s.stackingGuardNoticeAckAt == first)
    }

    // MARK: - The notice UI never presents — proven at the source level

    @Test func sourceCompiles() {
        #expect(
            !Self.bolusEntryViewSource.isEmpty,
            "could not read BolusEntryView.swift at the resolved repo-root path — check #filePath resolution")
    }

    @Test func noStackingGuardNoticeStateVariableRemainsInBolusEntryView() {
        // Regardless of ack state, there is no `showStackingGuardNotice` for anything to flip true —
        // the notice cannot present because its presentation-state variable no longer exists.
        #expect(
            !Self.bolusEntryViewSource.contains("showStackingGuardNotice"),
            "showStackingGuardNotice must be fully removed — the notice never presents")
    }

    @Test func noStackingGuardNoticeAlertRendersInBolusEntryView() {
        #expect(
            !Self.bolusEntryViewSource.contains("New: Insulin Stacking Guard"),
            "the one-shot stacking-guard notice alert must not render")
    }

    @Test func noOrphanedNoticeCopyConstantRemainsInBolusEntryView() {
        #expect(
            !Self.bolusEntryViewSource.contains("stackingGuardNoticeCopy ="),
            "stackingGuardNoticeCopy must be removed — it described a friction path that cannot fire with friction permanently off"
        )
        #expect(
            !Self.bolusEntryViewSource.contains("an extra confirmation or a re-type step"),
            "no copy describing the now-impossible friction path may remain in BolusEntryView.swift")
    }
}
