import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins that `MobiRejectBackstop` tears down a Mobi identity with no SwiftUI view mounted. View-anchored `.onChange` observers never fire while backgrounded.
@Suite(.serialized) @MainActor
struct MobiRejectBackstopBoundaryTests {
    private func makeModel(isMobi: Bool) -> (AppModel, MockBackend) {
        let backend = MockBackend(isMobi: isMobi)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobi-reject-backstop-\(UUID().uuidString).json")
        return (AppModel(source: backend, ledgerStoreURL: url), backend)
    }

    @Test func backstopRejectsMobiDetectedWithNoViewOnScreen() async {
        let (model, backend) = makeModel(isMobi: false)

        // Starts as t:slim — sanity, mirrors `tslimStillPairsAndDelivers`'s starting state.
        #expect(model.snapshot.pumpModel != .mobi)
        #expect(model.lastError == nil)

        // No view of any kind is constructed in this test. This is the only observer of `model`.
        let backstop = MobiRejectBackstop(model: model)
        backstop.start()

        // The transition: a mid-session identity flip via the backend's `onChange` → `AppModel.refresh()`
        // — precisely what a real backgrounded Mobi (re)discovery drives, with zero foreground UI.
        backend.simulatePumpIdentityChange(isMobi: true)
        #expect(model.snapshot.pumpModel == .mobi)   // the momentary-true fact (RESEARCH Pitfall 3)

        // `MobiRejectBackstop`'s re-arm hop is a `Task { @MainActor in ... }` (see its doc comment) —
        // it's merely ENQUEUED at the synchronous point above, not run yet. Give the main actor's queue
        // turns to drain it before asserting the outcome.
        var iterations = 0
        while model.lastError == nil && iterations < 50 {
            await Task.yield()
            iterations += 1
        }

        // OUTCOME: torn down by the backstop alone — no `.onChange`, no view, no foreground trigger.
        #expect(model.lastError == MobiRejectCopy.mobiNotSupported)
        #expect(model.snapshot.connection == .disconnected)
        #expect(model.savePinPrompt == nil)
        #expect(model.savedPin == nil)
    }

    /// A Mobi that is already the current identity before `start()` must still be rejected — observation
    /// fires only on the next mutation, so `start()` calls `rejectMobiIfDetected()` synchronously first.
    @Test func backstopRejectsAlreadyCurrentMobiAtStartup() {
        let (model, _) = makeModel(isMobi: true)

        // The Mobi identity is already present, before ANY observer (foreground or this backstop) runs.
        #expect(model.snapshot.pumpModel == .mobi)
        #expect(model.lastError == nil)

        // No view of any kind is constructed; this is the only observer of `model`. `start()`'s pre-arm
        // `rejectMobiIfDetected()` runs synchronously — no transition, no `.onChange`, no re-arm hop.
        let backstop = MobiRejectBackstop(model: model)
        backstop.start()

        // OUTCOME: torn down against the ALREADY-CURRENT value, purely by `start()`'s pre-arm reject.
        #expect(model.lastError == MobiRejectCopy.mobiNotSupported)
        #expect(model.snapshot.connection == .disconnected)
        #expect(model.savePinPrompt == nil)
        #expect(model.savedPin == nil)
    }

    /// Companion negative check: a backend that never becomes Mobi never trips the backstop — it must
    /// stay a true no-op for the kept t:slim path (mirrors `tslimStillPairsAndDelivers`).
    @Test func backstopIsNoOpWhenNeverMobi() async {
        let (model, backend) = makeModel(isMobi: false)
        let backstop = MobiRejectBackstop(model: model)
        backstop.start()

        backend.seedFreshGlucose(150)   // an unrelated snapshot change, to exercise the re-arm loop
        var iterations = 0
        while iterations < 10 { await Task.yield(); iterations += 1 }

        #expect(model.snapshot.pumpModel != .mobi)
        #expect(model.lastError == nil)
    }
}
