import Foundation

/// The **pump backend** interface — the stable seam between the faBolus UI and any pump. A backend
/// (TandemBackend/PumpX2Kit, MockBackend, or a community backend) conforms to this; the app depends
/// only on this protocol + the neutral models, never on a specific pump library. Async streaming of
/// snapshots keeps the HUD reactive.
///
/// **To add a pump:** conform a new type to this protocol, register it in `BackendRegistry.enabled`
/// (in the app target), and rely on the default-throwing extension for actions your pump can't do.
/// **To add an action:** add the method here + a default-throwing impl in the extension below, then
/// implement it in `TandemBackend` **and** `MockBackend`, and surface it via `AppModel`.
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
    /// Request the newest CGM reading from the pump **now** and wait briefly for it (bounded), so a
    /// correction is computed off the freshest possible value. Best-effort: returns when the reading
    /// arrives or a short timeout elapses. Default no-op for backends that can't force a read.
    func refreshGlucoseNow() async
    /// Deliver a bolus of the given units. Returns the **actual delivered** units
    /// (may be a partial amount if cancelled mid-delivery). Check `lastBolusCancelled`.
    /// `carbsGrams`/`bgMgdl` are optional **metadata** recorded on the pump (pump graph / t:connect /
    /// Control-IQ carb awareness) — they do NOT change the delivered dose (the pump can't compute from
    /// carbs; the caller always sizes the units). Use the `deliverBolus(units:)` convenience for
    /// units-only.
    /// `iobUnits` is the **frozen calculator IOB** (the active insulin the dose was computed against),
    /// recorded on the pump as `bolusIOB` metadata (FB-04). It is the value the calculator used at
    /// freeze time — NOT the live snapshot — so it preserves the approved inputs. Metadata only.
    func deliverBolus(units: Double, carbsGrams: Double?, bgMgdl: Int?, iobUnits: Double?) async throws -> Double
    /// Deliver an **extended (combo)** bolus: `nowUnits` up front and the remainder over
    /// `durationMinutes`. Total must be ≥ 0.40 U. Returns the actual delivered-so-far units. Optional
    /// — backends that don't support it use the throwing default. `carbsGrams`/`bgMgdl`/`iobUnits` are
    /// recorded metadata (see `deliverBolus`).
    func deliverExtendedBolus(totalUnits: Double, nowUnits: Double, durationMinutes: Int,
                              carbsGrams: Double?, bgMgdl: Int?, iobUnits: Double?) async throws -> Double
    func cancelBolus() async
    /// True if the most recent `deliverBolus` was cancelled before completing.
    var lastBolusCancelled: Bool { get }
    /// Called by the view model to observe changes.
    var onChange: (@MainActor () -> Void)? { get set }

    // MARK: - Durable unknown-outcome recovery (P0)

    /// Called by the backend the instant the pump grants a bolus permission and assigns a bolus id —
    /// **before** the initiate is written, so the host can persist the id durably and later reconcile an
    /// outcome that was lost to a timeout/disconnect/crash. This is the explicit, deterministically-testable
    /// ownership link the host uses instead of an unobserved broadcast.
    var onBolusIdAssigned: (@MainActor (Int) -> Void)? { get set }
    /// Reconcile a previously-sent bolus whose outcome was lost, against the pump's **authoritative** bolus
    /// history, by its pump-assigned id. Returns `.resolved` only on an authoritative id match; otherwise
    /// `.unavailable` so the host keeps the delivery blocked and asks the user to verify on the pump.
    func reconcile(bolusId: Int) async -> BolusReconciliation

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

    // Control-IQ settings (non-insulin config; changes closed-loop behavior).
    func setControlIQ(enabled: Bool, weightLbs: Int, totalDailyInsulinUnits: Int) async throws
    func refreshControlIQSettings() async
    // Pump sounds — annunciation level per category (0 audioHigh … 3 vibrate).
    func setPumpSounds(quickBolus: Int, general: Int, reminder: Int, alert: Int, alarm: Int, cgmA: Int, cgmB: Int) async throws
    // Insulin-delivery profiles (IDP). Switch/rename/delete are insulin-affecting (change active basal).
    func refreshProfiles() async
    func setActiveProfile(idpId: Int) async throws
    func renameProfile(idpId: Int, name: String) async throws
    func deleteProfile(idpId: Int) async throws
    /// Create a new profile with one initial time-segment (starting at midnight).
    func createProfile(name: String, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double,
                        isf: Int, targetBg: Int, insulinDurationMinutes: Int) async throws
    /// Read a profile's time-segments into `snapshot.viewedProfileSegments`.
    func refreshProfileSegments(idpId: Int) async
    func addProfileSegment(idpId: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
                           carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async throws
    func modifyProfileSegment(idpId: Int, segmentIndex: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
                              carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async throws
    func deleteProfileSegment(idpId: Int, segmentIndex: Int) async throws
    // Reminders / alert thresholds (non-insulin config).
    func setLowInsulinAlert(thresholdUnits: Int) async throws
    func setAutoOffAlert(enabled: Bool, durationMinutes: Int) async throws
    func setSiteChangeReminder(enabled: Bool, days: Int, timeOfDayMinutes: Int) async throws
    func setAlertSnooze(enabled: Bool, durationMinutes: Int) async throws
    // CGM alert thresholds.
    func setCgmHighLowAlert(alertType: Int, thresholdMgdl: Int, repeatMinutes: Int, enabled: Bool) async throws
    func setCgmOutOfRangeAlert(enabled: Bool, delayMinutes: Int) async throws
    func setCgmRiseFallAlert(alertType: Int, enabled: Bool, mgdlPerMin: Int) async throws
}

/// The largest prime-cannula amount the UI allows (defense-in-depth on an insulin-dispensing step).
public enum FillLimits {
    public static let maxCannulaMilliunits = 1000   // 1.0 U — Tandem cannula prime is ~0.3 U
}

public enum ControlError: Error, LocalizedError {
    case notSupported
    public var errorDescription: String? { "This pump doesn't support that action." }
}

/// The outcome of reconciling a lost-outcome bolus against the pump's authoritative history (P0).
public enum BolusReconciliation: Sendable, Equatable {
    /// The pump's record for this bolus id was found: `deliveredUnits` actually went in (possibly a partial
    /// amount). `cancelled` is true when the pump reports it ended by cancellation.
    case resolved(deliveredUnits: Double, cancelled: Bool)
    /// The outcome can't be determined right now (offline, history not caught up, or the pump's last-bolus
    /// id doesn't match) — keep the delivery blocked and surface "verify on the pump".
    case unavailable
}

public extension PumpBackend {
    var historyEvents: [HistoryEvent] { [] }
    func refreshGlucoseNow() async {}
    /// Default: a backend that can't query its bolus history can never auto-reconcile, so a lost outcome
    /// stays blocked until manual verification (fail closed).
    func reconcile(bolusId: Int) async -> BolusReconciliation { .unavailable }

    /// Units-only convenience — forwards with no carb/BG/IOB metadata. Keeps existing call sites terse.
    func deliverBolus(units: Double) async throws -> Double {
        try await deliverBolus(units: units, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
    }
    /// Metadata-carrying convenience with a default `iobUnits: nil`, so callers that don't have a frozen
    /// IOB (e.g. the widget path) needn't pass it, while the frozen-proposal paths do (FB-04).
    func deliverBolus(units: Double, carbsGrams: Double?, bgMgdl: Int?) async throws -> Double {
        try await deliverBolus(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl, iobUnits: nil)
    }
    /// Extended convenience without carb/BG/IOB metadata.
    func deliverExtendedBolus(totalUnits: Double, nowUnits: Double, durationMinutes: Int) async throws -> Double {
        try await deliverExtendedBolus(totalUnits: totalUnits, nowUnits: nowUnits,
                                       durationMinutes: durationMinutes, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
    }
    func deliverExtendedBolus(totalUnits: Double, nowUnits: Double, durationMinutes: Int,
                              carbsGrams: Double?, bgMgdl: Int?) async throws -> Double {
        try await deliverExtendedBolus(totalUnits: totalUnits, nowUnits: nowUnits,
                                       durationMinutes: durationMinutes, carbsGrams: carbsGrams, bgMgdl: bgMgdl, iobUnits: nil)
    }
    /// Default: backends that don't support extended boluses throw.
    func deliverExtendedBolus(totalUnits: Double, nowUnits: Double, durationMinutes: Int,
                              carbsGrams: Double?, bgMgdl: Int?, iobUnits: Double?) async throws -> Double { throw ControlError.notSupported }
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
    func setControlIQ(enabled: Bool, weightLbs: Int, totalDailyInsulinUnits: Int) async throws { throw ControlError.notSupported }
    func refreshControlIQSettings() async {}
    func setPumpSounds(quickBolus: Int, general: Int, reminder: Int, alert: Int, alarm: Int, cgmA: Int, cgmB: Int) async throws { throw ControlError.notSupported }
    func refreshProfiles() async {}
    func setActiveProfile(idpId: Int) async throws { throw ControlError.notSupported }
    func renameProfile(idpId: Int, name: String) async throws { throw ControlError.notSupported }
    func deleteProfile(idpId: Int) async throws { throw ControlError.notSupported }
    func createProfile(name: String, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double,
                       isf: Int, targetBg: Int, insulinDurationMinutes: Int) async throws { throw ControlError.notSupported }
    func refreshProfileSegments(idpId: Int) async {}
    func addProfileSegment(idpId: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
                           carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async throws { throw ControlError.notSupported }
    func modifyProfileSegment(idpId: Int, segmentIndex: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
                              carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async throws { throw ControlError.notSupported }
    func deleteProfileSegment(idpId: Int, segmentIndex: Int) async throws { throw ControlError.notSupported }
    func setLowInsulinAlert(thresholdUnits: Int) async throws { throw ControlError.notSupported }
    func setAutoOffAlert(enabled: Bool, durationMinutes: Int) async throws { throw ControlError.notSupported }
    func setSiteChangeReminder(enabled: Bool, days: Int, timeOfDayMinutes: Int) async throws { throw ControlError.notSupported }
    func setAlertSnooze(enabled: Bool, durationMinutes: Int) async throws { throw ControlError.notSupported }
    func setCgmHighLowAlert(alertType: Int, thresholdMgdl: Int, repeatMinutes: Int, enabled: Bool) async throws { throw ControlError.notSupported }
    func setCgmOutOfRangeAlert(enabled: Bool, delayMinutes: Int) async throws { throw ControlError.notSupported }
    func setCgmRiseFallAlert(alertType: Int, enabled: Bool, mgdlPerMin: Int) async throws { throw ControlError.notSupported }
}

public enum BolusError: Error, LocalizedError {
    case notConnected, exceedsMax(Double), cancelled, pumpRejected(String)
    /// FB-02: the initiate command WAS written to the pump but its outcome is unknown (the response
    /// was lost to a timeout/disconnect). The bolus may or may not have started — the caller must NOT
    /// treat this as a plain failure/retry; it must reconcile against the pump's bolus history first.
    case indeterminate(String)
    /// FB-01: the dose was computed from unverified/assumed pump settings and cannot be auto-delivered.
    case unverifiedInputs(String)
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to a pump."
        case .exceedsMax(let m): return "Exceeds max bolus of \(m) u."
        case .cancelled: return "Bolus cancelled."
        case .pumpRejected(let r): return "Pump rejected the bolus: \(r)."
        case .indeterminate(let r): return "Bolus outcome unknown — verify on the pump: \(r)."
        case .unverifiedInputs(let r): return "Pump settings not verified: \(r)."
        }
    }
    /// True for an outcome that must block new deliveries until reconciled (FB-02).
    public var isIndeterminate: Bool { if case .indeterminate = self { return true } else { return false } }
}

/// Absolute defense-in-depth ceiling. The real cap is the pump's configured max bolus
/// (`PumpSnapshot.maxBolusUnits`); this is only a final sanity bound so a bug can't request an
/// absurd amount (the pump also rejects anything over its own limit).
public enum Interlocks {
    public static let absoluteMaxUnits: Double = 25.0
}
