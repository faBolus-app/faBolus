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
/// Wording reconciliation: ROADMAP's Phase-2 success criteria describe the Garmin remote path as routing
/// "through `PhoneRemoteHost`" — that type is the WatchConnectivity / Quick-Bolus-widget receiver used by
/// the Apple Watch and widget surfaces. The Garmin path does NOT go through `PhoneRemoteHost`; it routes
/// from `GarminRemoteBridge` straight to `AppModel.remoteDeliver(from: .garmin, ...)` (see R4). This test
/// pins the ACTUAL seam.
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
}
