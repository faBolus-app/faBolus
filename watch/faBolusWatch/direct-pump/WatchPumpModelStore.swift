import Foundation

/// Remembers which Tandem model the watch last connected to (from the BLE advertised name), so the
/// pairing screen can offer to save the fixed PIN only on a **Mobi**. Nil until first detected.
enum WatchPumpModelStore {
    private static let key = "watchDetectedPumpIsMobi"

    static func set(isMobi: Bool) { UserDefaults.standard.set(isMobi, forKey: key) }

    /// true = Mobi, false = t:slim X2, nil = not yet detected.
    static func isMobi() -> Bool? { UserDefaults.standard.object(forKey: key) as? Bool }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
