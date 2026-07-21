import Foundation
import CryptoKit

/// A `RemoteTransport` decorator that **encrypts the ongoing command stream** over an inner transport
/// (e.g. `BLELink`). `MacPairing` authenticates the peer and delivers the long-term token already
/// sealed, but the *ongoing* BLE traffic (glucose, bolus amounts, commands) would otherwise be
/// cleartext. This closes that gap so **no remote channel ships unencrypted**.
///
/// - During the pairing handshake (no session key yet), only `auth*` commands pass through — they
///   carry no secret (just client id, nonces, and HMAC proofs). Any other kind is refused, so a real
///   command/status can never cross before the session is established.
/// - Once `activateSession(...)` runs (both ends, at the end of the handshake), every non-`auth`
///   command is `AES-GCM`-sealed into a `.sealed` envelope with a per-message random nonce and a
///   monotonic counter (authenticated in the AAD) for **replay protection**. The session key is fresh
///   per connection (derived from the shared secret + both handshake nonces).
///
/// `@unchecked Sendable`: mutable session state is guarded by `lock`; callbacks re-dispatch to the
/// main actor via the inner transport.
public final class SealedTransport: RemoteTransport, @unchecked Sendable {
    private let inner: any RemoteTransport
    public var onReceive: (@MainActor (RemoteCommand) -> Void)?
    public var onReachabilityChange: (@MainActor (Bool) -> Void)? {
        get { inner.onReachabilityChange }
        set { inner.onReachabilityChange = newValue }
    }
    public var isReachable: Bool { inner.isReachable }

    private let lock = NSLock()
    private var key: SymmetricKey?
    private var sendCounter: UInt64 = 0
    private var expectedRecvCounter: UInt64 = 0

    public init(inner: any RemoteTransport) {
        self.inner = inner
        inner.onReceive = { [weak self] cmd in self?.receive(cmd) }
    }

    /// Enable encryption for the rest of this connection. Call on **both** ends after a successful
    /// handshake, with the same shared `secret` (code bytes first-pairing, token on reconnect) and the
    /// two handshake nonces.
    public func activateSession(secret: Data, phoneNonce: Data, macNonce: Data) {
        lock.lock(); defer { lock.unlock() }
        key = MacPairing.channelKey(secret: secret, phoneNonce: phoneNonce, macNonce: macNonce)
        sendCounter = 0
        expectedRecvCounter = 0
    }

    /// Forget the session key (on disconnect) so the next connection must re-handshake before any
    /// real command flows.
    public func endSession() {
        lock.lock(); key = nil; lock.unlock()
    }

    public var hasSession: Bool { lock.lock(); defer { lock.unlock() }; return key != nil }

    // MARK: Send

    public func send(_ command: RemoteCommand) {
        if Self.isAuth(command.kind) { inner.send(command); return }   // handshake frames: cleartext, no secrets
        lock.lock()
        guard let key else { lock.unlock(); return }   // no session yet → never emit a real command in clear
        let ctr = sendCounter; sendCounter &+= 1
        lock.unlock()
        guard let payload = Self.seal(command, key: key, counter: ctr) else { return }
        inner.send(.sealed(payload))
    }

    // MARK: Receive

    private func receive(_ cmd: RemoteCommand) {
        if Self.isAuth(cmd.kind) { deliver(cmd); return }
        // Any non-auth command MUST arrive sealed once we're encrypting.
        guard cmd.kind == .sealed, let payload = cmd.sealedPayload else { return }
        lock.lock(); let k = key; lock.unlock()
        guard let k, let (opened, ctr) = Self.open(payload, key: k) else { return }
        lock.lock()
        guard ctr >= expectedRecvCounter else { lock.unlock(); return }   // replay / reorder → drop
        expectedRecvCounter = ctr &+ 1
        lock.unlock()
        deliver(opened)
    }

    private func deliver(_ cmd: RemoteCommand) {
        Task { @MainActor in self.onReceive?(cmd) }
    }

    // MARK: Crypto (internal for tests)

    static func isAuth(_ k: RemoteCommand.Kind) -> Bool {
        k == .authHello || k == .authChallenge || k == .authProof || k == .authResult
    }

    static func seal(_ command: RemoteCommand, key: SymmetricKey, counter: UInt64) -> String? {
        guard let data = try? command.encoded() else { return nil }
        let ctr = counterData(counter)
        guard let box = try? AES.GCM.seal(data, using: key, authenticating: ctr),
              let combined = box.combined else { return nil }
        return (ctr + combined).base64EncodedString()
    }

    static func open(_ payloadB64: String, key: SymmetricKey) -> (RemoteCommand, UInt64)? {
        guard let blob = Data(base64Encoded: payloadB64), blob.count > 8 else { return nil }
        let ctrData = blob.prefix(8)
        let boxData = blob.suffix(from: blob.startIndex + 8)
        let counter = ctrData.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard let box = try? AES.GCM.SealedBox(combined: boxData),
              let opened = try? AES.GCM.open(box, using: key, authenticating: ctrData),
              let cmd = try? RemoteCommand.decode(opened) else { return nil }
        return (cmd, counter)
    }

    private static func counterData(_ c: UInt64) -> Data {
        var be = c.bigEndian
        return Data(bytes: &be, count: 8)
    }
}
