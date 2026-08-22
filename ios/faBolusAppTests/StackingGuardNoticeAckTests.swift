import Testing
import Foundation
@testable import faBolus

/// FLAG-4 (§1.5, REQ-D16-flags): the one-time DosingSafetyKit→SG advisory-behavior-change notice's
/// AppSettings-level ack state (`stackingGuardNoticeAckAt`/`hasAcknowledgedStackingGuardNotice`/
/// `acknowledgeStackingGuardNotice`) persists once and is idempotent (keeps the first timestamp), matching
/// the `TherapyEditAck` idiom (`TherapyEditAckAppTests`) — this half is independent of the notice UI itself
/// and is kept exactly as before.
///
/// LOCK-06 (Phase 8, 08-02): the notice UI it used to gate is REMOVED from `BolusEntryView` — with friction
/// permanently off (08-01), the notice's copy ("an extra confirmation or a re-type step") no longer
/// describes anything that can happen, so it never presents now regardless of ack state. Proven at the
/// source level (no `showStackingGuardNotice` state/trigger/render, no `stackingGuardNoticeCopy` constant
/// left in `BolusEntryView.swift`) — same re-grep-the-checked-in-source idiom as
/// `StackingGuardDisclosureHiddenBoundaryTests`/`RetrospectiveAbsenceGuardTests`.
@Suite(.serialized) @MainActor
struct StackingGuardNoticeAckTests {

    /// Resolve the repo root by walking up from this file's own `#filePath`
    /// (`<root>/ios/faBolusAppTests/StackingGuardNoticeAckTests.swift`).
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()   // → .../ios
            .deletingLastPathComponent()   // → repo root
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
        s.acknowledgeStackingGuardNotice()                 // idempotent — must keep the first timestamp
        #expect(s.stackingGuardNoticeAckAt == first)
    }

    // MARK: - LOCK-06: the notice UI never presents — proven at the source level

    @Test func sourceCompiles() {
        #expect(!Self.bolusEntryViewSource.isEmpty,
                "could not read BolusEntryView.swift at the resolved repo-root path — check #filePath resolution")
    }

    @Test func noStackingGuardNoticeStateVariableRemainsInBolusEntryView() {
        // Regardless of ack state, there is no `showStackingGuardNotice` for anything to flip true —
        // the notice cannot present because its presentation-state variable no longer exists.
        #expect(!Self.bolusEntryViewSource.contains("showStackingGuardNotice"),
                "showStackingGuardNotice must be fully removed — the notice never presents (LOCK-06)")
    }

    @Test func noStackingGuardNoticeAlertRendersInBolusEntryView() {
        #expect(!Self.bolusEntryViewSource.contains("New: Insulin Stacking Guard"),
                "the one-shot stacking-guard notice alert must not render (LOCK-06)")
    }

    @Test func noOrphanedNoticeCopyConstantRemainsInBolusEntryView() {
        #expect(!Self.bolusEntryViewSource.contains("stackingGuardNoticeCopy ="),
                "stackingGuardNoticeCopy must be removed — it described a friction path that cannot fire with friction permanently off (LOCK-06)")
        #expect(!Self.bolusEntryViewSource.contains("an extra confirmation or a re-type step"),
                "no copy describing the now-impossible friction path may remain in BolusEntryView.swift")
    }
}
