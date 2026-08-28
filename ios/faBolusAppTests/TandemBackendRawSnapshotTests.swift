import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Plan 14-10 (owner-authorized follow-up to 14-09 checkpoint #3, D1/D2) — pins TandemBackend's
/// `rawActiveNotifications` exposure: the TRUE pre-`acknowledged`-filter raw pump alert bitmap, published
/// atomically alongside the existing filtered `activeNotifications` in `mergeNotifications`, and the
/// nil-until-first-read invariant (T-14-41 mitigation) that distinguishes "not yet polled this
/// connection" from "the pump genuinely reports zero active alerts."
@Suite(.serialized) @MainActor
struct TandemBackendRawSnapshotTests {

    // MARK: - Nil-until-first-read

    /// A freshly-built backend (before any status read) has `rawActiveNotifications == nil` — the
    /// underlying source lists initialize to `[]` (TandemBackend.swift:171-175) but the raw OPTIONAL
    /// stays nil until a real read completes, so a bare `[]` is never emitted as authoritative.
    @Test func freshBackendHasNilRawActiveNotifications() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        #expect(b.rawActiveNotifications == nil)
    }

    /// The first successful alert read (via mergeNotifications) sets the raw optional to non-nil.
    @Test func firstAlertReadSetsRawActiveNotificationsNonNil() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.injectStatusFrameForTesting(FakePumpTransport.alertStatusBitmap(1 << 5))
        #expect(b.rawActiveNotifications != nil)
    }

    // MARK: - Raw ignores the local-snooze filter (the core fix)

    /// A t:slim-like backend (isMobi=false ⇒ supportsRemoteAlertDismiss=false) with one active alert:
    /// after a local-snooze dismiss (`.localSnoozeOnly`, writes `acknowledged`) and a re-poll of the SAME
    /// bitmap, `activeNotifications` OMITS the snoozed alert (the filter applies) but
    /// `rawActiveNotifications` STILL CONTAINS it (raw ignores the local filter entirely) — this is the
    /// proof-of-absence oracle's whole reason to exist.
    @Test func rawActiveNotificationsRetainsALocallySnoozedAlertThatActiveNotificationsOmits() async throws {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)  // default isMobi=false ⇒ t:slim-like
        b.injectStatusFrameForTesting(FakePumpTransport.alertStatusBitmap(1 << 5))
        let alert = try #require(b.activeNotifications.first(where: { $0.id == 5 }))

        let outcome = await b.dismissNotificationTyped(alert)
        #expect(outcome == .localSnoozeOnly, "a t:slim-like pump must never authenticate a dismiss")

        // Re-poll the SAME bitmap — the pump still reports the alert as active on its own bitmap.
        b.injectStatusFrameForTesting(FakePumpTransport.alertStatusBitmap(1 << 5))

        #expect(
            !b.activeNotifications.contains(where: { $0.id == 5 }),
            "the filtered list must OMIT a locally-snoozed alert (local-snooze IS a real filter)")
        #expect(
            b.rawActiveNotifications?.contains(where: { $0.id == 5 }) == true,
            "the RAW set must STILL CONTAIN it — local-snooze is not proof the pump cleared it")
    }

    /// When nothing is acknowledged, the raw set and the filtered set are identical (by identity).
    @Test func rawActiveNotificationsEqualsActiveNotificationsWhenNothingAcknowledged() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.injectStatusFrameForTesting(FakePumpTransport.alertStatusBitmap(1 << 5))
        let rawIds = Set((b.rawActiveNotifications ?? []).map { "\($0.kind.rawValue):\($0.id)" })
        let filteredIds = Set(b.activeNotifications.map { "\($0.kind.rawValue):\($0.id)" })
        #expect(rawIds == filteredIds)
        #expect(!rawIds.isEmpty, "sanity: the injected alert must actually be present")
    }

    // MARK: - Reset to nil on link-drop / pump-switch

    /// `applyClientState(.disconnected)` runs `linkDroppedCleanup()`, which must reset the raw optional
    /// back to nil (the nil-until-first-read invariant survives a drop — a stale raw set from a PRIOR
    /// connection must never be emitted as this connection's proof-of-absence oracle).
    @Test func rawActiveNotificationsResetsToNilOnLinkDrop() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.injectStatusFrameForTesting(FakePumpTransport.alertStatusBitmap(1 << 5))
        #expect(b.rawActiveNotifications != nil)
        b.applyClientState(.disconnected)
        #expect(b.rawActiveNotifications == nil)
    }

    /// `resetSnapshotForPumpSwitch()` must also reset the raw optional to nil — a different pump's raw
    /// bitmap must never be judged against the PRIOR pump's stale raw set.
    @Test func rawActiveNotificationsResetsToNilOnPumpSwitch() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.injectStatusFrameForTesting(FakePumpTransport.alertStatusBitmap(1 << 5))
        #expect(b.rawActiveNotifications != nil)
        b.resetSnapshotForPumpSwitch()
        #expect(b.rawActiveNotifications == nil)
    }

    // MARK: - Filtered output stays byte-identical (no regression)

    /// The filtered `activeNotifications` computation itself is untouched — same alert, same fields.
    @Test func filteredActiveNotificationsUnchangedByRawExposure() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.injectStatusFrameForTesting(FakePumpTransport.alertStatusBitmap(1 << 5))
        #expect(b.activeNotifications.first(where: { $0.id == 5 })?.title.isEmpty == false)
    }
}
