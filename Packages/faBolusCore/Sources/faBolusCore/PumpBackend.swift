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

    /// Read the paired G6 CGM transmitter ID from the pump (for CGM-failover auto-fill). Returns nil
    /// if the pump can't/doesn't report it. Read-only.
    func readG6TransmitterId() async -> String?

    // MARK: - Mobi workflows (A4) — the screenless Mobi needs a phone for these.

    // CGM sensor session (non-insulin control). G6: set the transmitter id, then start with the
    // sensor code ("0000"/0 to join an existing session). G7/ONE+: set the pairing code + sensor type.
    func startG6Session(transmitterId: String, sensorCode: Int) async throws
    func startG7Session(pairingCode: Int) async throws
    func setSensorType(_ typeId: Int) async throws
    func stopCgmSession() async throws
    /// Poll the pump's CGM session status into `snapshot.cgmSessionActive`.
    func refreshCgmSession() async

    // Cartridge change / fill (INSULIN-AFFECTING — bench-validate on saline first). Multi-step:
    // suspend → clear alerts → enter change mode → (swap) → exit → detect; fill tubing/cannula after.
    func enterChangeCartridgeMode() async throws
    func exitChangeCartridgeMode() async throws
    func enterFillTubingMode() async throws
    func exitFillTubingMode() async throws
    /// Fill the cannula with `milliunits` (e.g. 300 = 0.3 U). Insulin-affecting; bounded by the UI.
    func fillCannula(milliunits: Int) async throws
    /// Poll the pump's cartridge/load status into `snapshot.cartridgeLoadState`.
    func refreshLoadStatus() async

    // Settings (non-insulin config).
    func setMaxBolus(units: Double) async throws
    func setMaxBasal(unitsPerHour: Double) async throws
    /// Set the pump clock to the phone's current time.
    func syncTimeToNow() async throws
}

/// The largest prime-cannula amount the UI allows (defense-in-depth on an insulin-dispensing step).
public enum FillLimits {
    public static let maxCannulaMilliunits = 1000   // 1.0 U — Tandem cannula prime is ~0.3 U
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
    func readG6TransmitterId() async -> String? { nil }

    func startG6Session(transmitterId: String, sensorCode: Int) async throws { throw ControlError.notSupported }
    func startG7Session(pairingCode: Int) async throws { throw ControlError.notSupported }
    func setSensorType(_ typeId: Int) async throws { throw ControlError.notSupported }
    func stopCgmSession() async throws { throw ControlError.notSupported }
    func refreshCgmSession() async {}
    func enterChangeCartridgeMode() async throws { throw ControlError.notSupported }
    func exitChangeCartridgeMode() async throws { throw ControlError.notSupported }
    func enterFillTubingMode() async throws { throw ControlError.notSupported }
    func exitFillTubingMode() async throws { throw ControlError.notSupported }
    func fillCannula(milliunits: Int) async throws { throw ControlError.notSupported }
    func refreshLoadStatus() async {}
    func setMaxBolus(units: Double) async throws { throw ControlError.notSupported }
    func setMaxBasal(unitsPerHour: Double) async throws { throw ControlError.notSupported }
    func syncTimeToNow() async throws { throw ControlError.notSupported }
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
