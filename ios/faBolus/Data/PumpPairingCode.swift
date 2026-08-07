import Foundation
import PumpX2Auth

/// Validation + scheme detection for a Tandem pump pairing code entered in the UI.
///
/// A code is valid if it is EITHER a **6-digit** (modern EC-JPAKE, firmware ≥ v7.7) OR a **16-char
/// alphanumeric** (legacy V1, pre-v7.7) code; separators/spaces are ignored (stripped before
/// pairing). The app auto-selects the pairing scheme from the code the user typed — there is no
/// firmware toggle: enter whatever the pump shows and the right handshake (JPAKE vs legacy V1) runs.
///
/// This wraps `PumpX2Auth.PairingAuth` so SwiftUI views don't depend on the pump library directly.
enum PumpPairingCode {
    /// True when `code` is a usable pump pairing code (a valid 6-digit OR a valid 16-char code).
    static func isValid(_ code: String) -> Bool {
        (try? PairingAuth.processPairingCode(code, type: .short6Char)) != nil ||
        (try? PairingAuth.processPairingCode(code, type: .long16Char)) != nil
    }

    /// The pairing scheme the app will use for `code` (`.short6Char` JPAKE vs `.long16Char` legacy V1).
    static func scheme(_ code: String) -> PairingCodeType { PairingAuth.detectType(code) }

    /// True when `code` routes to the legacy V1 (16-char) handshake rather than modern JPAKE.
    static func isLegacy(_ code: String) -> Bool { scheme(code) == .long16Char }
}
