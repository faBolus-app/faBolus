import Foundation

/// The **pump backend** interface — the stable seam between the faBolus UI and any pump. A backend
/// (TandemBackend/TandemKit, MockBackend, or a community backend) conforms to this; the app depends
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
    /// The TRUE pre-local-snooze-filter active-alert set: the pump's OWN raw bitmap for THIS poll,
    /// before any wearer/auto local snooze is subtracted. `nil` until the FIRST successful alert read
    /// on the current connection — a backend's underlying source lists may initialize to `[]` and
    /// never reset on disconnect, so a bare `[]` is ambiguous between "the pump has zero alerts" and
    /// "not yet polled"; the optional resolves it. This is the raw-snapshot proof-of-absence oracle
    /// for a pump that does NOT honor a remote dismiss (t:slim X2) — a wearer dismiss is removed on a
    /// remote ONLY when it is proven absent from this set, never from `activeNotifications`'
    /// local-snooze-contaminated absence.
    ///
    /// DEFAULT (below): returns `activeNotifications` — correct ONLY for a backend that applies NO
    /// local-snooze/auto-snooze filter to `activeNotifications` (a backend with no local-snooze
    /// concept reports its filtered set as always-known raw truth). A future backend that DOES
    /// locally filter, does NOT override this, and reports `supportsRemoteAlertDismiss == false`
    /// would feed its CONTAMINATED filtered set as the raw absence-oracle (a fail-open) — such a
    /// backend MUST override this with its true pre-filter set. `TandemBackend` overrides it (the
    /// only backend with a local filter today); `MockBackend` has none, so the default is correct
    /// for it.
    var rawActiveNotifications: [PumpAlert]? { get }
    /// Diagnostic string (raw alert bitmaps + poll count) for confirming the pump is answering.
    var alertDebug: String { get }
    /// Dismiss (clear) one alert on the pump — a signed control command. LEGACY void entry point; kept
    /// for existing callers (auto-rules). Every backend now gets `dismissNotificationTyped(_:)` for free
    /// (below); `TandemBackend` makes THIS method a thin wrapper that calls the typed one once and
    /// discards the outcome (MEDIUM-D: exactly one op-184 body, owned by the typed method).
    func dismissNotification(_ alert: PumpAlert) async
    /// The TYPED, authenticated outcome of a dismiss. The ONLY authenticated success signal is
    /// `.authenticatedCleared`, derived EXCLUSIVELY from a signed `status == 0` pump response —
    /// never inferred from a shared before/after transition on a mutable dict (a concurrent
    /// auto-snooze/local-snooze mutates the exact same key during the same async awaits a dismiss
    /// is awaiting on). Every backend gets a safe default for free (below, calls the void method
    /// once → `.notAuthenticated`); `TandemBackend` overrides it to OWN the single op-184 body and
    /// return the real outcome from the exact `status == 0` branch.
    func dismissNotificationTyped(_ alert: PumpAlert) async -> DismissOutcome
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
    /// DIF-ux — the same recommendation, but with the HOST-OWNER's warned per-attempt overrides for stale /
    /// unconfirmable calc inputs. `allowStaleIob` keeps SUBTRACTING the last-known op-109 IOB (never zeroes
    /// it); `allowStaleTherapy` sizes the dose off the last-known op-115 carb ratio / ISF / target — both
    /// still returning `inputsVerified == false`. Both default OFF everywhere via the extension below, so
    /// existing callers and remotes are unchanged and fail closed. ONLY the iPhone host compose flow ever
    /// passes `true`, and ONLY after an explicit warning (`StaleIobPrompt` / `StaleTherapyPrompt`); remotes
    /// (`resolveRemoteDose`) MUST never plumb it through, so a remote can never dose off unconfirmed inputs.
    func recommendBolus(
        carbsGrams: Double, bgMgdl: Int?,
        allowStaleIob: Bool, allowStaleTherapy: Bool
    ) async -> BolusRecommendation
    /// Request the newest CGM reading from the pump **now** and wait briefly for it (bounded), so a
    /// correction is computed off the freshest possible value. Best-effort: returns when the reading
    /// arrives or a short timeout elapses. Default no-op for backends that can't force a read.
    func refreshGlucoseNow() async
    /// Request the newest bolus-calculator INPUTS from the pump **now** and wait briefly for them
    /// (bounded), so an authoritative dose is built from fresh, self-consistent pump values rather than a
    /// ~10-min-stale cache: op-115 (carb ratio / ISF / target / max, resolved for the active
    /// profile+segment) and op-109 (active insulin). The exact analogue of `refreshGlucoseNow` for the
    /// calc inputs. Best-effort: returns when both arrive or a short timeout elapses. Default no-op for
    /// backends that can't force a read.
    func refreshCalcInputsNow() async
    /// Deliver a bolus of the given units. Returns the **actual delivered** units
    /// (may be a partial amount if cancelled mid-delivery). Check `lastBolusCancelled`.
    /// `carbsGrams`/`bgMgdl` are optional **metadata** recorded on the pump (pump graph / t:connect /
    /// Control-IQ carb awareness) — they do NOT change the delivered dose (the pump can't compute from
    /// carbs; the caller always sizes the units). Use the `deliverBolus(units:)` convenience for
    /// units-only.
    /// `iobUnits` is the **frozen calculator IOB** (the active insulin the dose was computed against),
    /// recorded on the pump as `bolusIOB` metadata. It is the value the calculator used at
    /// freeze time — NOT the live snapshot — so it preserves the approved inputs. Metadata only.
    func deliverBolus(units: Double, carbsGrams: Double?, bgMgdl: Int?, iobUnits: Double?) async throws -> Double
    /// Deliver an **extended (combo)** bolus: `nowUnits` up front and the remainder over
    /// `durationMinutes`. Total must be ≥ 0.40 U. Returns the actual delivered-so-far units. Optional
    /// — backends that don't support it use the throwing default. `carbsGrams`/`bgMgdl`/`iobUnits` are
    /// recorded metadata (see `deliverBolus`).
    func deliverExtendedBolus(
        totalUnits: Double, nowUnits: Double, durationMinutes: Int,
        carbsGrams: Double?, bgMgdl: Int?, iobUnits: Double?
    ) async throws -> Double
    func cancelBolus() async
    /// True if the most recent `deliverBolus` was cancelled before completing.
    var lastBolusCancelled: Bool { get }
    /// Called by the view model to observe changes.
    var onChange: (@MainActor () -> Void)? { get set }

    // MARK: - Durable unknown-outcome recovery

    /// Called by the backend the instant the pump grants a bolus permission and assigns a bolus id —
    /// **before** any metadata/initiate is written. The host must DURABLY record the id (and its
    /// "initiate imminent" phase) and return `true` only if that save succeeded. If it returns `false`,
    /// the backend MUST abort before writing metadata/initiate (round-3 §5) — nothing is delivered and the
    /// durable ledger stays blocked/clean, so a save failure can never leave an id-less record that a
    /// relaunch mistakes for "not sent." An acknowledged, awaited handshake — not a fire-and-forget post.
    var commitBolusId: (@MainActor (Int) async -> Bool)? { get set }
    /// Reconcile a previously-sent bolus whose outcome was lost, against the pump's **authoritative** bolus
    /// history, by its pump-assigned id. Returns `.resolved` only on an authoritative id match; otherwise
    /// `.unavailable` so the host keeps the delivery blocked and asks the user to verify on the pump.
    func reconcile(bolusId: Int) async -> BolusReconciliation
    /// Release a backend's OWN in-memory "an unknown-outcome bolus blocks new deliveries" flag, called
    /// ONLY from the host's manual verification affordance. This is a SECOND fail-closed layer,
    /// independent of the host's durable ledger block — a backend that has no such flag (the default
    /// below) is unaffected. The host must call this together with releasing its own block, never one
    /// without the other, so a manual clear can't leave a backend-side flag re-refusing the exact
    /// delivery the user just unblocked.
    func clearUnknownOutcomeAfterManualVerification()

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
    /// Set the pump user mode (sleep/exercise on/off). Takes the typed `ModeCommand` rather than a raw
    /// bitmap so a caller can't confuse the command (1…4) with the reported state (0…2). Insulin-affecting
    /// (changes Control-IQ behavior). Precondition: Control-IQ must be ON (enforced pre-flight upstream).
    func setMode(_ command: ModeCommand) async throws
    /// Play the "find my pump" sound. Non-insulin.
    func playFindMyPump() async throws

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

    /// B4 — clear the pump-DERIVED CONFIG fields of the snapshot (max bolus/basal, calculator therapy
    /// params, Control-IQ config, controller variant, profiles/segments) back to defaults, and reset the
    /// FRESHNESS of every live reading (glucose, IOB, reservoir, battery, basal rate) to unknown, so a
    /// DIFFERENT pump's config or readings can never be shown or dosed against before the new pump
    /// answers. Values already read are kept — a reading is never fabricated to zero — only their age
    /// resets to "never read this connection." Connection state and delivery-suspended are unaffected.
    /// MUST NOT call `onChange` — the caller (`AppModel.refresh`) republishes; a nested notify would
    /// re-enter refresh. Synchronous. Default no-op (a stateless/simulated backend re-seeds on connect
    /// anyway).
    func resetSnapshotForPumpSwitch()

    // Control-IQ settings (non-insulin config; changes closed-loop behavior).
    func setControlIQ(enabled: Bool, weightLbs: Int, totalDailyInsulinUnits: Int) async throws
    func refreshControlIQSettings() async
    /// Read the pump's native Sleep-schedule slots into `snapshot.sleepSchedules`. Universal/unsigned
    /// read — NOT capability-gated; sendable and harmless on any connected pump model regardless of
    /// `PumpCapabilities.supportsSleepScheduleWrite`.
    func refreshSleepSchedule() async
    /// Write one native Sleep-schedule slot. Mobi-only by capability
    /// (`PumpCapabilities.supportsSleepScheduleWrite`) — mirrors the pump protocol's own MOBI_ONLY
    /// device scope. Mode-only: the underlying wire write is `.settings` risk, never `.delivery` —
    /// this call never reaches the dose/delivery path. `activeDays` is the confirmed upstream
    /// `MultiDay` bit mask (Monday=bit0(1)…Sunday=bit6(64)); `startMinute`/`endMinute` are
    /// minute-of-day, clamped to 0...1439 by the implementation.
    func setSleepSchedule(slot: Int, enabled: Bool, activeDays: Int, startMinute: Int, endMinute: Int) async throws
    // Pump sounds — annunciation level per category (0 audioHigh … 3 vibrate).
    func setPumpSounds(quickBolus: Int, general: Int, reminder: Int, alert: Int, alarm: Int, cgmA: Int, cgmB: Int)
        async throws
    // Insulin-delivery profiles (IDP). Switch/rename/delete are insulin-affecting (change active basal).
    func refreshProfiles() async
    func setActiveProfile(idpId: Int) async throws
    func renameProfile(idpId: Int, name: String) async throws
    func deleteProfile(idpId: Int) async throws
    /// Create a new profile with one initial time-segment (starting at midnight).
    func createProfile(
        name: String, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double,
        isf: Int, targetBg: Int, insulinDurationMinutes: Int) async throws
    /// Read a profile's time-segments into `snapshot.viewedProfileSegments`.
    func refreshProfileSegments(idpId: Int) async
    func addProfileSegment(
        idpId: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
        carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async throws
    func modifyProfileSegment(
        idpId: Int, segmentIndex: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
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

/// The prime-cannula bounds the UI allows (defense-in-depth on an insulin-dispensing step).
public enum FillLimits {
    public static let maxCannulaMilliunits = 1000  // 1.0 U — Tandem cannula prime is ~0.3 U. Deliberate cap
    // (NOT raised alongside the kit's
    // FillCannulaRequest 3000 mU ceiling.
    /// 0 is never a valid fill — pumpX2's `FillCannulaRequest` throws on
    /// `primeSizeMilliUnits <= 0`. The app-side clamp must not leave 0 reachable (two-layer
    /// defense: the kit init is the primary boundary, this clamp is the secondary one).
    public static let minCannulaMilliunits = 1

    /// Shared clamp used by every backend that constructs a `FillCannulaRequest`-equivalent write, so 0
    /// (upstream-invalid) can never reach the wire and the deliberate `maxCannulaMilliunits` cap is never
    /// exceeded. Mirrors `Interlocks.clampMaxBolusLimit`'s "one definition, every backend" pattern.
    public static func clampPrimeSize(_ milliunits: Int) -> Int {
        max(minCannulaMilliunits, min(milliunits, maxCannulaMilliunits))
    }
}

public enum ControlError: Error, LocalizedError {
    case notSupported
    public var errorDescription: String? { "This pump doesn't support that action." }
}

/// The outcome of reconciling a lost-outcome bolus against the pump's authoritative history.

/// Additive capability protocol naming the read-only history-sync surface `TandemBackend` exposes
/// (`HistorySyncState`). `PumpBackend` itself gains nothing; a backend opts in by additionally
/// conforming here. `AppModel` already casts to this for `historySyncState` / `triggerManualHistorySync`
/// / `cancelHistorySync`. `TandemOnlyOps` keeps remaining Tandem-only members.
@MainActor
public protocol PumpHistoryProviding: AnyObject {
    /// The gap-sync's current state for the "Pump history sync" UI section.
    var historySyncState: HistorySyncState { get }
    /// Manually run the gap-aware history sync regardless of the automatic-sync toggle.
    func triggerManualHistorySync()
    /// Abort an in-progress manual/automatic gap sync.
    func cancelHistorySync()
}

/// Additive capability protocol naming the diagnostics/telemetry-only hooks `TandemBackend`
/// exposes, so `AppModel`'s diagnostics wiring can depend on a capability slice instead of the
/// concrete type. `PumpBackend` itself gains nothing; a backend opts in by additionally conforming
/// here. `AppModel` already casts to this for `onCommandLatency` / `onWillRetryReconnect` /
/// `badOpcodesForDiagnostics`. `alertDebug` stays a plain `PumpBackend` member — reached without
/// any cast.
@MainActor
public protocol PumpDiagnosticsProviding: AnyObject {
    /// B3a (§5.2.8): observational command round-trip latency sink. Diagnostics-only; never influences
    /// control flow.
    var onCommandLatency: (@MainActor (Double?) -> Void)? { get set }
    /// Observational reconnect-ladder sink. Diagnostics-only; never influences control flow.
    var onWillRetryReconnect: (@MainActor (Int, TimeInterval) -> Void)? { get set }
    /// Opcodes the connected pump has rejected this connection-lifetime, for the
    /// `[Capability/opcode]` diagnostics section.
    var badOpcodesForDiagnostics: Set<UInt8> { get }
    /// Forget every learned read exclusion for the currently-adopted pump and re-probe from the next
    /// poll, WITHOUT unpairing. Recovery path for debug session `tslim-reservoir-battery-zero`: an
    /// exclusion learned from a transient error used to be permanent, and the only way out was a full
    /// `forgetPairing()` (which also drops pairing credentials and the trusted-identity record).
    ///
    /// Cannot make a read appear to have SUCCEEDED — it only re-enables sending it — so it can never
    /// turn an unknown pre-guard into a confirmed-ready one.
    func resetLearnedReadExclusions()
}

extension PumpDiagnosticsProviding {
    /// Default no-op, so a backend with no learned-exclusion machinery (mocks, tests, a future
    /// non-Tandem backend) conforms without change.
    public func resetLearnedReadExclusions() {}
}

/// The phone's TYPED, authenticated outcome of a signed pump dismiss
/// (`PumpBackend.dismissNotificationTyped(_:)`). `.authenticatedCleared` is the ONLY case that
/// authorizes a durable Garmin `dismissAck` — it is derived exclusively from a `status == 0`
/// signed pump response, never from a shared before/after transition on a mutable dict (a
/// concurrent auto-snooze/local-snooze mutates that exact key during the same async awaits a
/// dismiss is awaiting on). Every other case fails closed: no ack, the alert stays visible.
public enum DismissOutcome: Sendable, Equatable {
    /// The pump signed-confirmed the clear (`status == 0`). The SOLE authenticated success signal.
    case authenticatedCleared
    /// The pump signed-responded with a non-zero (rejected) status.
    case rejected
    /// No signed response arrived in time (timeout / disconnect / a pre-write send failure).
    case noResponse
    /// This pump model doesn't honor a remote dismiss (t:slim X2) — a PURE LOCAL snooze; no op-184 was
    /// ever sent. Never authenticated, never acked.
    case localSnoozeOnly
    /// The backend doesn't implement the typed path at all (the community-default extension impl) — the
    /// LEGACY void method was called once and its real outcome is opaque to this caller. Never treated
    /// as authenticated.
    case notAuthenticated
}

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
    /// Default: a conformer with no local-snooze concept reports its filtered set as
    /// the always-known raw truth — see the protocol requirement's doc comment for the fail-open caveat
    /// a backend that DOES locally filter must heed by overriding this.
    var rawActiveNotifications: [PumpAlert]? { activeNotifications }
    /// Community-default typed dismiss: calls the LEGACY void `dismissNotification(_:)` exactly ONCE
    /// and returns `.notAuthenticated` — never authenticated, so a community backend that hasn't
    /// implemented the typed path can never trigger a Garmin `dismissAck` by accident.
    /// `TandemBackend` overrides this to own the single op-184 body and return the real,
    /// authenticated outcome.
    func dismissNotificationTyped(_ alert: PumpAlert) async -> DismissOutcome {
        await dismissNotification(alert)
        return .notAuthenticated
    }
    /// DIF-ux default: a backend that doesn't implement the override IGNORES it and falls back to the plain
    /// (no-override) recommendation — i.e. it stays fail-closed. This is the fail-SAFE direction (an
    /// unhonored "use last-known" simply keeps the surface blocked, never dosing off unconfirmed inputs), so
    /// community backends + the conformance stub get correct safety for free. `TandemBackend` / `MockBackend`
    /// override this with the real last-known recompute.
    func recommendBolus(
        carbsGrams: Double, bgMgdl: Int?,
        allowStaleIob: Bool, allowStaleTherapy: Bool
    ) async -> BolusRecommendation {
        await recommendBolus(carbsGrams: carbsGrams, bgMgdl: bgMgdl)
    }
    func refreshGlucoseNow() async {}
    func refreshCalcInputsNow() async {}
    /// B4 default: no-op. A backend that rebuilds its snapshot on connect (the simulator) needs nothing
    /// here; `TandemBackend` overrides to clear the live pump's stale config on an in-run pump swap.
    func resetSnapshotForPumpSwitch() {}
    /// Default: a backend that can't query its bolus history can never auto-reconcile, so a lost outcome
    /// stays blocked until manual verification (fail closed).
    func reconcile(bolusId: Int) async -> BolusReconciliation { .unavailable }
    /// Default no-op: a backend with no in-memory unknown-outcome flag has nothing to clear.
    func clearUnknownOutcomeAfterManualVerification() {}

    /// Units-only convenience — forwards with no carb/BG/IOB metadata. Keeps existing call sites terse.
    func deliverBolus(units: Double) async throws -> Double {
        try await deliverBolus(units: units, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
    }
    /// Metadata-carrying convenience with a default `iobUnits: nil`, so callers that don't have a frozen
    /// IOB (e.g. the widget path) needn't pass it, while the frozen-proposal paths do.
    func deliverBolus(units: Double, carbsGrams: Double?, bgMgdl: Int?) async throws -> Double {
        try await deliverBolus(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl, iobUnits: nil)
    }
    /// Extended convenience without carb/BG/IOB metadata.
    func deliverExtendedBolus(totalUnits: Double, nowUnits: Double, durationMinutes: Int) async throws -> Double {
        try await deliverExtendedBolus(
            totalUnits: totalUnits, nowUnits: nowUnits,
            durationMinutes: durationMinutes, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
    }
    func deliverExtendedBolus(
        totalUnits: Double, nowUnits: Double, durationMinutes: Int,
        carbsGrams: Double?, bgMgdl: Int?
    ) async throws -> Double {
        try await deliverExtendedBolus(
            totalUnits: totalUnits, nowUnits: nowUnits,
            durationMinutes: durationMinutes, carbsGrams: carbsGrams, bgMgdl: bgMgdl, iobUnits: nil)
    }
    /// Default: backends that don't support extended boluses throw.
    func deliverExtendedBolus(
        totalUnits: Double, nowUnits: Double, durationMinutes: Int,
        carbsGrams: Double?, bgMgdl: Int?, iobUnits: Double?
    ) async throws -> Double { throw ControlError.notSupported }
    func suspendDelivery() async throws { throw ControlError.notSupported }
    func resumeDelivery() async throws { throw ControlError.notSupported }
    func setTempBasal(percent: Int, durationMinutes: Int) async throws { throw ControlError.notSupported }
    func stopTempBasal() async throws { throw ControlError.notSupported }
    func setMode(_ command: ModeCommand) async throws { throw ControlError.notSupported }
    func playFindMyPump() async throws { throw ControlError.notSupported }

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
    func setControlIQ(enabled: Bool, weightLbs: Int, totalDailyInsulinUnits: Int) async throws {
        throw ControlError.notSupported
    }
    func setSleepSchedule(slot: Int, enabled: Bool, activeDays: Int, startMinute: Int, endMinute: Int) async throws {
        throw ControlError.notSupported
    }
    func refreshControlIQSettings() async {}
    func refreshSleepSchedule() async {}
    func setPumpSounds(quickBolus: Int, general: Int, reminder: Int, alert: Int, alarm: Int, cgmA: Int, cgmB: Int)
        async throws
    { throw ControlError.notSupported }
    func refreshProfiles() async {}
    func setActiveProfile(idpId: Int) async throws { throw ControlError.notSupported }
    func renameProfile(idpId: Int, name: String) async throws { throw ControlError.notSupported }
    func deleteProfile(idpId: Int) async throws { throw ControlError.notSupported }
    func createProfile(
        name: String, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double,
        isf: Int, targetBg: Int, insulinDurationMinutes: Int
    ) async throws { throw ControlError.notSupported }
    func refreshProfileSegments(idpId: Int) async {}
    func addProfileSegment(
        idpId: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
        carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int
    ) async throws { throw ControlError.notSupported }
    func modifyProfileSegment(
        idpId: Int, segmentIndex: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
        carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int
    ) async throws { throw ControlError.notSupported }
    func deleteProfileSegment(idpId: Int, segmentIndex: Int) async throws { throw ControlError.notSupported }
    func setLowInsulinAlert(thresholdUnits: Int) async throws { throw ControlError.notSupported }
    func setAutoOffAlert(enabled: Bool, durationMinutes: Int) async throws { throw ControlError.notSupported }
    func setSiteChangeReminder(enabled: Bool, days: Int, timeOfDayMinutes: Int) async throws {
        throw ControlError.notSupported
    }
    func setAlertSnooze(enabled: Bool, durationMinutes: Int) async throws { throw ControlError.notSupported }
    func setCgmHighLowAlert(alertType: Int, thresholdMgdl: Int, repeatMinutes: Int, enabled: Bool) async throws {
        throw ControlError.notSupported
    }
    func setCgmOutOfRangeAlert(enabled: Bool, delayMinutes: Int) async throws { throw ControlError.notSupported }
    func setCgmRiseFallAlert(alertType: Int, enabled: Bool, mgdlPerMin: Int) async throws {
        throw ControlError.notSupported
    }
}

public enum BolusError: Error, LocalizedError {
    case notConnected, exceedsMax(Double), cancelled, pumpRejected(String)
    /// The initiate command WAS written to the pump but its outcome is unknown (the response
    /// was lost to a timeout/disconnect). The bolus may or may not have started — the caller must NOT
    /// treat this as a plain failure/retry; it must reconcile against the pump's bolus history first.
    case indeterminate(String)
    /// The dose was computed from unverified/assumed pump settings and cannot be auto-delivered.
    case unverifiedInputs(String)
    /// The cartridge is mid change/load/prime-tubing (`!PumpSnapshot.cartridgeReadyForBolus`)
    /// — dosing is physically impossible. Thrown BEFORE any signed frame is written; never a delivered
    /// value, never a mutation of delivery state (fail-closed — never reports success for this).
    case noCartridge(String)
    /// The pump refused a real delivery attempt (nack) while the app's own last-known
    /// `reservoirUnits` reading was below the requested total. Distinct from generic `.pumpRejected`
    /// — but the wire protocol has no insulin-specific nack code (`BolusPermissionResponse` /
    /// `InitiateBolusResponse` are exhaustive with no reservoir signal), so the cause MUST be
    /// worded as an inference from the app's own reading, never a pump-confirmed fact. A clean
    /// pre-initiate failure (never indeterminate, never delivered).
    case possiblyOutOfInsulin(reservoirUnits: Double, nackDetail: String)
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to a pump."
        case .exceedsMax(let m): return "Exceeds max bolus of \(m) u."
        case .cancelled: return "Bolus cancelled."
        case .pumpRejected(let r): return "Pump rejected the bolus: \(r)."
        case .indeterminate(let r): return "Bolus outcome unknown — verify on the pump: \(r)."
        case .unverifiedInputs(let r): return "Pump settings not verified: \(r)."
        case .noCartridge(let r): return "Cartridge not loaded: \(r)."
        case .possiblyOutOfInsulin(let reservoirUnits, let nackDetail):
            return
                "Pump refused the bolus (\(nackDetail)); last known reservoir was \(reservoirUnits) u — this may be due to insufficient insulin."
        }
    }
    /// True for an outcome that must block new deliveries until reconciled.
    public var isIndeterminate: Bool { if case .indeterminate = self { return true } else { return false } }
}

/// Absolute defense-in-depth ceiling. The real cap is the pump's configured max bolus
/// (`PumpSnapshot.maxBolusUnits`); this is only a final sanity bound so a bug can't request an
/// absurd amount (the pump also rejects anything over its own limit).
public enum Interlocks {
    public static let absoluteMaxUnits: Double = 25.0
    /// Raised from the prior 0.05 U (the pump's minimum programming increment) to 1.0 U to match
    /// TandemKit's `SetMaxBolusLimitRequest` throwing floor (pumpX2's own `MIN_BOLUS_LIMIT_MILLIUNITS`),
    /// so a legitimate app-originated limit can never throw at the kit boundary after UI confirmation.
    /// Conservative/unverified (bench-pinnable) — not independently bench-confirmed by the app team.
    public static let minMaxBolusLimitUnits: Double = 1.0
    /// The max-basal **limit** floor, matching TandemKit's `SetMaxBasalLimitRequest` throwing floor
    /// (pumpX2's `MIN_BASAL_LIMIT_MILLIUNITS`). Before this the app clamped max-basal only to
    /// `max(0, …)` (`TandemBackend.setMaxBasal`), below the kit's floor. Conservative/unverified
    /// (bench-pinnable).
    public static let minMaxBasalLimitUnitsPerHour: Double = 1.0
    /// The max-basal **limit** ceiling, matching TandemKit's `SetMaxBasalLimitRequest` throwing ceiling
    /// (pumpX2's `MAX_BASAL_LIMIT_MILLIUNITS` = 15000 mU/hr = 15.0 U/hr, byte-verified against
    /// `SetMaxBasalLimitRequest.java`). A faBolusCore-side literal because `Interlocks` doesn't import
    /// `TandemMessages`; without it a request above 15 U/hr throws at the kit boundary instead of clamping.
    /// Conservative/unverified (bench-pinnable).
    public static let maxMaxBasalLimitUnitsPerHour: Double = 15.0
    /// Clamp a requested max-bolus **limit** into the app's absolute range. The 25 U ceiling is a HARD cap
    /// (never a confirmation) — a limit can never be set above it, on ANY backend. This is the single
    /// definition the funnel (`AppModel.setMaxBolus`) and every backend share, so the invariant no
    /// longer depends on which backend is active (a `MockBackend` used to skip it). Distinct from the
    /// per-bolus DELIVERY block (`deliverBolus` throws `.exceedsMax`) — this does not replace that.
    public static func clampMaxBolusLimit(_ units: Double) -> Double {
        max(minMaxBolusLimitUnits, min(units, absoluteMaxUnits))
    }
    /// Clamp a requested max-basal **limit** (U/hr) into the app's supported range. Mirrors
    /// `clampMaxBolusLimit`: floors at `minMaxBasalLimitUnitsPerHour` and caps at
    /// `maxMaxBasalLimitUnitsPerHour` (the kit's byte-verified 15.0 U/hr throwing ceiling), so an
    /// app-originated limit can never throw at the kit boundary — a value above 15 U/hr clamps to 15.0
    /// and dispatches rather than surfacing a raw, unlocalized `ValidationError`. Single shared definition
    /// the funnel (`AppModel.setMaxBasal`) and every backend route a max-basal-LIMIT write through.
    public static func clampMaxBasalLimit(_ unitsPerHour: Double) -> Double {
        max(minMaxBasalLimitUnitsPerHour, min(unitsPerHour, maxMaxBasalLimitUnitsPerHour))
    }
}
