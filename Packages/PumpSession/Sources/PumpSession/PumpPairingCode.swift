import Foundation
import TandemAuth
import TandemLink

/// A pump pairing code as the user typed it. Either a 6-digit code (JPAKE, newer firmware) or a
/// 16-character code (legacy pairing, older firmware); separators and spaces are ignored. The scheme
/// follows from the code, so there's no firmware choice to make: the user enters what the pump shows.
public enum PumpPairingCode {
    /// The code is usable as either kind.
    public static func isValid(_ code: String) -> Bool { credentials(for: code) != nil }

    public static func scheme(_ code: String) -> StoredPairing.Scheme? {
        guard let credentials = credentials(for: code) else { return nil }
        if case .legacy = credentials { return .legacy }
        return .jpake
    }

    /// The credentials the link pairs with, or `nil` for a code that is neither kind.
    public static func credentials(for code: String) -> PairingCredentials? {
        switch PairingAuth.detectType(code) {
        case .long16Char:
            return (try? PairingAuth.processPairingCode(code, type: .long16Char)).map { .legacy(code: $0) }
        case .short6Char:
            return (try? PairingAuth.processPairingCode(code, type: .short6Char)).map { .jpake(code: $0) }
        }
    }
}
