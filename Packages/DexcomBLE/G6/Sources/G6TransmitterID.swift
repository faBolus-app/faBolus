import Foundation

/// A Dexcom G5/G6/ONE transmitter ID: six letters and digits, printed on the transmitter and shown in
/// the Dexcom app. The transmitter advertises as "Dexcom" plus the ID's last two characters.
public enum G6TransmitterID {
    public static let length = 6

    /// The ID uppercased with surrounding spaces and padding removed, or `nil` when it isn't six letters
    /// and digits. Accepts what a person types and the pump's CGM hardware-info string, which is a
    /// fixed 16-byte field and may carry trailing NULs.
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            .uppercased()
        guard trimmed.count == length, trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return trimmed
    }

    /// The ID to match: one typed in settings wins over the one the pump reports, because the user may
    /// be wearing a transmitter the pump hasn't been told about yet.
    public static func preferred(entered: String?, fromPump: String?) -> String? {
        normalized(entered) ?? normalized(fromPump)
    }
}
