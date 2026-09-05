import Testing
import Foundation
import faBolusCore
import UserNotifications
@testable import faBolus

/// An indeterminate bolus posts a suppressible `.bolusIndeterminate` warning alongside — never
/// replacing — the never-suppressible `.bolusReconciliation` post, and never uses the word that
/// means the dose failed.
@Suite(.serialized)
@MainActor
struct BolusIndeterminateNotificationTests {

    // MARK: - Test harness (mirrors DeliverySurfaceOutcomeGuardTests / AppModelBehaviorTests)

    @MainActor
    final class EchoRecorder {
        private(set) var commands: [RemoteCommand] = []
        func attach(to model: AppModel) { model.addRemoteEcho { [weak self] c in self?.commands.append(c) } }
        var last: RemoteCommand? { commands.last }
    }

    private func makeModel(connected: Bool) async -> (AppModel, MockBackend, EchoRecorder) {
        let backend = MockBackend()
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("17-13-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        let rec = EchoRecorder()
        rec.attach(to: model)
        if connected { await backend.connect() }
        return (model, backend, rec)
    }

    private func withCleanSettings(_ body: () async throws -> Void) async rethrows {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled
        s.phoneReadOnly = false
        s.childModeEnabled = false
        defer {
            s.phoneReadOnly = ro
            s.childModeEnabled = child
        }
        try await body()
    }

    private static let lockedCopy = AppModel.indeterminateOutcomeLockedCopy
    private static let widgetEchoMessage = "Bolus sent but outcome is unknown — verify on the pump."
    /// Never the word that means a dose did not happen — checked against every captured locked-copy post.
    private static let doseDidNotHappenWord = "fail"

    // MARK: - performLocalBolus (local / reverse-approval)

    @Test func localIndeterminatePostsExactlyOneGovernedNotificationWithLockedCopyAndNoDeliveryFailed() async {
        await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            backend.forceIndeterminateNextDelivery = true
            var posted: [NotificationBroker.Message] = []
            model.notificationSink = { msg, _, _ in posted.append(msg) }

            await model.deliverBolus(units: 1.0)

            let indeterminate = posted.filter { $0.category == .bolusIndeterminate }
            #expect(indeterminate.count == 1, "exactly one .bolusIndeterminate post for this delivery")
            #expect(indeterminate.first?.title == Self.lockedCopy)
            #expect(indeterminate.first?.body == Self.lockedCopy)
            #expect(indeterminate.first?.severity == .warning)
            #expect(
                posted.allSatisfy { $0.category != .bolusDeliveryFailed },
                "an indeterminate outcome must never post a delivery-FAILED notification")
            for m in indeterminate {
                #expect(!m.title.lowercased().contains(Self.doseDidNotHappenWord))
                #expect(!m.body.lowercased().contains(Self.doseDidNotHappenWord))
            }
        }
    }

    // MARK: - Extended bolus (local combo)

    @Test func extendedIndeterminatePostsExactlyOneGovernedNotificationWithLockedCopyAndNoDeliveryFailed() async {
        await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            backend.forceIndeterminateNextDelivery = true
            var posted: [NotificationBroker.Message] = []
            model.notificationSink = { msg, _, _ in posted.append(msg) }

            await model.deliverExtendedBolus(totalUnits: 2.0, nowUnits: 1.0, durationMinutes: 30)

            let indeterminate = posted.filter { $0.category == .bolusIndeterminate }
            #expect(indeterminate.count == 1)
            #expect(indeterminate.first?.title == Self.lockedCopy)
            #expect(indeterminate.first?.body == Self.lockedCopy)
            #expect(indeterminate.first?.severity == .warning)
            #expect(posted.allSatisfy { $0.category != .bolusDeliveryFailed })
        }
    }

    // MARK: - Remote / remote-approval-confirmed (executeResolved via remoteDeliver)

    @Test func remoteIndeterminatePostsExactlyOneGovernedNotificationAndEchoesTheUnchangedUnknownStatus() async {
        await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            backend.forceIndeterminateNextDelivery = true
            var posted: [NotificationBroker.Message] = []
            model.notificationSink = { msg, _, _ in posted.append(msg) }

            await model.remoteDeliver(requestId: "r-indet-notif", units: 1.0, peerId: "watch")

            let indeterminate = posted.filter { $0.category == .bolusIndeterminate }
            #expect(indeterminate.count == 1)
            #expect(indeterminate.first?.title == Self.lockedCopy)
            #expect(indeterminate.first?.body == Self.lockedCopy)
            #expect(posted.allSatisfy { $0.category != .bolusDeliveryFailed })
            // executeResolved's `.unknown` echo message is ALREADY the locked copy — must stay unchanged.
            #expect(rec.last?.requestId == "r-indet-notif")
            #expect(rec.last?.status == .unknown)
            #expect(rec.last?.message == Self.lockedCopy)
        }
    }

    // MARK: - Widget (deliverWidgetBolus)

    @Test
    func widgetIndeterminatePostsExactlyOneGovernedNotificationConvergesUserCopyButEchoesTheUnchangedShorterMessage()
        async
    {
        await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            backend.forceIndeterminateNextDelivery = true
            var posted: [NotificationBroker.Message] = []
            model.notificationSink = { msg, _, _ in posted.append(msg) }

            let r = await model.deliverWidgetBolus(requestId: "w-indet-notif", units: 1.0)

            let indeterminate = posted.filter { $0.category == .bolusIndeterminate }
            #expect(indeterminate.count == 1)
            #expect(indeterminate.first?.title == Self.lockedCopy)
            #expect(indeterminate.first?.body == Self.lockedCopy)
            #expect(posted.allSatisfy { $0.category != .bolusDeliveryFailed })
            // USER-FACING copy converges to the locked string (the returned tuple's error).
            #expect(r.error == Self.lockedCopy, "the widget's user-facing error must converge to the locked copy")
            // PEER WIRE: the `.unknown` echo message stays the ORIGINAL shorter string, byte-identical.
            #expect(rec.last?.requestId == "w-indet-notif")
            #expect(rec.last?.status == .unknown)
            #expect(
                rec.last?.message == Self.widgetEchoMessage,
                "the widget's .unknown echo payload must remain byte-identical to its original shorter string")
        }
    }

    // MARK: - Echo-payload-unchanged (peer wire byte-identity)

    @Test func widgetUnknownEchoMessageIsByteIdenticalToItsOriginalShorterStringRegardlessOfUserCopyConvergence() async
    {
        await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            backend.forceIndeterminateNextDelivery = true
            _ = await model.deliverWidgetBolus(requestId: "w-echo-check", units: 1.0)
            #expect(rec.last?.message == "Bolus sent but outcome is unknown — verify on the pump.")
            #expect(rec.last?.message != Self.lockedCopy, "the peer echo must NOT converge to the longer locked copy")
        }
    }

    @Test func executeResolvedUnknownEchoMessageIsUnchanged() async {
        await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            backend.forceIndeterminateNextDelivery = true
            await model.remoteDeliver(requestId: "r-echo-check", units: 1.0, peerId: "watch")
            #expect(rec.last?.message == Self.lockedCopy)
        }
    }

    // MARK: - Locked-copy guard across every captured `.bolusIndeterminate` post

    @Test func everyBolusIndeterminatePostTitleAndBodyEqualTheLockedCopyExactlyAndNeverMentionFailure() async {
        await withCleanSettings {
            var allPosted: [NotificationBroker.Message] = []
            for surface in ["local", "extended", "remote", "widget"] {
                let (model, backend, _) = await makeModel(connected: true)
                backend.forceIndeterminateNextDelivery = true
                model.notificationSink = { msg, _, _ in allPosted.append(msg) }
                switch surface {
                case "local": await model.deliverBolus(units: 1.0)
                case "extended": await model.deliverExtendedBolus(totalUnits: 1.0, nowUnits: 1.0, durationMinutes: 30)
                case "remote": await model.remoteDeliver(requestId: "guard-\(surface)", units: 1.0, peerId: "watch")
                default: _ = await model.deliverWidgetBolus(requestId: "guard-\(surface)", units: 1.0)
                }
            }
            let indeterminate = allPosted.filter { $0.category == .bolusIndeterminate }
            #expect(indeterminate.count == 4, "all four surfaces must each post exactly one")
            for m in indeterminate {
                #expect(m.title == Self.lockedCopy)
                #expect(m.body == Self.lockedCopy)
                #expect(!m.title.lowercased().contains(Self.doseDidNotHappenWord))
                #expect(!m.body.lowercased().contains(Self.doseDidNotHappenWord))
            }
        }
    }

    // MARK: - Through-the-broker coalesce-independence + governed-suppressibility
    // (NotificationCoordinatorTests' harness — a fake NotificationRuntime + the REAL NotificationPoster,
    // NOT a raw pre-governance notificationSink capture.)

    private func at(_ h: Int, _ m: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h, minute: m))!
    }
    private func isolatedStore(_ name: String) -> UserDefaults {
        let suite = "test.17-13.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test
    func indeterminateAndReconciliationDeliverThroughTheRealBrokerWithDistinctIdentifiersAndNeitherCoalescesTheOther() {
        let rt = NotificationRuntime(store: isolatedStore(#function))
        let indeterminateMsg = NotificationBroker.Message(
            category: .bolusIndeterminate, severity: .warning, title: Self.lockedCopy, body: Self.lockedCopy,
            dedupeKey: "indeterminate-local-X")
        let reconciliationMsg = NotificationBroker.Message(
            category: .bolusReconciliation, severity: .info, title: "Bolus delivered", body: "Reconciled: 1.0 U.",
            dedupeKey: "reconcile-local-X")
        var identifiers: [String] = []
        let d1 = NotificationPoster.post(indeterminateMsg, runtime: rt, now: at(9, 0)) {
            identifiers.append($0.identifier)
        }
        let d2 = NotificationPoster.post(reconciliationMsg, runtime: rt, now: at(9, 1)) {
            identifiers.append($0.identifier)
        }
        #expect(d1.deliver, "the immediate governed heads-up must deliver under a normal config")
        #expect(d2.deliver, "the never-suppressible authoritative resolution must always deliver")
        #expect(Set(identifiers).count == 2, "distinct OS identifiers — neither post coalesces the other")
        #expect(identifiers == ["indeterminate-local-X", "reconcile-local-X"])
    }

    @Test func governedBolusIndeterminateIsSuppressibleUnderAHostileConfigButBolusReconciliationStillDelivers() {
        let rt = NotificationRuntime(
            store: isolatedStore(#function),
            settings: [.bolusIndeterminate: NotificationBroker.CategorySettings(enabled: false)])
        let indeterminateMsg = NotificationBroker.Message(
            category: .bolusIndeterminate, severity: .warning, title: Self.lockedCopy, body: Self.lockedCopy,
            dedupeKey: "indeterminate-local-Y")
        let reconciliationMsg = NotificationBroker.Message(
            category: .bolusReconciliation, severity: .warning, title: "Bolus not delivered",
            body: "Interrupted before the pump accepted it — not delivered.", dedupeKey: "reconcile-local-Y")
        var identifiers: [String] = []
        let dIndet = NotificationPoster.post(indeterminateMsg, runtime: rt, now: at(9, 0)) {
            identifiers.append($0.identifier)
        }
        let dRecon = NotificationPoster.post(reconciliationMsg, runtime: rt, now: at(9, 1)) {
            identifiers.append($0.identifier)
        }
        #expect(
            !dIndet.deliver && dIndet.reason == .categoryDisabled,
            "a governed .bolusIndeterminate honors a user disable — proving it is genuinely governed, not a safety trio member"
        )
        #expect(
            dRecon.deliver,
            "the never-suppressible .bolusReconciliation is unaffected by the governed category's settings")
    }
}
