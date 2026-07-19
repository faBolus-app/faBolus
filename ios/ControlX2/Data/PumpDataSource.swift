import Foundation
import PumpX2Messages

/// Abstraction over the pump so the UI runs in the simulator (mock) and, later, against a real
/// pump via PumpX2Kit (live). Async streaming of snapshots keeps the HUD reactive.
@MainActor
public protocol PumpDataSource: AnyObject {
    var snapshot: PumpSnapshot { get }
    var glucoseHistory: [GlucoseReading] { get }
    /// Active pump alerts/alarms/CGM alerts (most severe first).
    var activeNotifications: [PumpNotification] { get }
    /// Diagnostic string (raw alert bitmaps + poll count) for confirming the pump is answering.
    var alertDebug: String { get }
    /// Dismiss (clear) one notification on the pump — a signed control command.
    func dismissNotification(_ notification: PumpNotification) async
    /// 6-digit JPAKE pairing code from the pump (ignored by the mock).
    var pairingCode: String { get set }
    /// True when a prior pairing was saved (Keychain) — connect can resume without a code.
    var hasStoredPairing: Bool { get }
    /// Forget the saved pairing (require the 6-digit code again).
    func forgetPairing()
    func connect() async
    func disconnect()
    /// Compute a bolus recommendation for the given carbs/BG (uses the pump's calculator on
    /// the live source; a simple model on the mock).
    func recommendBolus(carbsGrams: Double, bgMgdl: Int?) async -> BolusRecommendation
    /// Deliver a SALINE bench bolus of the given units. Returns the **actual delivered** units
    /// (may be a partial amount if cancelled mid-delivery). Check `lastBolusCancelled`.
    func deliverBolus(units: Double) async throws -> Double
    func cancelBolus() async
    /// True if the most recent `deliverBolus` was cancelled before completing.
    var lastBolusCancelled: Bool { get }
    /// Called by the view model to observe changes.
    var onChange: (@MainActor () -> Void)? { get set }
}

public enum BolusError: Error, LocalizedError {
    case notConnected, exceedsMax(Double), cancelled, pumpRejected(String)
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to a pump."
        case .exceedsMax(let m): return "Exceeds max bolus of \(m) u."
        case .cancelled: return "Bolus cancelled."
        case .pumpRejected(let r): return "Pump rejected the bolus: \(r)."
        }
    }
}

/// Absolute defense-in-depth ceiling. The real cap is the pump's configured max bolus
/// (`PumpSnapshot.maxBolusUnits`); this is only a final sanity bound so a bug can't request an
/// absurd amount (the pump also rejects anything over its own limit).
public enum Interlocks {
    public static let absoluteMaxUnits: Double = 25.0
}
