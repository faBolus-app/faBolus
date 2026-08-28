import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// The kept `.garmin` remote path (`AppModel.remoteDeliver(from: .garmin)`) and the widget
/// `deliverWidgetBolus` path still deliver; neither routes through the retired WatchConnectivity host.
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
        s.childModeEnabled = false; s.remotesReadOnly = false; s.garminBolusEnabled = true
        await body()
        s.childModeEnabled = child; s.remotesReadOnly = rro; s.garminBolusEnabled = gbe
    }

    @Test func garminRemotePathStillDeliversABolusRequest() async {
        await withClean {
            let (model, backend, box) = makeModel()
            await backend.connect()

            await model.remoteDeliver(requestId: "boundary", units: 1.0, passcode: nil,
                                      from: .garmin, peerId: "garmin")

            // A non-failed bolusStatus echo (delivered/cancelled) — or, failing that, the MockBackend
            // recorded the matching deliverBolus call — proves the kept `.garmin` seam still delivers.
            let deliveredOrCancelled = box.echoes.contains {
                $0.requestId == "boundary" && $0.kind == .bolusStatus &&
                ($0.status == .delivered || $0.status == .cancelled)
            }
            let backendRecordedTheDeliver = backend.lastDeliver?.units == 1.0
            #expect(deliveredOrCancelled || backendRecordedTheDeliver)
            #expect(!box.echoes.contains { $0.requestId == "boundary" && $0.status == .failed })
        }
    }

    // MARK: - Kept `.quickBolusWidget` delivery seam

    /// Units-mode widget requests go through `AppModel.deliverWidgetBolus`, not `remoteDeliver` and not
    /// the retired WatchConnectivity host. `deliverWidgetBolus` builds its own `accessDecision(..., from:
    /// .quickBolusWidget)` internally.
    @Test func quickBolusWidgetUnitsPathStillDeliversABolusRequest() async {
        await withClean {
            let (model, backend, box) = makeModel()
            await backend.connect()

            let out = await model.deliverWidgetBolus(requestId: "boundary-widget-units", units: 1.0)

            #expect(out.error == nil)
            let deliveredOrCancelled = box.echoes.contains {
                $0.requestId == "boundary-widget-units" && $0.kind == .bolusStatus &&
                ($0.status == .delivered || $0.status == .cancelled)
            }
            let backendRecordedTheDeliver = backend.lastDeliver?.units == 1.0
            #expect(deliveredOrCancelled || backendRecordedTheDeliver)
            #expect(!box.echoes.contains { $0.requestId == "boundary-widget-units" && $0.status == .failed })
        }
    }

    /// The carbs-mode widget path does not deliver in place — it stages `presentRemoteBolus(..., from:
    /// .quickBolusWidget)` for an in-app confirm. Pins that this seam still reaches the evaluator.
    @Test func quickBolusWidgetCarbsPathStillPresentsForInAppApproval() async {
        await withClean {
            let (model, backend, _) = makeModel()
            await backend.connect()
            let est = await model.recommendBolus(carbsGrams: 20, bgMgdl: nil).recommendedUnits

            await model.presentRemoteBolus(requestId: "boundary-widget-carbs", units: 0, carbsGrams: 20,
                                           bgMgdl: nil, remoteEstimate: est,
                                           from: .quickBolusWidget, peerId: "widget")

            #expect(model.pendingRemoteBolus != nil)
            #expect(model.pendingRemoteBolus?.carbsGrams == 20)
        }
    }
}
