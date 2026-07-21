import Foundation
import faBolusCore
import UIKit

/// iPhone-side receiver for the **Mac** remote, carried over `BLELink` (Bluetooth LE) so it keeps
/// working when the phone is locked or the app is backgrounded — the phone runs as a BLE peripheral
/// under the `bluetooth-peripheral` background mode. Like `PhoneRemoteHost` it translates the
/// transport's `RemoteCommand`s into `AppModel` calls and echoes status back — only the transport
/// differs.
///
/// Unlike the Apple Watch (physically paired to the phone), any Mac in range could open the BLE
/// link, so this host **authenticates the Mac before honoring anything**. A one-time 6-digit code
/// shown on the phone (Settings → Pair a Mac) drives a mutual HMAC handshake (`MacPairing`); on
/// success both ends persist a long-term token so later reconnects are automatic. Until a peer is
/// authenticated, every bolus/cancel/control/status command is dropped and no status is pushed to
/// it — the phone only exchanges `auth*` messages.
@MainActor
public final class PeerRemoteHost {
    // The raw BLE peripheral (for discovery/disconnect), wrapped in a SealedTransport that encrypts
    // every command after the handshake — so ongoing traffic is never cleartext (see SealedTransport).
    private let bleLink = BLELink(role: .peripheral, displayName: UIDevice.current.name)
    private let link: SealedTransport
    private weak var model: AppModel?
    private let pairing = MacPairingCoordinator.shared

    // Per-connection auth state. Reset whenever the link drops.
    private var authenticated = false
    private var peerClientId: String?
    private var peerName: String?
    private var macNonce: Data?
    private var phoneNonce: Data?
    private var secret: Data?          // code-derived (first pairing) or the stored token (reconnect)
    private var firstPairing = false
    private var pairingCode: String?   // the code in use, needed to seal the token on first pairing

    public init(model: AppModel) {
        self.model = model
        self.link = SealedTransport(inner: bleLink)
        link.onReceive = { [weak self] cmd in self?.handle(cmd) }
        link.onReachabilityChange = { [weak self] reachable in
            if !reachable { self?.resetAuth() }
        }
        // Status/echo go out only to an authenticated Mac (no glucose/pump leak to an unpaired peer).
        model.addRemoteEcho { [weak self] cmd in
            guard let self, self.authenticated else { return }
            self.link.send(cmd)
        }
        model.addStatusListener { [weak self] _ in
            guard let self, self.authenticated, let m = self.model else { return }
            self.link.send(m.statusCommand(includeHistory: true))
        }
        // If the user revokes a Mac that's currently connected, drop it immediately.
        pairing.onForget = { [weak self] id in
            RemotePeerPolicyStore.remove(id)   // drop the revoked peer's permissions too
            guard let self, id == self.peerClientId else { return }
            self.resetAuth()
            self.bleLink.disconnectAll()
        }
    }

    private func resetAuth() {
        authenticated = false
        peerClientId = nil; peerName = nil; macNonce = nil; phoneNonce = nil
        secret = nil; firstPairing = false; pairingCode = nil
        link.endSession()   // next connection must re-handshake before any real command flows
        pairing.setConnected(false, name: nil)
    }

    /// Stop advertising and drop any connection (called when the user turns remote Bluetooth off).
    public func stop() {
        resetAuth()
        bleLink.stop()
    }

    private func handle(_ cmd: RemoteCommand) {
        switch cmd.kind {
        case .authHello, .authProof:
            handleAuth(cmd)
        case .authChallenge, .authResult:
            break   // phone-outbound only
        default:
            guard authenticated else { return }   // gate: ignore commands from an unauthenticated Mac
            handleCommand(cmd)
        }
    }

    // MARK: - Handshake (phone = verifier)

    private func handleAuth(_ cmd: RemoteCommand) {
        switch cmd.kind {
        case .authHello:
            guard let clientId = cmd.authClientId,
                  let mNonceB64 = cmd.authNonce, let mNonce = Data(base64Encoded: mNonceB64) else { return }
            let name = cmd.message ?? "Mac"
            // Choose the secret: a known Mac reconnects with its token; a new Mac needs an open code.
            if let token = pairing.token(for: clientId) {
                secret = token; firstPairing = false; pairingCode = nil
            } else if let code = pairing.validCode() {
                secret = MacPairing.secret(code: code); firstPairing = true; pairingCode = code
            } else {
                link.send(.auth(.authResult, ok: false,
                                message: "Open “Pair a Mac” in faBolus on your iPhone, then enter the code."))
                return
            }
            peerClientId = clientId; peerName = name; macNonce = mNonce
            let pNonce = MacPairing.newNonce(); phoneNonce = pNonce
            link.send(.auth(.authChallenge, nonce: pNonce.base64EncodedString()))

        case .authProof:
            guard let clientId = peerClientId, let mNonce = macNonce, let pNonce = phoneNonce,
                  let secret, let proof = cmd.authProof else { return }
            guard MacPairing.verify(proof, secret: secret, label: "mac",
                                    phoneNonce: pNonce, macNonce: mNonce, clientId: clientId) else {
                link.send(.auth(.authResult, ok: false, message: "Incorrect code. Try again."))
                // Keep the code window open so the user can retry, but drop this attempt's state.
                peerClientId = nil; macNonce = nil; phoneNonce = nil; self.secret = nil
                return
            }
            // Verified. On first pairing, mint + persist a long-term token and seal it for the Mac.
            var sealed: String?
            if firstPairing, let code = pairingCode {
                let token = MacPairing.newToken()
                pairing.authorize(clientId: clientId, name: peerName ?? "Mac", token: token)
                RemotePeerPolicyStore.ensureDefault(for: clientId)   // new peer starts view-only
                sealed = MacPairing.sealToken(token, code: code)
            }
            let phoneProof = MacPairing.proof(secret: secret, label: "phone",
                                              phoneNonce: pNonce, macNonce: mNonce, clientId: clientId)
            authenticated = true
            // Turn on channel encryption for the rest of this connection BEFORE any non-auth send.
            link.activateSession(secret: secret, phoneNonce: pNonce, macNonce: mNonce)
            pairing.setConnected(true, name: peerName)
            link.send(.auth(.authResult, proof: phoneProof, sealedToken: sealed, ok: true))
            // Now that the Mac is trusted, send it a full snapshot.
            if let m = model { link.send(m.statusCommand(includeHistory: true)) }

        default:
            break
        }
    }

    // MARK: - Authenticated commands (unchanged behavior)

    /// The authenticated peer's granted policy (permissions + bolus-approval mode). A peer with no
    /// stored policy is a pre-existing full grant (the Mac paired before policies); new peers are
    /// view-only until the host grants more.
    private var policy: RemotePeerPolicy {
        RemotePeerPolicyStore.effectivePolicy(for: peerClientId ?? "")
    }

    /// Reject a command the peer isn't permitted to run, echoing a failure back.
    private func deny(_ requestId: String) {
        link.send(RemoteCommand(kind: .bolusStatus, requestId: requestId,
                                status: .failed, message: "Not permitted for this remote"))
    }

    /// Global read-only clamp (Settings → Remote access): block insulin-affecting writes over BLE
    /// regardless of a peer's granted permissions. Status, cancel (stops insulin), and alert-dismiss
    /// stay allowed.
    private var readOnly: Bool { AppSettings.shared.remoteBluetoothReadOnly }

    private func handleCommand(_ cmd: RemoteCommand) {
        guard let model else { return }
        let policy = self.policy
        switch cmd.kind {
        case .bolusRequest:
            guard !readOnly else { deny(cmd.requestId); return }
            guard policy.allows(.bolus) else { deny(cmd.requestId); return }
            Task {
                let units: Double
                if let carbs = cmd.carbsGrams, carbs > 0 {
                    let rec = await model.recommendBolus(carbsGrams: carbs, bgMgdl: cmd.bgMgdl.map(Int.init) ?? model.snapshot.glucose)
                    units = rec.recommendedUnits
                } else {
                    units = cmd.units ?? 0
                }
                guard units > 0 else {
                    self.link.send(RemoteCommand(kind: .bolusStatus, requestId: cmd.requestId,
                                                 status: .failed, message: "No insulin needed"))
                    return
                }
                // An authorized peer overrides child lock (enforceChildLock: false). Approval mode
                // decides whether the host executes directly or must approve on-device first.
                if policy.approvalMode == .hostApproval {
                    model.presentRemoteBolus(requestId: cmd.requestId, units: units, enforceChildLock: false)
                } else {
                    await model.remoteDeliver(requestId: cmd.requestId, units: units, enforceChildLock: false)
                }
            }
        case .cancelBolus:
            guard policy.allows(.cancelBolus) else { deny(cmd.requestId); return }
            Task { await model.cancelBolus(enforceChildLock: false) }
        case .dismissAlert:
            guard policy.allows(.dismissAlerts) else { deny(cmd.requestId); return }
            if let id = cmd.alertId, let k = cmd.alertKind {
                Task { await model.dismissAlert(id: id, kind: k, enforceChildLock: false); self.link.send(model.statusCommand(includeHistory: true)) }
            }
        case .statusRead:
            link.send(model.statusCommand(includeHistory: true))   // viewing is always allowed
        case .suspendPump:
            guard !readOnly, policy.allows(.suspendResume) else { deny(cmd.requestId); return }
            model.requestRemoteControl(requestId: cmd.requestId, action: .suspend)
        case .resumePump:
            guard !readOnly, policy.allows(.suspendResume) else { deny(cmd.requestId); return }
            model.requestRemoteControl(requestId: cmd.requestId, action: .resume)
        default:
            break
        }
    }
}
