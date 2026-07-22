import XCTest
@testable import faBolusCore

final class PeerPairingPayloadTests: XCTestCase {
    func testRoundTrip() {
        let p = PeerPairingPayload(hostName: "Tia's iPhone", code: MacPairing.newStrongCode())
        let s = p.qrString()
        XCTAssertTrue(s.hasPrefix("fabolus-pair://"))
        let parsed = PeerPairingPayload(qrString: s)
        XCTAssertEqual(parsed, p)
    }

    func testHandlesSpacesAndSymbolsInHostName() {
        let p = PeerPairingPayload(hostName: "Mom & Dad’s iPhone (12)", code: "004291")
        XCTAssertEqual(PeerPairingPayload(qrString: p.qrString()), p)
    }

    func testRejectsForeignStrings() {
        XCTAssertNil(PeerPairingPayload(qrString: "https://example.com"))
        XCTAssertNil(PeerPairingPayload(qrString: "fabolus-pair://v1?host=&code="))   // empty fields
        XCTAssertNil(PeerPairingPayload(qrString: "random text"))
    }

    func testStrongCodeIs128Bit() {
        XCTAssertEqual(MacPairing.newStrongCode().count, 32)   // 16 bytes hex
    }
}
