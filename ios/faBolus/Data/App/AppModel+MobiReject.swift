import Foundation
import faBolusCore

/// Phase 9 Plan 01 (MOBI-01/MOBI-03, D-02/D-03/D-08): the Mobi reject-at-pairing safety gate's shared
/// observe-and-abort helper. A NEW, non-protected file — `ios/faBolus/Data/AppModel.swift` and
/// `ios/faBolus/Data/TandemBackend.swift` stay byte-identical (D-08). The protected discovery callback
/// (`TandemBackend.swift:2201-2211`, unedited) legitimately sets `snapshot.isMobi` / `snapshot.pumpModel
/// == .mobi` true the INSTANT a real Mobi is BLE-discovered — the "momentary link", owner-accepted
/// (D-03) — before any pairing negotiation completes. Three thin `.onChange(of:
/// model.snapshot.pumpModel)` triggers (`MainHUDView`/`SettingsView`/`ConnectPumpOnboardingView`, each
/// anchored at a scope that OUTLIVES the transient pairing sheet — the sheet dismisses before
/// `connectWithCode` resolves, RESEARCH Pitfall 3 / Pattern 2) call the ONE helper below, which tears
/// the attempt down via the EXISTING public `AppModel.disconnect()` / `forgetPairing()` — never a
/// hand-rolled BLE/Keychain unwind (RESEARCH Don't-Hand-Roll).
extension AppModel {
    /// Reject a detected Mobi before any pairing-completion-gated code (`evaluateSavePinOffer()`, which
    /// only fires on `.connected`/`.bolusing`) can run. A no-op when the current model identity isn't
    /// Mobi — safe to call unconditionally from every trigger, and safe to call more than once
    /// (idempotent: `disconnect()`/`forgetPairing()` are cheap no-ops once already torn down).
    ///
    /// Per RESEARCH Pitfall 3: this checks the OUTCOME-driving fact (`snapshot.pumpModel`), never
    /// asserts `isMobi` "never" becomes true — it legitimately does, momentarily, before this runs.
    ///
    /// Flag 1 (09-OWNER-FLAGS.md, owner-defaulted): deliberately does NOT call
    /// `PumpModelStore.clear()` — cosmetic-only drift (a phantom Mobi unpair-confirmation copy for a
    /// user who never successfully pairs anything after upgrading), zero safety impact, smaller diff.
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

// §13 NOTICE: this wording is DRAFT and is experimental-distribution surface — the Mobi-reject message
// must pass owner + §13 clinical review (endocrinologist / CDCES) before any `experimental` build is
// distributed (per BRANCHES.md's §13). Ship-DRAFT-now is the owner's explicit decision (09-CONTEXT.md
// D-04); final wording is v0.4.0 Phase 10's job. `MobiRejectCopyTests` asserts this never contains the
// banned phrase (REQUIREMENTS.md MOBI-03), mirroring `RegulatoryCopyTests`'s guard-only style — this
// does NOT bless the exact wording.
enum MobiRejectCopy {
    static let mobiNotSupported =
        "Tandem Mobi isn't supported in this version of faBolus. This build supports the Tandem t:slim X2 only."
}
