import Testing
import Foundation
@testable import faBolusCore

/// A settled reconciliation must be announced ONCE and then stop.
///
/// `.bolusReconciliation` minted a dynamic durable dedupe key (`reconcile-<peerId>-<requestId>`) that no
/// caller could enumerate, so nothing ever pruned it and the launch replay re-posted it forever — the
/// owner's 2026-08-29 export shows `bolusReconciliation: 8` for exactly ONE reconciliation
/// (`Reconcile delivered: 1`). Two pieces are pinned here:
///
/// 1. `reconciliationDedupeKey` / `isReconciliationDedupeKey` give the dynamic family a single
///    constructor and a recognizer, so it CAN be withdrawn by name.
/// 2. `shouldReplayPersistedAlert` defines "resolved" for the replay log. A `.bolusReconciliation` post
///    is, by construction, the announcement of an ALREADY-TERMINAL ledger entry (both post sites in
///    `DeliveryLedgerCoordinator.reconcileUnresolvedDeliveries` run immediately after `settle(…)`), so
///    the only thing left to establish is whether the wearer has been shown it. Presentation — not a
///    timer, not age, not a redraw — is the positive evidence that retires the entry. An entry that was
///    persisted but NOT yet presented (a process death between persist and the OS `add`) still replays,
///    so the persist-then-replay guarantee is preserved exactly.
@Suite struct SettledReconciliationDoesNotReplayTests {
    typealias B = NotificationBroker
    typealias C = NotificationBroker.Category

    // MARK: - The dynamic key family now has a name

    /// Byte-identical to the literal the two post sites used before this change — an on-device entry
    /// written by an older build must still be recognized.
    @Test func theReconciliationDedupeKeyIsUnchangedAndRecognizable() {
        let key = RemoteBolusLedger.reconciliationDedupeKey(peerId: "garmin", requestId: "req-1")
        #expect(key == "reconcile-garmin-req-1")
        #expect(RemoteBolusLedger.isReconciliationDedupeKey(key))
        #expect(RemoteBolusLedger.isReconciliationDedupeKey("reconcile-local-abc"))
    }

    /// The recognizer must not claim the OTHER durable safety keys — an over-broad match would let a
    /// reconciliation-scoped prune delete a pump-disconnect or CGM entry.
    @Test func theRecognizerNeverMatchesAnotherSafetyCategorysKeys() {
        for other in [
            "safety.pumpDisconnect", "safety.cgmDataLoss", "safety.pumpConnectionUnstable",
            "safety.cgmStalenessWatchdog", "safety.pumpDisconnect.escalation.30m",
            "bolusDeliveryFailed-3", "indeterminate-widget-req-1", ""
        ] {
            #expect(!RemoteBolusLedger.isReconciliationDedupeKey(other), "must not match \(other)")
        }
    }

    // MARK: - "Resolved" for the replay log

    /// `.bolusReconciliation` is the only category that announces an already-settled result. Every other
    /// never-suppressible category tracks an ongoing CONDITION whose withdrawal comes from the condition
    /// clearing, so it must keep replaying.
    @Test func bolusReconciliationIsTheOnlyCategoryThatAnnouncesASettledResult() {
        #expect(C.bolusReconciliation.announcesSettledResult)
        let announcing = Set(C.allCases.filter { $0.announcesSettledResult }.map(\.rawValue))
        #expect(announcing == ["bolusReconciliation"])
    }

    /// The core rule: presented ⇒ retired; not-yet-presented ⇒ still replays exactly once.
    @Test func aReconciliationReplaysUntilItHasBeenPresentedAndThenNeverAgain() {
        #expect(
            B.shouldReplayPersistedAlert(category: .bolusReconciliation, alreadyPresented: false),
            "persisted-but-never-shown must still replay — that is the whole point of the durable log")
        #expect(
            !B.shouldReplayPersistedAlert(category: .bolusReconciliation, alreadyPresented: true),
            "an already-shown announcement of a settled dose must never re-alarm")
    }

    /// A CONDITION alert keeps replaying whether or not it has been presented — its life is governed by
    /// the condition, and the cold-launch edge detectors deliberately do not re-raise, so the durable
    /// replay is the only thing that keeps an unresolved disconnect visible across a relaunch.
    @Test func aConditionTrackingSafetyAlertAlwaysReplays() {
        for c in C.allCases where c.neverSuppressible && !c.announcesSettledResult && c.deliversAsNotification {
            #expect(B.shouldReplayPersistedAlert(category: c, alreadyPresented: false), "\(c.rawValue)")
            #expect(
                B.shouldReplayPersistedAlert(category: c, alreadyPresented: true),
                "\(c.rawValue) tracks a condition — presentation does not resolve it")
        }
    }

    /// Non-vacuity for the loop above: it must actually cover the three condition categories.
    @Test func theConditionCategorySetIsNotEmpty() {
        let conditions = Set(
            C.allCases
                .filter { $0.neverSuppressible && !$0.announcesSettledResult && $0.deliversAsNotification }
                .map(\.rawValue))
        #expect(conditions == ["pumpDisconnect", "pumpConnectionUnstable", "urgentLowGlucose"])
    }

    /// A UI-state-only category can never replay either — otherwise a durable `.cgmDataLoss` entry
    /// written by an older build would be re-evaluated (and re-refused) on every launch forever.
    @Test func aUiStateOnlyCategoryIsNeverReplayed() {
        #expect(!B.shouldReplayPersistedAlert(category: .cgmDataLoss, alreadyPresented: false))
        #expect(!B.shouldReplayPersistedAlert(category: .cgmDataLoss, alreadyPresented: true))
    }
}
