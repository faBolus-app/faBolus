import Foundation
import faBolusCore

/// Mobi reject-at-pairing: observe `snapshot.pumpModel` and abort via the existing public
/// `disconnect()` / `forgetPairing()`. The discovery callback legitimately sets `pumpModel == .mobi`
/// the instant a real Mobi is BLE-discovered — before pairing completes — so this tears that
/// momentary link down. No hand-rolled BLE/Keychain unwind.
extension AppModel {
    /// Reject a detected Mobi before pairing completes. A no-op when the current model identity isn't
    /// Mobi — safe to call unconditionally from every trigger, and safe to call more than once
    /// (idempotent: `disconnect()`/`forgetPairing()` are cheap no-ops once already torn down).
    ///
    /// Checks the OUTCOME-driving fact (`snapshot.pumpModel`), never asserts `isMobi` "never"
    /// becomes true — it legitimately does, momentarily, before this runs.
    ///
    /// Deliberately does NOT call `PumpModelStore.clear()` — cosmetic-only drift (a phantom Mobi
    /// unpair-confirmation copy for a user who never successfully pairs anything after upgrading),
    /// zero safety impact.
    @MainActor
    public func rejectMobiIfDetected() {
        guard snapshot.pumpModel == .mobi else { return }
        // Surface the reject message through the EXISTING `lastError` display path (already rendered
        // by `DashboardView`'s `Label(err, ...)`) — no new UI state, no protected-file edit.
        lastError = MobiRejectCopy.mobiNotSupported
        disconnect()
        forgetPairing()
    }
}

// User-facing Mobi-reject copy. Tests assert it never contains the banned phrase; this does
// NOT bless the exact wording.
enum MobiRejectCopy {
    static let mobiNotSupported =
        "Tandem Mobi isn't supported in this version of faBolus. This build supports the Tandem t:slim X2 only."
}
