import Testing
import Foundation
import faBolusCore
import UserNotifications
@testable import faBolus

/// The app-side halves of three owner-authorized notification changes (2026-08-30). The pure policy
/// predicates they read are pinned in `faBolusCore` (`UnresolvedDoseNotificationsOfferNoSilencingActionTests`,
/// `CgmGapIsUiStateNotANotificationTests`, `SettledReconciliationDoesNotReplayTests`); what this suite
/// covers is what only the app target can observe — which ACTIONS iOS is actually handed, and what the
/// durable replay log does across a launch.
///
/// There was previously no coverage of the registration surface at all, which is how "Bolus outcome
/// unknown" shipped with a category-silencing snooze as its only button.
@MainActor
@Suite(.serialized) struct NotificationCategoryRegistrationAndReplayTests {
    typealias B = NotificationBroker
    typealias C = NotificationBroker.Category

    private func at(_ h: Int, _ m: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h, minute: m))!
    }
    /// A throwaway, empty defaults suite (unique per test) so runtime + replay state never leaks.
    private func isolatedStore(_ name: String) -> UserDefaults {
        let suite = "test.notifpolicy.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }
    private func tempLedgerURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notif-policy-ledger-\(UUID().uuidString).json")
    }
    private func entry(
        _ category: C, key: String, severity: B.Severity = .warning,
        lifecycleState: SafetyAlertStore.LifecycleState = .issued
    ) -> SafetyAlertStore.Entry {
        SafetyAlertStore.Entry(
            category: category, severity: severity, title: "t", body: "b", dedupeKey: key,
            userInfo: [:], categoryIdentifier: "", issuedDate: at(9, 0), deadline: nil,
            kind: .immediate, lifecycleState: lifecycleState)
    }
    /// The owned categories keyed by identifier, for direct assertions on their actions.
    private func ownedByIdentifier() -> [String: UNNotificationCategory] {
        Dictionary(uniqueKeysWithValues: NotificationCoordinator.ownedCategories().map { ($0.identifier, $0) })
    }

    // MARK: - Change 2: the two unresolved-dose categories offer NO action buttons

    /// The core assertion. Neither unresolved-dose category may carry ANY action — iOS still supplies its
    /// own default tap and swipe-to-dismiss, so only the one-tap silence is gone.
    @Test func neitherUnresolvedDoseCategoryRegistersAnyAction() {
        let owned = ownedByIdentifier()
        for c in [C.bolusIndeterminate, C.bolusDeliveryFailed] {
            let registered = owned[c.rawValue]
            #expect(registered != nil, "\(c.rawValue) must still have a registered category identifier")
            #expect(
                registered?.actions.isEmpty == true,
                "\(c.rawValue) must offer no action buttons at all — a snooze here silences an unresolved dose")
        }
    }

    /// Non-vacuity: the routine categories still have their snooze, and pump alerts still have both
    /// buttons. A blanket "register nothing" would pass the test above and fail this one.
    @Test func theRoutineCategoriesKeepTheirSnoozeAndPumpAlertsKeepClearAndSnooze() {
        let owned = ownedByIdentifier()
        for raw in ["remoteBolusRejected", "modeReminder", "mealReminder"] {
            #expect(owned[raw]?.actions.map(\.identifier) == ["SNOOZE"], "\(raw) keeps its snooze")
        }
        #expect(
            owned[NotificationCoordinator.pumpAlertCategory]?.actions.map(\.identifier) == ["CLEAR", "SNOOZE"],
            "pump alerts keep dismiss-on-pump and snooze")
    }

    /// The registration table and the policy predicate must agree for EVERY category — the invariant that
    /// makes the two assertions above structural rather than a pair of hand-maintained special cases.
    @Test func aSnoozeActionAppearsExactlyOnTheCategoriesThatPermitSilencing() {
        for category in NotificationCoordinator.ownedCategories() {
            let hasSnooze = category.actions.contains { $0.identifier == "SNOOZE" }
            // `PUMP_ALERT` is registered under its own constant, not a raw value.
            let permits: Bool
            if category.identifier == NotificationCoordinator.pumpAlertCategory {
                permits = C.pumpAlert.permitsSilencingAction
            } else {
                permits = C(rawValue: category.identifier)?.permitsSilencingAction ?? false
            }
            #expect(
                hasSnooze == permits,
                "\(category.identifier): registered snooze=\(hasSnooze) but permitsSilencingAction=\(permits)")
        }
    }

    /// Every category resolves to a REGISTERED identifier — including the never-suppressible safety ones,
    /// which used to resolve to "" and could never be attributed. A never-suppressible category's
    /// registered actions are EMPTY (no snooze/silencing affordance — they must never be snoozeable from a
    /// banner), which is how attribution and the safety property can both hold at once.
    @Test func everyResolvedCategoryIdentifierIsRegisteredAndNoSafetyCategoryIs() {
        let owned = ownedByIdentifier()
        let identifiers = Set(owned.keys)
        #expect(!identifiers.isEmpty, "an empty owned set would make every other assertion vacuous")
        for c in C.allCases {
            let id = NotificationCoordinator.categoryIdentifier(for: c)
            #expect(identifiers.contains(id), "\(c.rawValue) resolves to \(id), which is not registered")
            if c.neverSuppressible {
                #expect(
                    owned[id]?.actions.isEmpty == true,
                    "\(c.rawValue) is never-suppressible — its registered category must carry no actions")
            }
        }
    }

    /// The pump-alert category registers `.customDismissAction` so an explicit swipe-dismiss is reported
    /// back as `UNNotificationDismissActionIdentifier` — without it, iOS never delivers that identifier
    /// at all, and a dismissal is structurally unrecordable. Every never-suppressible category gets the
    /// same option, for the same reason.
    @Test func pumpAlertAndEveryNeverSuppressibleCategoryRegisterCustomDismissAction() {
        let owned = ownedByIdentifier()
        #expect(
            owned[NotificationCoordinator.pumpAlertCategory]?.options.contains(.customDismissAction) == true,
            "the pump-alert category must register .customDismissAction so a dismiss is recordable")
        for c in C.allCases where c.neverSuppressible {
            let registered = owned[NotificationCoordinator.categoryIdentifier(for: c)]
            #expect(
                registered?.options.contains(.customDismissAction) == true,
                "\(c.rawValue) must register .customDismissAction so a dismiss is recordable")
        }
    }

    /// The runtime refuses to record a snooze for an unresolved-dose category, so the "Snooze 2h" button
    /// on a notification DELIVERED by an older build (which keeps the actions it was delivered with) is
    /// inert when tapped — and the category still delivers afterwards.
    @Test func theRuntimeRefusesToSnoozeAnUnresolvedDoseCategoryAndItStillDelivers() {
        let store = isolatedStore(#function)
        let rt = NotificationRuntime(store: store)
        for c in [C.bolusIndeterminate, C.bolusDeliveryFailed] {
            rt.snooze(c, until: at(10, 0))
            #expect(rt.state.snoozedUntil?[c.rawValue] == nil, "\(c.rawValue) must not be recordable as snoozed")
            let d = NotificationPoster.post(
                B.Message(category: c, severity: .warning, title: "t", body: "b", dedupeKey: "\(c.rawValue)-1"),
                runtime: rt, now: at(9, 0)
            ) { _ in }
            #expect(d.deliver, "\(c.rawValue) must still deliver after a snooze attempt")
        }
        // Non-vacuity: a category that DOES permit a snooze is still snoozed by the same call.
        rt.snooze(.pumpAlert, until: at(10, 0))
        #expect(rt.state.snoozedUntil?["pumpAlert"] == at(10, 0))
    }

    // MARK: - Change 3: a CGM gap never becomes a notification

    /// The coordinator's own gate: a `.cgmDataLoss` post persists NO durable replay record and builds no
    /// request. The durable half is why the refusal cannot live only in `decide()` — the safety branch
    /// persists before the broker decides, so a refusal there alone would leave an orphan record behind.
    @Test func aCgmDataLossPostPersistsNothingAndDeliversNothing() {
        let defaults = isolatedStore(#function)
        let rt = NotificationRuntime(store: defaults)
        defaults.set(true, forKey: NotificationRuntime.telemetryEnabledKey)  // so a phantom count would show
        let store = SafetyAlertStore(store: defaults)
        let model = AppModel(source: MockBackend(), ledgerStoreURL: tempLedgerURL())
        let coordinator = NotificationCoordinator(model: model, runtime: rt, safetyAlertStore: store)

        let d = coordinator.post(
            B.Message(
                category: .cgmDataLoss, severity: .warning, title: "CGM data lost", body: "b",
                dedupeKey: "safety.cgmDataLoss"))

        #expect(!d.deliver && d.reason == .uiStateOnly)
        #expect(
            store.entries["safety.cgmDataLoss"] == nil,
            "a UI-state-only category must leave no durable replay record")
        #expect(rt.telemetry["cgmDataLoss"] == nil, "and must not be counted as delivered")
    }

    /// Arming the staleness watchdog must post nothing and — the specific regression in the 2026-08-29
    /// export — must not increment a counter named `delivered`. 720 of those increments were watchdog
    /// re-arms the wearer never saw (one per advanced CGM datum ≈ 60 h of normal operation).
    @Test func armingTheStalenessWatchdogCountsNoDeliveryAndPersistsNothing() {
        let defaults = isolatedStore(#function)
        let rt = NotificationRuntime(store: defaults)
        defaults.set(true, forKey: NotificationRuntime.telemetryEnabledKey)
        let store = SafetyAlertStore(store: defaults)
        let model = AppModel(source: MockBackend(), ledgerStoreURL: tempLedgerURL())
        let coordinator = NotificationCoordinator(model: model, runtime: rt, safetyAlertStore: store)
        #expect(model.notificationStalenessSink != nil, "the coordinator must own the arm sink")

        // Ten advanced CGM readings' worth of re-arms.
        for i in 0..<10 { model.notificationStalenessSink?(Date().addingTimeInterval(Double(i) * 300)) }

        #expect(rt.telemetry["cgmDataLoss"] == nil, "a watchdog re-arm is not a delivered notification")
        #expect(store.entries[StalenessWatchdog.dedupeKey] == nil, "and it persists no replay record")
        _ = coordinator
    }

    // MARK: - Change 1: a settled reconciliation is announced once, then retired

    /// An already-PRESENTED reconciliation is retired at the next launch WITHOUT being re-announced —
    /// the defect that made one reconciliation read as `bolusReconciliation: 8` in the export. Telemetry
    /// is the observable: a replay would have counted a delivery.
    @Test func aPresentedReconciliationIsRetiredWithoutReplaying() {
        let defaults = isolatedStore(#function)
        defaults.set(true, forKey: AppGroupKeys.safetyAlertsReconciliationPurged)  // isolate from the migration
        defaults.set(true, forKey: NotificationRuntime.telemetryEnabledKey)
        let rt = NotificationRuntime(store: defaults)
        let store = SafetyAlertStore(store: defaults)
        let key = RemoteBolusLedger.reconciliationDedupeKey(peerId: "garmin", requestId: "r1")
        store.record(entry(.bolusReconciliation, key: key, severity: .info, lifecycleState: .presented))
        let model = AppModel(source: MockBackend(), ledgerStoreURL: tempLedgerURL())

        // Constructing the coordinator runs `replayPersistedSafetyAlerts()`.
        let coordinator = NotificationCoordinator(model: model, runtime: rt, safetyAlertStore: store)

        #expect(store.entries[key] == nil, "a settled, already-shown reconciliation must be retired")
        #expect(
            rt.telemetry["bolusReconciliation"] == nil,
            "and must NOT be re-announced — no delivery may be counted for it")
        _ = coordinator
    }

    /// The persist-then-replay guarantee is intact: a reconciliation record that was persisted but never
    /// handed to the OS (a process death in that window) still replays — exactly once — and is then
    /// retired, so the wearer is guaranteed one announcement and at most one repeat.
    @Test func anUnpresentedReconciliationReplaysExactlyOnceAndIsThenRetired() {
        let defaults = isolatedStore(#function)
        defaults.set(true, forKey: AppGroupKeys.safetyAlertsReconciliationPurged)
        defaults.set(true, forKey: NotificationRuntime.telemetryEnabledKey)
        let rt = NotificationRuntime(store: defaults)
        let store = SafetyAlertStore(store: defaults)
        let key = RemoteBolusLedger.reconciliationDedupeKey(peerId: "garmin", requestId: "r2")
        store.record(entry(.bolusReconciliation, key: key, severity: .info, lifecycleState: .issued))
        let model = AppModel(source: MockBackend(), ledgerStoreURL: tempLedgerURL())

        let first = NotificationCoordinator(model: model, runtime: rt, safetyAlertStore: store)
        #expect(rt.telemetry["bolusReconciliation"]?.delivered == 1, "the never-shown record must replay once")
        #expect(store.entries[key] == nil, "and must be retired in the same launch, not left for the next one")

        // A second launch on the same store announces nothing further.
        let model2 = AppModel(source: MockBackend(), ledgerStoreURL: tempLedgerURL())
        let second = NotificationCoordinator(model: model2, runtime: rt, safetyAlertStore: store)
        #expect(rt.telemetry["bolusReconciliation"]?.delivered == 1, "no further re-announcement, ever")
        _ = (first, second)
    }

    /// A CONDITION record is unaffected: presentation resolves nothing about an ongoing pump disconnect,
    /// so it must still replay across a relaunch (the cold-launch edge detectors deliberately do not
    /// re-raise, so this durable replay is the only thing that keeps it visible).
    @Test func aPresentedConditionRecordStillReplaysAcrossALaunch() {
        let defaults = isolatedStore(#function)
        defaults.set(true, forKey: AppGroupKeys.safetyAlertsReconciliationPurged)
        defaults.set(true, forKey: NotificationRuntime.telemetryEnabledKey)
        let rt = NotificationRuntime(store: defaults)
        let store = SafetyAlertStore(store: defaults)
        store.record(
            entry(.pumpDisconnect, key: "safety.pumpDisconnect", severity: .error, lifecycleState: .presented))
        let model = AppModel(source: MockBackend(), ledgerStoreURL: tempLedgerURL())

        let coordinator = NotificationCoordinator(model: model, runtime: rt, safetyAlertStore: store)

        #expect(rt.telemetry["pumpDisconnect"]?.delivered == 1, "an unresolved condition must still replay")
        #expect(
            store.entries["safety.pumpDisconnect"] != nil,
            "and its record must survive — only the condition clearing may prune it")
        _ = coordinator
    }

    /// The one-time migration: it removes the stuck reconciliation record WITHOUT announcing it, leaves
    /// every other category alone, and never fires again.
    @Test func theOneTimePurgeRemovesOnlyReconciliationRecordsAndOnlyOnce() {
        let defaults = isolatedStore(#function)
        defaults.set(true, forKey: NotificationRuntime.telemetryEnabledKey)
        let rt = NotificationRuntime(store: defaults)
        let store = SafetyAlertStore(store: defaults)
        let stuck = RemoteBolusLedger.reconciliationDedupeKey(peerId: "garmin", requestId: "stuck")
        store.record(entry(.bolusReconciliation, key: stuck, severity: .info, lifecycleState: .issued))
        store.record(
            entry(.pumpDisconnect, key: "safety.pumpDisconnect", severity: .error, lifecycleState: .issued))
        let model = AppModel(source: MockBackend(), ledgerStoreURL: tempLedgerURL())

        let first = NotificationCoordinator(model: model, runtime: rt, safetyAlertStore: store)

        #expect(store.entries[stuck] == nil, "the stuck reconciliation record must be purged")
        #expect(
            rt.telemetry["bolusReconciliation"] == nil,
            "the purge must remove it silently — it must NOT be announced one last time")
        #expect(
            store.entries["safety.pumpDisconnect"] != nil,
            "a condition record about a still-live condition must be untouched by the purge")
        #expect(defaults.bool(forKey: AppGroupKeys.safetyAlertsReconciliationPurged))

        // A LATER, legitimate reconciliation on the same install must not be caught by the purge: it is
        // retired by presentation instead, so an unpresented one still replays.
        let fresh = RemoteBolusLedger.reconciliationDedupeKey(peerId: "garmin", requestId: "fresh")
        store.record(entry(.bolusReconciliation, key: fresh, severity: .info, lifecycleState: .issued))
        let model2 = AppModel(source: MockBackend(), ledgerStoreURL: tempLedgerURL())
        let second = NotificationCoordinator(model: model2, runtime: rt, safetyAlertStore: store)
        #expect(
            rt.telemetry["bolusReconciliation"]?.delivered == 1,
            "the purge is spent — a later reconciliation is announced normally")
        _ = (first, second)
    }

    /// `SafetyAlertPoster` still persists BEFORE the OS `add(_:)` (the record reads `.issued` inside the
    /// closure) and marks `.presented` only afterwards — the ordering the retirement rule depends on.
    @Test func theSafetyPosterMarksPresentedOnlyAfterTheOsAcceptsTheRequest() {
        let defaults = isolatedStore(#function)
        let store = SafetyAlertStore(store: defaults)
        let rt = NotificationRuntime(store: defaults)
        let key = RemoteBolusLedger.reconciliationDedupeKey(peerId: "garmin", requestId: "r3")
        var stateInsideAdd: SafetyAlertStore.LifecycleState?

        let d = SafetyAlertPoster.post(
            B.Message(
                category: .bolusReconciliation, severity: .info, title: "Bolus delivered",
                body: "Reconciled from the pump: 1.0 U delivered.", dedupeKey: key),
            store: store, runtime: rt, now: at(9, 0)
        ) { _ in stateInsideAdd = store.entries[key]?.lifecycleState }

        #expect(d.deliver)
        #expect(stateInsideAdd == .issued, "persist-before-post: the record exists, unpresented, at add time")
        #expect(store.entries[key]?.lifecycleState == .presented, "and is marked presented once the OS has it")
    }

    /// "Delete all on-device data" must erase the durable replay log too. Before this it did not, which is
    /// why the stuck reconciliation record survived a full erase.
    @Test func eraseStoredBlobsAlsoErasesTheDurableReplayLog() {
        let defaults = isolatedStore(#function)
        let store = SafetyAlertStore(store: defaults)
        store.record(entry(.pumpDisconnect, key: "safety.pumpDisconnect", severity: .error))
        #expect(defaults.data(forKey: SafetyAlertStore.key) != nil)

        NotificationRuntime.eraseStoredBlobs(store: defaults)

        #expect(defaults.data(forKey: SafetyAlertStore.key) == nil, "the replay log is accumulated data — erase it")
        #expect(SafetyAlertStore(store: defaults).unresolvedEntries().isEmpty)
    }
}
