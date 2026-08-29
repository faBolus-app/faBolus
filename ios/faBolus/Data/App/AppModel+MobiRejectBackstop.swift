import Foundation
import Observation
import faBolusCore

/// Always-on Mobi reject backstop, owned outside the SwiftUI view tree. The view-scoped
/// `.onChange(of: pumpModel)` observers miss a Mobi discovered while backgrounded or on a different
/// screen; this observer keeps running regardless of which screen is visible. Reuses the existing
/// `rejectMobiIfDetected()` — additional layer, not a replacement.
@MainActor
final class MobiRejectBackstop {
    private let model: AppModel
    private var running = false

    init(model: AppModel) {
        self.model = model
    }

    /// Idempotent — a duplicate `start()` (e.g. a re-triggered `onAppear`) is a harmless no-op so we
    /// never stack a second observation loop on the same model.
    func start() {
        guard !running else { return }
        running = true
        // Reject an ALREADY-CURRENT Mobi before arming future observation.
        // `withObservationTracking`'s `onChange` fires only on the NEXT mutation, never against the
        // value already present — so a Mobi made current before `start()` runs (CoreBluetooth
        // state-restoration reconnect, or a stored/identified Mobi applied before the backstop wires
        // up) would otherwise never trigger a reject. `rejectMobiIfDetected()` is @MainActor,
        // idempotent, and guards `snapshot.pumpModel == .mobi`, so this is a no-op when no Mobi is
        // present. This closes the startup-ordering gap; the delivery-boundary preflight in
        // `TandemBackend.validateDeliver` is the structural interlock that backs it up.
        model.rejectMobiIfDetected()
        observeNext()
    }

    /// Stops re-arming. Not currently called by app code (the backstop runs for the process's whole
    /// lifetime once started) — kept so a future caller, or a test, can tear it down cleanly.
    func stop() {
        running = false
    }

    /// `withObservationTracking`'s `onChange` fires exactly ONCE per registration — the standard
    /// pattern (Apple's own docs example) is to re-arm from inside the callback, which is what the
    /// recursion below does. Re-arm FIRST, then act: acting before re-arming would leave a window
    /// (between the callback firing and re-registration) during which a further change to `snapshot`
    /// wouldn't be tracked at all.
    ///
    /// The callback isn't guaranteed to run on the main actor (it fires wherever the tracked property
    /// was mutated), so every hop back into `self`/`model` (both `@MainActor`) happens inside a
    /// `Task { @MainActor in ... }`.
    private func observeNext() {
        withObservationTracking {
            // Reading the whole `snapshot` (not just `.pumpModel`) is deliberate: it's the ONLY stored
            // property the `@Observable` macro instruments here, so tracking it is what makes this
            // fire on every `AppModel.refresh()` snapshot replace — including the one that first sets
            // `pumpModel == .mobi`. `rejectMobiIfDetected()`'s own guard (`snapshot.pumpModel == .mobi`)
            // makes the extra, sometimes-redundant calls on unrelated snapshot changes a cheap no-op —
            // never a second distinct teardown with different side effects.
            _ = model.snapshot
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.observeNext()
                self.model.rejectMobiIfDetected()
            }
        }
    }
}
