import Foundation
import CryptoKit

/// One-time-code authentication for pairing a Mac remote with the iPhone host.
///
/// Design — the phone is the authority (it owns the pump). First-time pairing requires a 6-digit
/// code shown on the phone and entered on the Mac. A **mutual HMAC challenge–response** proves both
/// ends know the code without ever sending it; on success the phone issues a random 256-bit
/// **long-term token** — sealed on the wire with a code-derived AES-GCM key so it isn't exposed —
/// that both ends store in the Keychain. Reconnects authenticate with the token, so the code is
/// needed only once.
///
/// Security note: a 6-digit code is low-entropy, so an attacker who captures the *first* pairing
/// exchange over an unencrypted link could brute-force it offline. The Multipeer link is encrypted;
/// the BLE link is not — so the code is single-use and short-lived, and steady-state security rests
/// on the 256-bit token. For defense against an on-path attacker *during first pairing*, upgrade to a
/// PAKE (the repo already vendors mbedtls J-PAKE for pump auth). See docs/operate/mac-remote.md.
///
/// These are pure, platform-independent primitives (CryptoKit only) so they unit-test without a
/// Keychain or a live link; the state machine that drives them lives in the phone host and Mac model.
public enum MacPairing {
    public static let codeLength = 6

    // MARK: - Material generation

    /// A fresh 6-digit numeric pairing code (leading zeros preserved).
    public static func newCode() -> String {
        (0..<codeLength).map { _ in String(Int.random(in: 0...9)) }.joined()
    }
    /// A stable per-Mac identifier (generated once, persisted by the Mac; not secret).
    public static func newClientId() -> String { UUID().uuidString }
    /// A random 256-bit long-term pairing token.
    public static func newToken() -> Data { randomBytes(32) }
    /// A random 128-bit challenge nonce.
    public static func newNonce() -> Data { randomBytes(16) }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    // MARK: - Key derivation

    private static let salt = Data("fabolus.macpair.v1".utf8)

    /// HMAC key derived from the shared secret (the code bytes on first pairing, or the token on a
    /// reconnect) via HKDF-SHA256.
    static func authKey(secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
                               info: Data("auth".utf8), outputByteCount: 32)
    }
    /// AES-GCM key derived from the code, used to seal the long-term token on first pairing.
    static func sealKey(code: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)), salt: salt,
                               info: Data("seal".utf8), outputByteCount: 32)
    }
    /// Per-connection AES-GCM **channel** key that seals ongoing commands after the handshake (see
    /// `SealedTransport`). Both ends derive it identically from the shared `secret` (code bytes on
    /// first pairing, or the token on reconnect) bound to both handshake nonces, so each connection
    /// gets a fresh key — closing the cleartext-BLE gap (traffic is encrypted, not just authenticated).
    static func channelKey(secret: Data, phoneNonce: Data, macNonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                               salt: phoneNonce + macNonce,
                               info: Data("fabolus.channel.v1".utf8), outputByteCount: 32)
    }

    /// The HMAC secret material for the proofs: raw code bytes (first pairing) or the token (reconnect).
    public static func secret(code: String) -> Data { Data(code.utf8) }

    // MARK: - Mutual proofs

    /// `label` binds each side's proof to its role ("mac" or "phone") so a proof can't be replayed
    /// in the other direction; both nonces + the client id bind it to this exact exchange.
    private static func message(label: String, phoneNonce: Data, macNonce: Data, clientId: String) -> Data {
        var m = Data(label.utf8)
        m.append(phoneNonce); m.append(macNonce); m.append(Data(clientId.utf8))
        return m
    }

    public static func proof(secret: Data, label: String, phoneNonce: Data, macNonce: Data,
                             clientId: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: message(label: label, phoneNonce: phoneNonce, macNonce: macNonce, clientId: clientId),
            using: authKey(secret: secret))
        return Data(code).base64EncodedString()
    }

    /// Constant-time verification (CryptoKit's `isValidAuthenticationCode`).
    public static func verify(_ proofB64: String, secret: Data, label: String, phoneNonce: Data,
                              macNonce: Data, clientId: String) -> Bool {
        guard let given = Data(base64Encoded: proofB64) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            given,
            authenticating: message(label: label, phoneNonce: phoneNonce, macNonce: macNonce, clientId: clientId),
            using: authKey(secret: secret))
    }

    // MARK: - Token sealing (first pairing)

    /// Seal the long-term token with a code-derived key so it isn't exposed on the wire.
    public static func sealToken(_ token: Data, code: String) -> String? {
        guard let box = try? AES.GCM.seal(token, using: sealKey(code: code)),
              let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }

    /// Open a sealed token with the code; nil if the code is wrong or the data is tampered.
    public static func openToken(_ sealedB64: String, code: String) -> Data? {
        guard let data = Data(base64Encoded: sealedB64),
              let box = try? AES.GCM.SealedBox(combined: data),
              let token = try? AES.GCM.open(box, using: sealKey(code: code)) else { return nil }
        return token
    }
}
