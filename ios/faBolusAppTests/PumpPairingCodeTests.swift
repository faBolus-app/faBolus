import Testing
@testable import faBolus

/// The app's pump-pairing-code validation + automatic scheme selection (6-digit JPAKE vs legacy V1
/// 16-char). The pairing MECHANICS are proven in TandemKit; this pins the app-layer contract the
/// pairing UI relies on — that both code formats are accepted and routed to the right handshake.
@Suite struct PumpPairingCodeTests {
    @Test func acceptsSixDigitAsJpake() {
        #expect(PumpPairingCode.isValid("123456"))
        #expect(PumpPairingCode.isValid("123-456"))  // separators ignored
        #expect(PumpPairingCode.isValid("123 456"))
        #expect(PumpPairingCode.scheme("123456") == .short6Char)  // → JPAKE
    }

    @Test func acceptsSixteenCharAsLegacyV1() {
        #expect(PumpPairingCode.isValid("abcd1234ijkl5678"))
        #expect(PumpPairingCode.isValid("abcd-1234-ijkl-5678"))
        #expect(PumpPairingCode.scheme("abcd1234ijkl5678") == .long16Char)  // → V1
    }

    /// Safety-hardened detection: a 16-char alphanumeric code that happens to contain exactly 6
    /// digits must still route to V1, not misfire as a 6-digit JPAKE code.
    @Test func sixteenCharWithSixDigitsRoutesToV1() {
        #expect(PumpPairingCode.isValid("ab12cd34ef56ghij"))
        #expect(PumpPairingCode.scheme("ab12cd34ef56ghij") == .long16Char)
    }

    @Test func rejectsMalformedCodes() {
        #expect(!PumpPairingCode.isValid(""))
        #expect(!PumpPairingCode.isValid("123"))  // too short
        #expect(!PumpPairingCode.isValid("12345"))  // 5 digits
        #expect(!PumpPairingCode.isValid("1234567"))  // 7 digits, not 16 alnum
        #expect(!PumpPairingCode.isValid("abcd!fghijklmnop"))  // 15 alnum after stripping — not 16
    }
}
