import Testing
import Foundation
import faBolusCore
import HistoryStore
@testable import faBolus

/// Phase 09-01, gap A5 (guards-FIRST, D-01) — characterizes each delivery surface's
/// `DeliveryOutcome` → echo/`lastError`/return mapping (local standard `deliverBolus`/`performLocalBolus`
/// `:1474-1513`, local extended `deliverExtendedBolus` `:1564-1594`, the widget `deliverWidgetBolus`
/// `:2588-2631`, and the remote-resolved `executeResolved` `:2512-2550`) BEFORE Wave 2 introduces thin
/// per-surface adapters over the extracted `DeliveryLedgerCoordinator` (D-04). Every adapter Wave 2 writes
/// must reproduce this exact mapping — a later change that alters which string/status a surface reports
/// for delivered/failed/blocked/indeterminate turns one of these guards RED.
///
/// Reuses `MockBackend` + a minimal `EchoRecorder` (mirroring `AppModelBehaviorTests`' own), and
/// `R3CLedgerFaultTests.FakeLedgerStore` (via `forceNoDurableStore`) to drive a deterministic global
/// BLOCKED outcome without racing a live in-flight delivery. Adds no production seam.
///
/// NOT covered: `deliverExtendedBolus`'s pre-flight `capabilities.supportsExtendedBolus == false` refusal
/// — `MockBackend.capabilities` has no knob to report that (`.mobiAdvanced`/`.full` both default it true),
/// and hand-writing a second `PumpBackend` conformer (~40 methods) just to flip one capability bit is out
/// of proportion to a characterization-only task; the refusal message itself
/// ("This pump doesn't support an extended bolus.", `AppModel.swift:1570`) is a one-line, easily-reviewed
/// guard clause, unlike the outcome-mapping switches this suite exists to pin.
@Suite(.serialized)
@MainActor
struct DeliverySurfaceOutcomeGuardTests {

    // MARK: - Test harness (mirrors AppModelBehaviorTests.makeModel / EchoRecorder)

    @MainActor
    final class EchoRecorder {
        private(set) var commands: [RemoteCommand] = []
        func attach(to model: AppModel) { model.addRemoteEcho { [weak self] c in self?.commands.append(c) } }
        var last: RemoteCommand? { commands.last }
    }

    private func makeModel(connected: Bool) async -> (AppModel, MockBackend, EchoRecorder) {
        let backend = MockBackend()
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("a5-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        let rec = EchoRecorder(); rec.attach(to: model)
        if connected { await backend.connect() }
        return (model, backend, rec)
    }

    /// A model whose global delivery block is forced ON from construction (`forceNoDurableStore`), so a
    /// `.blocked` outcome is reached deterministically without a live in-flight collision.
    private func makeGloballyBlockedModel() async -> (AppModel, MockBackend, EchoRecorder) {
        let backend = MockBackend(); await backend.connect()
        let store = R3CLedgerFaultTests.FakeLedgerStore()
        let model = AppModel(source: backend, ledgerStore: store, forceNoDurableStore: true)
        let rec = EchoRecorder(); rec.attach(to: model)
        return (model, backend, rec)
    }

    /// Mirrors `AppModelBehaviorTests.withCleanSettings` (not `R3CLedgerFaultTests`' narrower version):
    /// `deliverExtendedBolus` also runs through the P14 S2 app-mode gate, so `appMode` must be baselined
    /// to `.advanced` or every extended-bolus case here fails closed on "needs Advanced mode" before ever
    /// reaching the outcome mapping this suite exists to pin.
    private func withCleanSettings(_ body: () async throws -> Void) async rethrows {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled, mode = s.appMode
        s.phoneReadOnly = false; s.childModeEnabled = false; s.appMode = .advanced
        defer { s.phoneReadOnly = ro; s.childModeEnabled = child; s.appMode = mode }
        try await body()
    }

    private static let indeterminateLocalMessage =
        "Bolus sent but outcome is unknown — verify on the pump before retrying."
    private static let indeterminateWidgetMessage =
        "Bolus sent but outcome is unknown — verify on the pump."
    private static let notConnectedMessage = "Not connected to a pump."

    // MARK: - Local standard: deliverBolus / performLocalBolus (:1474-1513)

    @Test func localStandardDeliveredClearsLastErrorAndRecordsCarbs() async {
        await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            let historyStore = try! GlucoseHistoryStore(inMemory: true)
            model.setHistoryStoreForTesting(historyStore)
            await model.deliverBolus(units: 2.0, carbsGrams: 15)
            #expect(model.lastError == nil)
            #expect(backend.snapshot.lastBolusUnits == 2.0)
            let window = Date().addingTimeInterval(-60)...Date().addingTimeInterval(60)
            #expect(!historyStore.carbs(in: window).isEmpty, "carbs > 0 must be recorded to history")
        }
    }

    @Test func localStandardFailedSetsLastErrorAndNotifiesDeliveryFailed() async {
        await withCleanSettings {
            let (model, _, _) = await makeModel(connected: false)   // not connected → BolusError.notConnected
            var posted: [NotificationBroker.Message] = []
            model.notificationSink = { msg, _, _ in posted.append(msg) }
            await model.deliverBolus(units: 1.0)
            #expect(model.lastError == Self.notConnectedMessage)
            #expect(posted.contains { $0.category == .bolusDeliveryFailed })
        }
    }

    @Test func localStandardIndeterminateSetsTheUnknownOutcomeMessage() async {
        await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            backend.forceIndeterminateNextDelivery = true
            await model.deliverBolus(units: 1.0)
            #expect(model.lastError == Self.indeterminateLocalMessage)
        }
    }

    // MARK: - Local extended: deliverExtendedBolus (:1564-1594)

    @Test func localExtendedDeliveredClearsLastError() async {
        await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            await model.deliverExtendedBolus(totalUnits: 2.0, nowUnits: 1.0, durationMinutes: 30)
            #expect(model.lastError == nil)
            #expect(backend.snapshot.lastBolusUnits == 2.0)
        }
    }

    @Test func localExtendedFailedSetsLastErrorAndNotifiesDeliveryFailed() async {
        await withCleanSettings {
            let (model, _, _) = await makeModel(connected: false)
            var posted: [NotificationBroker.Message] = []
            model.notificationSink = { msg, _, _ in posted.append(msg) }
            await model.deliverExtendedBolus(totalUnits: 2.0, nowUnits: 1.0, durationMinutes: 30)
            #expect(model.lastError == Self.notConnectedMessage)
            #expect(posted.contains { $0.category == .bolusDeliveryFailed })
        }
    }

    @Test func localExtendedIndeterminateSetsTheUnknownOutcomeMessage() async {
        await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            backend.forceIndeterminateNextDelivery = true
            await model.deliverExtendedBolus(totalUnits: 2.0, nowUnits: 1.0, durationMinutes: 30)
            #expect(model.lastError == Self.indeterminateLocalMessage)
        }
    }

    // MARK: - Widget: deliverWidgetBolus (:2588-2631) — return TUPLE + echo

    @Test func widgetDeliveredReturnsUnitsAndEchoesTheOutcome() async {
        await withCleanSettings {
            let (model, _, rec) = await makeModel(connected: true)
            let r = await model.deliverWidgetBolus(requestId: "w-del", units: 2.0)
            #expect(r.delivered == 2.0)
            #expect(r.cancelled == false)
            #expect(r.error == nil)
            #expect(rec.last?.requestId == "w-del")
            #expect(rec.last?.status == .delivered)
        }
    }

    @Test func widgetGlobalBlockReturnsZeroAndEchoesFailed() async {
        await withCleanSettings {
            let (model, _, rec) = await makeGloballyBlockedModel()
            let r = await model.deliverWidgetBolus(requestId: "w-blocked", units: 2.0)
            #expect(r.delivered == 0)
            #expect(r.cancelled == false)
            #expect(r.error != nil)
            #expect(rec.last?.requestId == "w-blocked")
            #expect(rec.last?.status == .failed)
        }
    }

    @Test func widgetIndeterminateReturnsZeroAndEchoesTheUnknownVariant() async {
        await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            backend.forceIndeterminateNextDelivery = true
            let r = await model.deliverWidgetBolus(requestId: "w-indet", units: 1.0)
            #expect(r.delivered == 0)
            #expect(r.cancelled == false)
            // The widget's indeterminate string is its OWN shorter variant (:2621) — distinct from the
            // local surfaces' "…before retrying." wording pinned above.
            #expect(r.error == Self.indeterminateWidgetMessage)
            #expect(rec.last?.requestId == "w-indet")
            #expect(rec.last?.status == .unknown)
        }
    }

    // MARK: - Remote-resolved: executeResolved via remoteDeliver (:2512-2550)

    @Test func remoteResolvedDeliveredEchoesTheOutcomeAndClearsLastError() async {
        await withCleanSettings {
            let (model, _, rec) = await makeModel(connected: true)
            await model.remoteDeliver(requestId: "r-del", units: 2.0, peerId: "watch")
            #expect(rec.last?.requestId == "r-del")
            #expect(rec.last?.status == .delivered)
            #expect(model.lastError == nil)
        }
    }

    @Test func remoteResolvedGlobalBlockEchoesFailedAndSetsLastError() async {
        await withCleanSettings {
            let (model, _, rec) = await makeGloballyBlockedModel()
            await model.remoteDeliver(requestId: "r-blocked", units: 2.0, peerId: "watch")
            #expect(rec.last?.requestId == "r-blocked")
            #expect(rec.last?.status == .failed)
            #expect(model.lastError != nil)
        }
    }

    @Test func remoteResolvedFailedEchoesFailedAndSetsLastError() async {
        await withCleanSettings {
            let (model, _, rec) = await makeModel(connected: false)   // not connected → determinate failure
            await model.remoteDeliver(requestId: "r-failed", units: 1.0, peerId: "watch")
            #expect(rec.last?.requestId == "r-failed")
            #expect(rec.last?.status == .failed)
            #expect(model.lastError == Self.notConnectedMessage)
        }
    }

    @Test func remoteResolvedIndeterminateEchoesTheUnknownStatus() async {
        await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            backend.forceIndeterminateNextDelivery = true
            await model.remoteDeliver(requestId: "r-indet", units: 1.0, peerId: "watch")
            #expect(rec.last?.requestId == "r-indet")
            #expect(rec.last?.status == .unknown)
            #expect(model.lastError == Self.indeterminateLocalMessage)
        }
    }

    /// `r.units <= 0` (:2513) short-circuits BEFORE the ledgered delivery even starts — echoes a
    /// dedicated "No insulin needed" failure and never touches the pump.
    @Test func remoteResolvedZeroUnitsEchoesNoInsulinNeededWithoutDelivering() async {
        await withCleanSettings {
            let (model, backend, rec) = await makeModel(connected: true)
            let startIob = backend.snapshot.iobUnits
            await model.remoteDeliver(requestId: "r-zero", units: 0, peerId: "watch")
            #expect(rec.last?.requestId == "r-zero")
            #expect(rec.last?.status == .failed)
            #expect(rec.last?.message == "No insulin needed")
            #expect(backend.snapshot.iobUnits == startIob)
            #expect(backend.lastAssignedBolusId == nil)
        }
    }
}
