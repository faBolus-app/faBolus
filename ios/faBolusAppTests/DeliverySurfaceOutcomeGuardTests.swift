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
        let rec = EchoRecorder()
        rec.attach(to: model)
        if connected { await backend.connect() }
        return (model, backend, rec)
    }

    /// A model whose global delivery block is forced ON from construction (`forceNoDurableStore`), so a
    /// `.blocked` outcome is reached deterministically without a live in-flight collision.
    private func makeGloballyBlockedModel() async -> (AppModel, MockBackend, EchoRecorder) {
        let backend = MockBackend()
        await backend.connect()
        let store = R3CLedgerFaultTests.FakeLedgerStore()
        let model = AppModel(source: backend, ledgerStore: store, forceNoDurableStore: true)
        let rec = EchoRecorder()
        rec.attach(to: model)
        return (model, backend, rec)
    }

    /// Mirrors `AppModelBehaviorTests.withCleanSettings` (not `R3CLedgerFaultTests`' narrower version):
    /// `deliverExtendedBolus` also runs through the P14 S2 app-mode gate, so `appMode` must be baselined
    /// to `.advanced` or every extended-bolus case here fails closed on "needs Advanced mode" before ever
    /// reaching the outcome mapping this suite exists to pin.
    private func withCleanSettings(_ body: () async throws -> Void) async rethrows {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled, mode = s.appMode
        s.phoneReadOnly = false
        s.childModeEnabled = false
        s.appMode = .advanced
        defer {
            s.phoneReadOnly = ro
            s.childModeEnabled = child
            s.appMode = mode
        }
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
            let (model, _, _) = await makeModel(connected: false)  // not connected → BolusError.notConnected
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
            // REMED-17 (Plan 17-13, D3-01 owner-authorized convergence): the widget's USER-FACING returned
            // `error` now converges onto the shared locked copy (same wording every surface uses) — the
            // PEER-WIRE `.unknown` echo `message` (`rec.last?.message`, checked in
            // BolusIndeterminateNotificationTests' echo-payload-unchanged assertions) stays the ORIGINAL
            // shorter `Self.indeterminateWidgetMessage` string, byte-identical.
            #expect(r.error == Self.indeterminateLocalMessage)
            #expect(rec.last?.requestId == "w-indet")
            #expect(rec.last?.status == .unknown)
            #expect(
                rec.last?.message == Self.indeterminateWidgetMessage,
                "the peer-wire echo message must remain byte-identical to its original shorter string")
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
            let (model, _, rec) = await makeModel(connected: false)  // not connected → determinate failure
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

    // MARK: - WR-02 / VA-22: lastDeliveredUnits reports the ACTUAL committed amount (AppModel.swift :1891-1926, :2000-2010)
    //
    // The success banner must report the units the pump ACTUALLY committed (the ledger outcome's
    // `.delivered(units:cancelled:)` payload), not the frozen requested amount. `deliverBolus`/
    // `deliverExtendedBolus` reset `lastDeliveredUnits` to nil at the top of each delivery and set
    // `lastDeliveredUnits`/`lastDeliveredWasCancelled` only in the `.delivered` case.

    /// A full standard delivery (delivered == requested, not cancelled) publishes the actual committed
    /// units and a not-cancelled flag.
    @Test func localStandardFullDeliveryPublishesActualDeliveredUnits() async {
        await withCleanSettings {
            let (model, _, _) = await makeModel(connected: true)
            await model.deliverBolus(units: 2.0)
            #expect(model.lastDeliveredUnits == 2.0)
            #expect(model.lastDeliveredWasCancelled == false)
        }
    }

    /// Same for a full extended delivery — the mock returns the full `totalUnits`, so the banner reports it.
    @Test func localExtendedFullDeliveryPublishesActualDeliveredUnits() async {
        await withCleanSettings {
            let (model, _, _) = await makeModel(connected: true)
            await model.deliverExtendedBolus(totalUnits: 3.0, nowUnits: 1.0, durationMinutes: 30)
            #expect(model.lastDeliveredUnits == 3.0)
            #expect(model.lastDeliveredWasCancelled == false)
        }
    }

    /// Reset semantics — a freshly constructed model, before any delivery has settled, has no stale amount
    /// that could leak into a banner.
    @Test func lastDeliveredUnitsIsNilBeforeAnyDelivery() async {
        let (model, _, _) = await makeModel(connected: true)
        #expect(model.lastDeliveredUnits == nil)
        #expect(model.lastDeliveredWasCancelled == false)
    }

    /// Reset semantics — `lastDeliveredUnits` is cleared at the TOP of each delivery (:1918/:2000), so a
    /// prior delivery's amount can never survive into a delivery that doesn't reach `.delivered`. A full
    /// delivery publishes 2.0 U; a following indeterminate delivery (which never republishes) must clear it
    /// back to nil rather than leave the stale 2.0.
    @Test func lastDeliveredUnitsIsClearedAtTheStartOfEachDelivery() async {
        await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            await model.deliverBolus(units: 2.0)
            #expect(model.lastDeliveredUnits == 2.0)  // a real amount is now published
            backend.forceIndeterminateNextDelivery = true
            await model.deliverBolus(units: 1.0)
            #expect(model.lastError == Self.indeterminateLocalMessage)
            #expect(
                model.lastDeliveredUnits == nil,
                "the reset at the top of deliverBolus must clear the prior 2.0 U — an indeterminate outcome never republishes lastDeliveredUnits"
            )
        }
    }

    // The CORE case WR-02/VA-22 fixes — a mid-flight cancel/partial where the pump commits LESS than
    // requested. `DeliveryLedgerCoordinator.runLedgeredDelivery` builds `.delivered(units:cancelled:)` from
    // `delivered = try await deliver()` and `cancelled = source.lastBolusCancelled`. Driven via MockBackend's
    // one-shot `forceNextDeliveryPartial` seam (added with this test). The load-bearing assertion:
    // `lastDeliveredUnits` is the ACTUAL committed amount, NOT the frozen requested amount the pre-fix banner
    // reported — the full-delivery tests above can't prove this because there delivered == requested.

    /// Standard delivery cut short: requested 2.0 U, pump commits only 0.5 U and reports cancelled. The
    /// banner state must publish 0.5 U (actual) and cancelled == true, never the requested 2.0 U.
    @Test func localStandardCancelledPartialPublishesActualNotRequested() async {
        await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            backend.forceNextDeliveryPartial = (delivered: 0.5, cancelled: true)
            await model.deliverBolus(units: 2.0)
            #expect(model.lastDeliveredUnits == 0.5)  // ACTUAL committed, NOT the requested 2.0
            #expect(model.lastDeliveredWasCancelled == true)
        }
    }

    /// Extended delivery cut short: requested 3.0 U total, pump commits only 1.0 U and reports cancelled.
    @Test func localExtendedCancelledPartialPublishesActualNotRequested() async {
        await withCleanSettings {
            let (model, backend, _) = await makeModel(connected: true)
            backend.forceNextDeliveryPartial = (delivered: 1.0, cancelled: true)
            await model.deliverExtendedBolus(totalUnits: 3.0, nowUnits: 1.0, durationMinutes: 30)
            #expect(model.lastDeliveredUnits == 1.0)  // ACTUAL committed, NOT the requested 3.0
            #expect(model.lastDeliveredWasCancelled == true)
        }
    }
}
