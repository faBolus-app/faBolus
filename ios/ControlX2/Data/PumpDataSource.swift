import Foundation

/// Abstraction over the pump so the UI runs in the simulator (mock) and, later, against a real
/// pump via PumpX2Kit (live). Async streaming of snapshots keeps the HUD reactive.
@MainActor
public protocol PumpDataSource: AnyObject {
    var snapshot: PumpSnapshot { get }
    var glucoseHistory: [GlucoseReading] { get }
    /// 6-digit JPAKE pairing code from the pump (ignored by the mock).
    var pairingCode: String { get set }
    func connect() async
    func disconnect()
    /// Compute a bolus recommendation for the given carbs/BG (uses the pump's calculator on
    /// the live source; a simple model on the mock).
    func recommendBolus(carbsGrams: Double, bgMgdl: Int?) async -> BolusRecommendation
    /// Deliver a SALINE bench bolus of the given units. Returns the delivered units on success.
    func deliverBolus(units: Double) async throws -> Double
    func cancelBolus() async
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

/// Shared safety limit for the UI clamp (matches the interlock intent from the plan).
public enum Interlocks {
    public static let maxBolusUnits: Double = 10.0
}
