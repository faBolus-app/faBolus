import Foundation

/// Remembers which Tandem model we last connected to, detected from the BLE advertised name
/// ("Tandem Mobi …" vs "tslim X2 …"). Persisted so the UI can act on it across launches — e.g.
/// only offer to save the fixed PIN on a **Mobi**. Nil until we've connected once (the model isn't
/// knowable before the first scan).
enum PumpModelStore {
    private static let key = "detectedPumpIsMobi"

    static func set(isMobi: Bool) { UserDefaults.standard.set(isMobi, forKey: key) }

    /// true = Mobi, false = t:slim X2, nil = not yet detected.
    static func isMobi() -> Bool? { UserDefaults.standard.object(forKey: key) as? Bool }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
