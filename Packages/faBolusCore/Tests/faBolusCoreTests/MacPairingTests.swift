import XCTest
@testable import faBolusCore

/// The Mac↔phone pairing handshake (`MacPairing`): a mutual HMAC challenge–response over a one-time
/// code, then a sealed long-term token for reconnects. These must round-trip and reject tampering.
final class MacPairingTests: XCTestCase {

    private func makeExchange() -> (clientId: String, phoneNonce: Data, macNonce: Data) {
        (MacPairing.newClientId(), MacPairing.newNonce(), MacPairing.newNonce())
    }

    func testCodeShape() {
        let code = MacPairing.newCode()
        XCTAssertEqual(code.count, MacPairing.codeLength)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
    }

    func testMutualProofRoundTrip() {
        let (clientId, pN, mN) = makeExchange()
        let secret = MacPairing.secret(code: "123456")
        let macProof = MacPairing.proof(secret: secret, label: "mac", phoneNonce: pN, macNonce: mN, clientId: clientId)
        let phoneProof = MacPairing.proof(secret: secret, label: "phone", phoneNonce: pN, macNonce: mN, clientId: clientId)
        // Each side verifies the other's proof.
        XCTAssertTrue(MacPairing.verify(macProof, secret: secret, label: "mac", phoneNonce: pN, macNonce: mN, clientId: clientId))
        XCTAssertTrue(MacPairing.verify(phoneProof, secret: secret, label: "phone", phoneNonce: pN, macNonce: mN, clientId: clientId))
    }

    func testWrongCodeFails() {
        let (clientId, pN, mN) = makeExchange()
        let macProof = MacPairing.proof(secret: MacPairing.secret(code: "123456"),
                                        label: "mac", phoneNonce: pN, macNonce: mN, clientId: clientId)
        XCTAssertFalse(MacPairing.verify(macProof, secret: MacPairing.secret(code: "000000"),
                                         label: "mac", phoneNonce: pN, macNonce: mN, clientId: clientId))
    }

    func testProofBoundToRoleAndNonces() {
        let (clientId, pN, mN) = makeExchange()
        let secret = MacPairing.secret(code: "424242")
        let macProof = MacPairing.proof(secret: secret, label: "mac", phoneNonce: pN, macNonce: mN, clientId: clientId)
        // A Mac proof must not verify as a phone proof (role binding prevents reflection).
        XCTAssertFalse(MacPairing.verify(macProof, secret: secret, label: "phone", phoneNonce: pN, macNonce: mN, clientId: clientId))
        // Different nonce -> fails (freshness).
        XCTAssertFalse(MacPairing.verify(macProof, secret: secret, label: "mac", phoneNonce: MacPairing.newNonce(), macNonce: mN, clientId: clientId))
        // Different client id -> fails.
        XCTAssertFalse(MacPairing.verify(macProof, secret: secret, label: "mac", phoneNonce: pN, macNonce: mN, clientId: MacPairing.newClientId()))
    }

    func testTokenReconnectProof() {
        // Reconnect uses the token as the secret; a different token fails.
        let (clientId, pN, mN) = makeExchange()
        let token = MacPairing.newToken()
        let proof = MacPairing.proof(secret: token, label: "mac", phoneNonce: pN, macNonce: mN, clientId: clientId)
        XCTAssertTrue(MacPairing.verify(proof, secret: token, label: "mac", phoneNonce: pN, macNonce: mN, clientId: clientId))
        XCTAssertFalse(MacPairing.verify(proof, secret: MacPairing.newToken(), label: "mac", phoneNonce: pN, macNonce: mN, clientId: clientId))
    }

    func testSealedTokenRoundTrip() throws {
        let token = MacPairing.newToken()
        let sealed = try XCTUnwrap(MacPairing.sealToken(token, code: "135790"))
        XCTAssertNotEqual(Data(base64Encoded: sealed), token, "token must not be exposed in the clear")
        XCTAssertEqual(MacPairing.openToken(sealed, code: "135790"), token)
        XCTAssertNil(MacPairing.openToken(sealed, code: "000000"), "wrong code must not open the token")
    }

    func testAuthCommandRoundTrip() throws {
        let cmd = RemoteCommand.auth(.authProof, clientId: "abc", nonce: "bm9uY2U=", proof: "cHJvb2Y=")
        let back = try RemoteCommand.decode(try cmd.encoded())
        XCTAssertEqual(back.kind, .authProof)
        XCTAssertEqual(back.authClientId, "abc")
        XCTAssertEqual(back.authNonce, "bm9uY2U=")
        XCTAssertEqual(back.authProof, "cHJvb2Y=")
        // Non-auth commands must not carry auth fields in their JSON.
        let status = try RemoteCommand.decode(try RemoteCommand(kind: .statusRead).encoded())
        XCTAssertNil(status.authClientId)
    }
}
