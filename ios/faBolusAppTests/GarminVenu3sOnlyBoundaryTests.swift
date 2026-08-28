import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 2 (garmin-venu-3s-only) D-08 — a still-GREEN regression pin, not a RED→GREEN cycle: Phase 2
/// narrows the Garmin *device* surface (`../faBolusGarmin` manifests/jungles) and removes the standalone
/// watch-face app; it touches ZERO iOS delivery code. This test proves the kept `.garmin` remote-bolus
/// seam — `GarminRemoteBridge.handle` → `AppModel.remoteDeliver(from: .garmin, peerId: "garmin")` — is
/// undisturbed by that narrowing.
///
/// Wording reconciliation: ROADMAP's Phase-2 success criteria describe the Garmin remote path as
/// routing through the WatchConnectivity transport host — that type was the receiver used by the
/// Apple-Watch surface (retired entirely in Phase 17.5, D1-01). The Garmin path never went through
/// it; it routes from `GarminRemoteBridge` straight to `AppModel.remoteDeliver(from: .garmin, ...)`
/// (see R4). This test pins the ACTUAL seam.
///
/// R4 (ConnectIQ-free): calls `AppModel.remoteDeliver` directly against a `MockBackend` — no
/// `import ConnectIQ`, no `GarminRemoteBridge` instantiation. The Connect IQ SDK dependency lives only
/// inside the bridge; the deliver logic itself is SDK-agnostic.
@Suite(.serialized) @MainActor
struct GarminVenu3sOnlyBoundaryTests {
    private final class Box { var echoes: [RemoteCommand] = [] }

    private func makeModel() -> (AppModel, MockBackend, Box) {
        let backend = MockBackend()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gvb-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: url)
        let box = Box()
        model.addRemoteEcho { cmd in box.echoes.append(cmd) }
        return (model, backend, box)
    }

    /// Clean gate state for a `.garmin` deliver (bolusing ON, not read-only, no child lock, no passcode
    /// armed) so the test exercises only the seam under test, restoring everything after.
    private func withClean(_ body: () async -> Void) async {
        let s = AppSettings.shared
        let child = s.childModeEnabled, rro = s.remotesReadOnly, gbe = s.garminBolusEnabled
        s.childModeEnabled = false
        s.remotesReadOnly = false
        s.garminBolusEnabled = true
        await body()
        s.childModeEnabled = child
        s.remotesReadOnly = rro
        s.garminBolusEnabled = gbe
    }

    @Test func garminRemotePathStillDeliversABolusRequest() async {
        await withClean {
            let (model, backend, box) = makeModel()
            await backend.connect()

            await model.remoteDeliver(
                requestId: "boundary", units: 1.0, passcode: nil,
                from: .garmin, peerId: "garmin")

            // A non-failed bolusStatus echo (delivered/cancelled) — or, failing that, the MockBackend
            // recorded the matching deliverBolus call — proves the kept `.garmin` seam still delivers.
            let deliveredOrCancelled = box.echoes.contains {
                $0.requestId == "boundary" && $0.kind == .bolusStatus
                    && ($0.status == .delivered || $0.status == .cancelled)
            }
            let backendRecordedTheDeliver = backend.lastDeliver?.units == 1.0
            #expect(deliveredOrCancelled || backendRecordedTheDeliver)
            #expect(!box.echoes.contains { $0.requestId == "boundary" && $0.status == .failed })
        }
    }

    // MARK: - Phase 3 (03-02, REMOTE-02, D-03/Pitfall C) — the kept `.quickBolusWidget` delivery seam

    /// Pins the REAL widget call chain after the peer remote's removal: `WidgetBolusReceiver.swift:81`
    /// calls `AppModel.deliverWidgetBolus(...)` for a units-mode request — NOT `remoteDeliver`, and NOT
    /// through the (now-retired) WatchConnectivity host (Pitfall C). `deliverWidgetBolus` builds its own
    /// `accessDecision(..., from: .quickBolusWidget)` internally.
    @Test func quickBolusWidgetUnitsPathStillDeliversABolusRequest() async {
        await withClean {
            let (model, backend, box) = makeModel()
            await backend.connect()

            let out = await model.deliverWidgetBolus(requestId: "boundary-widget-units", units: 1.0)

            #expect(out.error == nil)
            let deliveredOrCancelled = box.echoes.contains {
                $0.requestId == "boundary-widget-units" && $0.kind == .bolusStatus
                    && ($0.status == .delivered || $0.status == .cancelled)
            }
            let backendRecordedTheDeliver = backend.lastDeliver?.units == 1.0
            #expect(deliveredOrCancelled || backendRecordedTheDeliver)
            #expect(!box.echoes.contains { $0.requestId == "boundary-widget-units" && $0.status == .failed })
        }
    }

    /// The carbs-mode widget path (`WidgetBolusReceiver.swift:66-67`) does NOT deliver in place — it
    /// calls `AppModel.presentRemoteBolus(..., from: .quickBolusWidget, peerId: "widget")` to freeze the
    /// real dose for an in-app confirm (audit C-03). Pins that this seam still reaches the evaluator and
    /// stages a pending approval — the real chain, not `remoteDeliver`/the retired WatchConnectivity host.
    @Test func quickBolusWidgetCarbsPathStillPresentsForInAppApproval() async {
        await withClean {
            let (model, backend, _) = makeModel()
            await backend.connect()
            let est = await model.recommendBolus(carbsGrams: 20, bgMgdl: nil).recommendedUnits

            await model.presentRemoteBolus(
                requestId: "boundary-widget-carbs", units: 0, carbsGrams: 20,
                bgMgdl: nil, remoteEstimate: est,
                from: .quickBolusWidget, peerId: "widget")

            #expect(model.pendingRemoteBolus != nil)
            #expect(model.pendingRemoteBolus?.carbsGrams == 20)
        }
    }

    // D-04 (superseded, Phase 17.5/D1-01): this file previously carried a compile-only proof that
    // the WatchConnectivity transport host still resolved as a type — that host is now deleted
    // entirely, so there is nothing left to reference here.
}
