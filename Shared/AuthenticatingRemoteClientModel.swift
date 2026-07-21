import Foundation
import faBolusCore

/// Shared **client-side pairing handshake** for every faBolus remote that authenticates to a host
/// (the Mac remote and the iPhone remote). Runs the `MacPairing` one-time-code / token handshake over
/// a `SealedTransport` (authHello → authChallenge → authProof → authResult) and, on success, activates
/// channel encryption so all later traffic is sealed. Subclasses supply the token store (via
/// closures), this device's id/name, and platform UI hooks — they don't reimplement the handshake.
@MainActor
class AuthenticatingRemoteClientModel: RemoteClientModel {
    private let clientId: String
    private let displayName: String
    private let tokenFor: (String) -> Data?
    private let saveToken: (Data, String) -> Void

    /// Whether the host has authenticated this device (source of truth for "can send commands").
    private(set) var authenticated = false

    // One handshake at a time.
    private var hsSecret: Data?
    private var hsClientNonce: Data?   // ours ("mac" nonce in MacPairing terms)
    private var hsHostNonce: Data?     // the host's ("phone" nonce)
    private var hsFirstPairing = false
    private var hsCode: String?

    private var sealed: SealedTransport? { link as? SealedTransport }

    init(link: SealedTransport, clientId: String, displayName: String,
         tokenFor: @escaping (String) -> Data?, saveToken: @escaping (Data, String) -> Void) {
        self.clientId = clientId; self.displayName = displayName
        self.tokenFor = tokenFor; self.saveToken = saveToken
        super.init(link: link)
    }

    // MARK: Subclass hooks
    /// The paired host's name (the account the token is stored under). nil = nothing paired yet.
    func currentHostName() -> String? { nil }
    /// Called when a first-time pairing needs the user to enter the host's one-time code.
    func handshakeNeedsCode() {}
    /// Called on a failed handshake (bad code / verification), with a user-facing message.
    func handshakeFailed(_ message: String) {}
    /// Called once the host has authenticated us and encryption is active.
    func handshakeSucceeded() {}

    // MARK: Handshake control
    /// Provide the one-time code the user typed (or scanned), then (re)start the handshake.
    func provideCode(_ code: String) { hsCode = code.filter(\.isNumber); startHandshake() }
    func resetHandshake() { hsSecret = nil; hsClientNonce = nil; hsHostNonce = nil; hsFirstPairing = false; hsCode = nil }

    override func reachabilityDidChange(_ r: Bool) {
        super.reachabilityDidChange(r)
        if r {
            startHandshake()
        } else {
            authenticated = false
            sealed?.endSession()   // require a fresh handshake on reconnect
            resetHandshake()
        }
    }

    func startHandshake() {
        guard link.isReachable, !authenticated, let host = currentHostName() else { return }
        if let token = tokenFor(host) {
            hsSecret = token; hsFirstPairing = false
        } else if let code = hsCode {
            hsSecret = MacPairing.secret(code: code); hsFirstPairing = true
        } else {
            handshakeNeedsCode(); return
        }
        let nonce = MacPairing.newNonce(); hsClientNonce = nonce
        link.send(.auth(.authHello, clientId: clientId, nonce: nonce.base64EncodedString(), message: displayName))
    }

    override func handle(_ cmd: RemoteCommand) {
        switch cmd.kind {
        case .authChallenge:
            guard let secret = hsSecret, let cNonce = hsClientNonce,
                  let hB64 = cmd.authNonce, let hNonce = Data(base64Encoded: hB64) else { return }
            hsHostNonce = hNonce
            let proof = MacPairing.proof(secret: secret, label: "mac",
                                         phoneNonce: hNonce, macNonce: cNonce, clientId: clientId)
            link.send(.auth(.authProof, clientId: clientId, proof: proof))
        case .authResult:
            handleAuthResult(cmd)
        default:
            super.handle(cmd)   // status/bolus echoes — only arrive once authenticated + sealed
        }
    }

    private func handleAuthResult(_ cmd: RemoteCommand) {
        guard cmd.authOK == true else {
            handshakeFailed(cmd.message ?? "Pairing failed.")
            hsSecret = nil; hsFirstPairing = false; hsCode = nil
            return
        }
        guard let secret = hsSecret, let cNonce = hsClientNonce, let hNonce = hsHostNonce,
              let hostProof = cmd.authProof,
              MacPairing.verify(hostProof, secret: secret, label: "phone",
                                phoneNonce: hNonce, macNonce: cNonce, clientId: clientId) else {
            handshakeFailed("Couldn’t verify the host.")
            resetHandshake()
            return
        }
        if hsFirstPairing {
            guard let sealedTok = cmd.authSealedToken, let code = hsCode,
                  let token = MacPairing.openToken(sealedTok, code: code) else {
                handshakeFailed("Pairing failed — please try again.")
                return
            }
            if let host = currentHostName() { saveToken(token, host) }
        }
        // Encrypt everything from here on, then we're trusted.
        sealed?.activateSession(secret: secret, phoneNonce: hNonce, macNonce: cNonce)
        authenticated = true
        hsCode = nil; hsFirstPairing = false
        handshakeSucceeded()
        requestStatus()
    }
}
