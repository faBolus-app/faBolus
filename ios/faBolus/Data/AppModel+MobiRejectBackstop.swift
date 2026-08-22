import Foundation
import Observation
import faBolusCore

/// Phase 9 code-review CR-01 gap closure — owner decision: a NON-dose-file backstop only (no edit to
/// `AppModel.swift`/`TandemBackend.swift`, D-08 dose-byte-identity kept green; a small residual
/// background race before ANY observer — foreground or this one — first runs is owner-accepted).
///
/// **The gap.** The reject-at-pairing gate (`AppModel.rejectMobiIfDetected()`,
/// `AppModel+MobiReject.swift`) is fired today ONLY from three foreground SwiftUI
/// `.onChange(of: model.snapshot.pumpModel)` observers (`MainHUDView`/`SettingsView`/
/// `ConnectPumpOnboardingView`). Each is anchored to a specific SwiftUI VIEW being on screen — so a
/// Mobi discovered while none of those three views is mounted (app backgrounded; a different screen
/// showing; the app relaunching into a fourth screen) evades the gate until the user happens to
/// navigate back to one of them. The app already declares BLE background modes, so a Mobi can be
/// (re)discovered while backgrounded.
///
/// **The backstop.** `MobiRejectBackstop` is ALWAYS ON: owned OUTSIDE the SwiftUI view tree (started
/// from `FaBolusApp`, alongside `PhoneRemoteHost`/`GarminRemoteBridge`/`NotificationCoordinator` — the
/// app's EXISTING pattern for AppModel-observers that must run regardless of which screen is visible),
/// observing `AppModel.snapshot` via the Observation framework's `withObservationTracking` — NOT a
/// SwiftUI `.onChange` on a view — so it keeps running whether or not any reject-observing view is
/// mounted, and while backgrounded (the process — and this observer's re-arm loop — stays alive across
/// a backgrounded pump reconnect, same as the kit's own background-safe reconnect path).
///
/// Reuses the EXISTING, already-idempotent `rejectMobiIfDetected()` — no duplicated abort logic, no new
/// `AppModel` surface. The three foreground triggers stay (defense in depth): this is an ADDITIONAL
/// always-on layer, not a replacement.
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
