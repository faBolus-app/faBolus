import Foundation

/// Minimal stub replacing the real Mac/peer pairing coordinator. `PeerRemoteHost` is removed, so
/// there is no remaining producer of a paired device. This stub exists solely to keep the
/// `hasPairedRemote` call site compiling.
///
/// **Consequence:** `pairedMacs` is now permanently empty, so `hasPairedRemote` is permanently
/// `false` — the Child-Mode reverse-approval branch can never fire; a child's bolus always falls
/// through to local delivery (still guarded by the pump's own passcode/limit checks). This is the
/// correct, fail-closed direction — there is no remaining approver device.
///
/// Reintegration: see `dev/phone-remote`'s `REINTEGRATION.md` for what a future re-add must restore
/// (the real, observable pairing coordinator this replaced is preserved there byte-identical).
@MainActor
final class MacPairingCoordinator {
    static let shared = MacPairingCoordinator()
    /// Always empty — no possible producer of a paired device anymore (fail-closed, F-1).
    private(set) var pairedMacs: [String] = []
    private init() {}
}
