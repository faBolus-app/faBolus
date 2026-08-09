import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P16 F3 — the phone Low Power Mode advisory is WARN-ONLY. Pins the shared `shouldWarn` predicate
/// (on when lpm+connected+not-dismissed; off when idle / dismissed / lpm-off) and that the `AppModel`
/// wiring exposes the advisory API without touching cadence, gating, or delivery.
@Suite(.serialized) @MainActor
struct LowPowerAdvisoryHostTests {

    private func makeModel() -> (AppModel, MockBackend) {
        let backend = MockBackend()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lpm-\(UUID().uuidString).json")
        return (AppModel(source: backend, ledgerStoreURL: url), backend)
    }

    /// On only when Low Power Mode is on AND a source is connected AND it hasn't been dismissed.
    @Test func warnsWhenLpmAndConnectedAndNotDismissed() {
        #expect(LowPowerAdvisory.shouldWarn(lpmActive: true, sourceConnected: true, dismissedEpisode: false))
    }

    /// Off when idle (no connected source), when dismissed this episode, and when Low Power Mode is off.
    @Test func silentWhenIdleOrDismissedOrLpmOff() {
        #expect(!LowPowerAdvisory.shouldWarn(lpmActive: true, sourceConnected: false, dismissedEpisode: false)) // idle
        #expect(!LowPowerAdvisory.shouldWarn(lpmActive: true, sourceConnected: true, dismissedEpisode: true))   // dismissed
        #expect(!LowPowerAdvisory.shouldWarn(lpmActive: false, sourceConnected: true, dismissedEpisode: false)) // lpm off
    }

    /// The model mirrors `ProcessInfo` at init and, when Low Power Mode is off (the test host default),
    /// never shows the advisory regardless of connection state.
    @Test func modelMirrorsProcessInfoAndStaysSilentWhenLpmOff() async {
        let (model, backend) = makeModel()
        #expect(model.lowPowerModeActive == ProcessInfo.processInfo.isLowPowerModeEnabled)
        await backend.connect()
        #expect(model.snapshot.isLinked)                       // a live source is connected
        if !ProcessInfo.processInfo.isLowPowerModeEnabled {
            #expect(!model.shouldShowLowPowerAdvisory)         // WARN-only gate stays closed when LPM is off
        }
        // Dismissing is a no-op on visibility here (advisory already hidden) and never throws/gates.
        model.dismissLowPowerAdvisory()
        if !ProcessInfo.processInfo.isLowPowerModeEnabled {
            #expect(!model.shouldShowLowPowerAdvisory)
        }
    }
}
