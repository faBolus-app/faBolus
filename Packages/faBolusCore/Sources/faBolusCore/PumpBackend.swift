import Foundation

/// The **pump backend** interface — the stable seam between the faBolus UI and any pump. A backend
/// (TandemBackend/PumpX2Kit, MockBackend, or a community backend) conforms to this; the app depends
/// only on this protocol + the neutral models, never on a specific pump library. Async streaming of
/// snapshots keeps the HUD reactive.
@MainActor
public protocol PumpBackend: AnyObject {
    /// What this backend supports, so the UI adapts (carbs mode, cancel, alerts, pairing).
    var capabilities: PumpCapabilities { get }
    var snapshot: PumpSnapshot { get }
    var glucoseHistory: [GlucoseReading] { get }
    /// IOB over time + delivered-bolus markers, for the chart's insulin overlay.
    var iobHistory: [IOBSample] { get }
    var bolusMarkers: [BolusMarker] { get }
    /// Active pump alerts/alarms/CGM alerts (most severe first), as neutral `PumpAlert`s.
    var activeNotifications: [PumpAlert] { get }
    /// Diagnostic string (raw alert bitmaps + poll count) for confirming the pump is answering.
    var alertDebug: String { get }
    /// Dismiss (clear) one alert on the pump — a signed control command.
    func dismissNotification(_ alert: PumpAlert) async
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
    /// Deliver a bolus of the given units. Returns the **actual delivered** units
    /// (may be a partial amount if cancelled mid-delivery). Check `lastBolusCancelled`.
    func deliverBolus(units: Double) async throws -> Double
    func cancelBolus() async
    /// True if the most recent `deliverBolus` was cancelled before completing.
    var lastBolusCancelled: Bool { get }
    /// Called by the view model to observe changes.
    var onChange: (@MainActor () -> Void)? { get set }

    /// Decoded history-log events for the Logbook (B2), newest first. Backends that don't decode
    /// history return `[]` (see the default). Populated from the pump's history backfill.
    var historyEvents: [HistoryEvent] { get }

    // MARK: - Advanced control (B3)
    // Signed, mostly insulin-affecting write commands. The UI gates each on the matching
    // `PumpCapabilities` flag AND `AppSettings.advancedControlEnabled` (default off) AND (in
    // practice) a Mobi pump. Insulin-affecting ones must be bench-validated on saline before use.
    // Default implementations throw `ControlError.notSupported` so non-Tandem backends compile.

    /// Suspend all insulin delivery.
    func suspendDelivery() async throws
    /// Resume insulin delivery.
    func resumeDelivery() async throws
    /// Set a temporary basal rate (`percent` 0–250) for `durationMinutes` (15–4320). Control-IQ
    /// must be off. Insulin-affecting.
    func setTempBasal(percent: Int, durationMinutes: Int) async throws
    /// Stop an active temp basal.
    func stopTempBasal() async throws
    /// Set the pump user-mode bitmap (sleep/exercise). Insulin-affecting (changes CIQ behavior).
    func setMode(bitmap: Int) async throws
    /// Play the "find my pump" sound. Non-insulin.
    func playFindMyPump() async throws
}

public enum ControlError: Error, LocalizedError {
    case notSupported
    public var errorDescription: String? { "This pump doesn't support that action." }
}

public extension PumpBackend {
    var historyEvents: [HistoryEvent] { [] }
    func suspendDelivery() async throws { throw ControlError.notSupported }
    func resumeDelivery() async throws { throw ControlError.notSupported }
    func setTempBasal(percent: Int, durationMinutes: Int) async throws { throw ControlError.notSupported }
    func stopTempBasal() async throws { throw ControlError.notSupported }
    func setMode(bitmap: Int) async throws { throw ControlError.notSupported }
    func playFindMyPump() async throws { throw ControlError.notSupported }
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
