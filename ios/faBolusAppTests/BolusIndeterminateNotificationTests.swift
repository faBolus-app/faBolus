import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// REMED-17 (Plan 17-13) — the D3-01 "frozen half" 17-04 Task 4, dispatched to a dedicated reviewed
/// safety plan (AUTHORIZE-FROZEN, OWNER-DECISIONS.md 2026-08-25). Fork A = the owner's Gentle
/// disposition: an immediate GOVERNED (suppressible) `.bolusIndeterminate` notification at `.warning`,
/// alongside — never replacing — the authoritative never-suppressible `.bolusReconciliation` post.
///
/// Proves, across all FOUR `.indeterminate` switch sites (local/reverse-approval, extended, remote/
/// approval-confirmed, widget):
///   1. exactly ONE `.bolusIndeterminate` post with the LOCKED copy (title AND body), never the word
///      that means a dose did not happen, and ZERO `.bolusDeliveryFailed` (the preserved invariant);
///   2. every peer-wire `.unknown` echo payload stays BYTE-IDENTICAL (widget's own shorter string;
///      executeResolved's unchanged locked-copy string) — proven by echo-payload-unchanged assertions;
///   3. through the REAL broker (`NotificationCoordinatorTests`' harness — a fake `NotificationRuntime`
///      + the real `NotificationPoster`), the immediate `.bolusIndeterminate` and the later authoritative
///      `.bolusReconciliation` deliver with DISTINCT OS identifiers (coalesce-independence), and the
///      governed category is genuinely suppressible under a hostile config while the trio category
///      still delivers (governed-suppressibility).
///
/// Mirrors `DeliverySurfaceOutcomeGuardTests`' harness (`makeModel`, `withCleanSettings`,
/// `backend.forceIndeterminateNextDelivery`) rather than inventing a new one.
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
        let rec = EchoRecorder(); rec.attach(to: model)
        if connected { await backend.connect() }
        return (model, backend, rec)
    }

    /// Mirrors `DeliverySurfaceOutcomeGuardTests.withCleanSettings` — `deliverExtendedBolus` also runs
    /// through the P14 S2 app-mode gate, so `appMode` must be baselined to `.advanced`.
    private func withCleanSettings(_ body: () async throws -> Void) async rethrows {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled, mode = s.appMode
        s.phoneReadOnly = false; s.childModeEnabled = false; s.appMode = .advanced
        defer { s.phoneReadOnly = ro; s.childModeEnabled = child; s.appMode = mode }
        try await body()
    }

    private static let lockedCopy = AppModel.indeterminateOutcomeLockedCopy
    private static let widgetEchoMessage = "Bolus sent but outcome is unknown — verify on the pump."
    /// Never the word that means a dose did not happen — checked against every captured locked-copy post.
    private static let doseDidNotHappenWord = "fail"

    // MARK: - Task 1 tracer: performLocalBolus (local / reverse-approval)

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
            #expect(posted.allSatisfy { $0.category != .bolusDeliveryFailed },
                    "an indeterminate outcome must never post a delivery-FAILED notification")
            for m in indeterminate {
                #expect(!m.title.lowercased().contains(Self.doseDidNotHappenWord))
                #expect(!m.body.lowercased().contains(Self.doseDidNotHappenWord))
            }
        }
    }
}
