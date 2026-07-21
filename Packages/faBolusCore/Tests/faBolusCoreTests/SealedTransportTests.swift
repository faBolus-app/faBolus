import XCTest
import CryptoKit
@testable import faBolusCore

/// In-memory transport so two `SealedTransport`s can be cross-wired without BLE. Nonisolated (like
/// `BLELink`) so it satisfies the `RemoteTransport` conformance; callbacks hop to the main actor.
private final class Loopback: RemoteTransport, @unchecked Sendable {
    var onReceive: (@MainActor (RemoteCommand) -> Void)?
    var onReachabilityChange: (@MainActor (Bool) -> Void)?
    var isReachable: Bool = true
    weak var peer: Loopback?
    private(set) var sent: [RemoteCommand] = []
    func send(_ command: RemoteCommand) {
        sent.append(command)
        let p = peer
        Task { @MainActor in p?.onReceive?(command) }
    }
}

@MainActor
final class SealedTransportTests: XCTestCase {
    private func key() -> SymmetricKey {
        MacPairing.channelKey(secret: Data("123456".utf8),
                              phoneNonce: Data(repeating: 1, count: 16),
                              macNonce: Data(repeating: 2, count: 16))
    }

    func testSealOpenRoundTrip() {
        let k = key()
        let cmd = RemoteCommand(kind: .bolusRequest, units: 1.25)
        let sealed = try! XCTUnwrap(SealedTransport.seal(cmd, key: k, counter: 0))
        let (opened, ctr) = try! XCTUnwrap(SealedTransport.open(sealed, key: k))
        XCTAssertEqual(opened.kind, .bolusRequest)
        XCTAssertEqual(opened.units, 1.25)
        XCTAssertEqual(ctr, 0)
    }

    func testWrongKeyFailsToOpen() {
        let sealed = SealedTransport.seal(RemoteCommand(kind: .statusRead), key: key(), counter: 0)!
        let wrong = MacPairing.channelKey(secret: Data("999999".utf8),
                                          phoneNonce: Data(repeating: 1, count: 16),
                                          macNonce: Data(repeating: 2, count: 16))
        XCTAssertNil(SealedTransport.open(sealed, key: wrong))
    }

    func testTamperedPayloadFails() {
        var sealed = SealedTransport.seal(RemoteCommand(kind: .statusRead), key: key(), counter: 0)!
        // Flip a character in the base64 to corrupt the ciphertext/tag.
        sealed = String(sealed.dropLast()) + (sealed.hasSuffix("A") ? "B" : "A")
        XCTAssertNil(SealedTransport.open(sealed, key: key()))
    }

    func testEndToEndEncryptsAndDelivers() async {
        let a = Loopback(), b = Loopback(); a.peer = b; b.peer = a
        let sa = SealedTransport(inner: a), sb = SealedTransport(inner: b)
        let secret = Data("123456".utf8)
        let pn = Data(repeating: 1, count: 16), mn = Data(repeating: 2, count: 16)
        sa.activateSession(secret: secret, phoneNonce: pn, macNonce: mn)
        sb.activateSession(secret: secret, phoneNonce: pn, macNonce: mn)

        var received: RemoteCommand?
        sb.onReceive = { received = $0 }
        sa.send(RemoteCommand(kind: .bolusRequest, units: 2.0))
        try? await Task.sleep(nanoseconds: 50_000_000)

        // On the wire it was a .sealed envelope (never the plaintext bolusRequest).
        XCTAssertEqual(a.sent.first?.kind, .sealed)
        XCTAssertNil(a.sent.first?.units)
        // But the peer decrypted the real command.
        XCTAssertEqual(received?.kind, .bolusRequest)
        XCTAssertEqual(received?.units, 2.0)
    }

    func testReplayRejected() async {
        let a = Loopback(), b = Loopback(); a.peer = b; b.peer = a
        let sa = SealedTransport(inner: a), sb = SealedTransport(inner: b)
        let secret = Data("123456".utf8), pn = Data(repeating: 1, count: 16), mn = Data(repeating: 2, count: 16)
        sa.activateSession(secret: secret, phoneNonce: pn, macNonce: mn)
        sb.activateSession(secret: secret, phoneNonce: pn, macNonce: mn)

        var count = 0
        sb.onReceive = { _ in count += 1 }
        sa.send(RemoteCommand(kind: .statusRead))
        try? await Task.sleep(nanoseconds: 30_000_000)
        // Re-send the exact same sealed frame (captured on a's wire) → replay.
        let replay = a.sent.first!
        b.onReceive?(replay)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(count, 1)   // the replayed frame is dropped
    }

    func testAuthPassesButRealCommandBlockedBeforeSession() async {
        let a = Loopback(), b = Loopback(); a.peer = b; b.peer = a
        let sa = SealedTransport(inner: a); _ = SealedTransport(inner: b)
        // No activateSession yet.
        sa.send(.auth(.authHello, clientId: "x"))
        sa.send(RemoteCommand(kind: .bolusRequest, units: 1))   // must NOT go out in clear
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(a.sent.count, 1)
        XCTAssertEqual(a.sent.first?.kind, .authHello)
    }
}
