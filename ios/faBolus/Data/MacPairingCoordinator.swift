import Foundation
import Observation
import faBolusCore

/// Shared, observable state for pairing Macs with this phone. The Settings UI drives it (start a
/// pairing window, list/forget Macs) and `PeerRemoteHost` reads/updates it during the handshake.
/// A singleton so both sides share one instance without threading it through the whole view tree.
@MainActor
@Observable
final class MacPairingCoordinator {
    static let shared = MacPairingCoordinator()

    struct PairedMac: Identifiable, Equatable { let id: String; let name: String }

    /// Macs authorized to control this phone (persisted tokens in `MacRemoteAuthStore`).
    private(set) var pairedMacs: [PairedMac] = []
    /// The 6-digit code shown while a pairing window is open, or nil.
    private(set) var activeCode: String?
    /// When the active code expires. A window lasts `codeLifetime`.
    private(set) var codeExpiry: Date?
    /// Whether an authenticated Mac is currently connected, and its name.
    private(set) var connected: Bool = false
    private(set) var connectedName: String?
    /// Set briefly after a successful pairing so the UI can confirm + prompt for this device's
    /// permissions. `justPairedClientId` keys the new peer's policy.
    var justPaired: String?
    var justPairedClientId: String?
    /// Whether the open window is QR (high-entropy code, shown as a QR to scan) vs a 6-digit code.
    private(set) var activeIsQR = false

    /// Invoked by `PeerRemoteHost` to kick a Mac whose authorization was just revoked.
    @ObservationIgnored var onForget: ((String) -> Void)?

    private static let codeLifetime: TimeInterval = 300   // 5 minutes

    private init() { reload() }

    private func reload() {
        pairedMacs = MacRemoteAuthStore.paired().map { PairedMac(id: $0.id, name: $0.name) }
    }

    // MARK: UI actions

    /// Open a pairing window and return the code to display. `viaQR` uses a high-entropy code shown as
    /// a QR (scanned, never typed); otherwise a 6-digit code the user types on the remote.
    @discardableResult
    func beginPairing(viaQR: Bool = false) -> String {
        let code = viaQR ? MacPairing.newStrongCode() : MacPairing.newCode()
        activeCode = code
        activeIsQR = viaQR
        codeExpiry = Date().addingTimeInterval(Self.codeLifetime)
        justPaired = nil
        return code
    }

    /// The QR string for the open window (nil unless a QR window is active). `hostName` must match the
    /// BLE peripheral display name so the scanning remote auto-selects this phone.
    func qrString(hostName: String) -> String? {
        guard activeIsQR, let code = validCode() else { return nil }
        return PeerPairingPayload(hostName: hostName, code: code).qrString()
    }

    func cancelPairing() { activeCode = nil; codeExpiry = nil; activeIsQR = false }

    func forget(_ id: String) {
        MacRemoteAuthStore.forget(clientId: id)
        reload()
        onForget?(id)
    }

    // MARK: Host-facing

    /// The active code if the pairing window is still open, else nil (also clears an expired one).
    func validCode() -> String? {
        guard let code = activeCode, let exp = codeExpiry else { return nil }
        if Date() >= exp { cancelPairing(); return nil }
        return code
    }

    func token(for clientId: String) -> Data? { MacRemoteAuthStore.token(for: clientId) }

    /// Persist a newly authorized Mac and close the pairing window.
    func authorize(clientId: String, name: String, token: Data) {
        MacRemoteAuthStore.authorize(clientId: clientId, token: token, name: name)
        cancelPairing()
        reload()
        justPaired = name
        justPairedClientId = clientId
    }

    // MARK: Per-device permissions (read-only vs. control), editable anytime.
    func policy(for clientId: String) -> RemotePeerPolicy { RemotePeerPolicyStore.effectivePolicy(for: clientId) }
    func setPolicy(_ policy: RemotePeerPolicy, for clientId: String) {
        RemotePeerPolicyStore.setPolicy(policy, for: clientId)
    }

    func setConnected(_ c: Bool, name: String?) {
        connected = c
        connectedName = c ? name : nil
    }
}
