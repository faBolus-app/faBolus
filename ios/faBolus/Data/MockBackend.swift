import Foundation
import faBolusCore

/// In-memory pump simulator so the HUD runs in the Simulator / SwiftUI previews with no
/// hardware. Generates a plausible glucose trace and simple IOB/COB dynamics. A reference
/// `PumpBackend` implementation — copy it as a starting point for a new backend.
@MainActor
public final class MockBackend: PumpBackend {
    // A simulator can present as a Mobi (full advanced-control surface, for trying the wizards) or a
    // t:slim X2 (bolus/status only), selected via the backend picker. The control wizards still
    // require AppSettings.advancedControlEnabled = on and only appear for the Mobi simulator.
    private let mobi: Bool
    public var capabilities: PumpCapabilities { mobi ? .mobiAdvanced : .full }
    public private(set) var snapshot = PumpSnapshot()
    public private(set) var glucoseHistory: [GlucoseReading] = []
    public private(set) var iobHistory: [IOBSample] = []
    public private(set) var bolusMarkers: [BolusMarker] = []
    public private(set) var activeNotifications: [PumpAlert] = [
        PumpAlert(id: 0, kind: .alert, title: "Low insulin",
                  detail: "Low amount of insulin remaining in the cartridge.")
    ]
    public var alertDebug: String { "mock" }
    public private(set) var lastBolusCancelled = false
    public func dismissNotification(_ alert: PumpAlert) async {
        activeNotifications.removeAll { $0.id == alert.id && $0.kind == alert.kind }
        onChange?()
    }
    public var pairingCode: String = ""   // unused by the mock
    public var hasStoredPairing: Bool { false }
    public func forgetPairing() {}
    public var onChange: (@MainActor () -> Void)?

    // MARK: - Durable unknown-outcome recovery (P0)
    public var commitBolusId: (@MainActor (Int) async -> Bool)?
    /// The next simulated pump-assigned bolus id (mimics `BolusPermissionResponse.bolusId`).
    private var nextBolusId = 1000
    /// The id assigned to the most recent delivery attempt (so a test can drive `reconcile`).
    public private(set) var lastAssignedBolusId: Int?
    /// Test knob: what `reconcile(bolusId:)` returns per pump bolus id. Absent ⇒ `.unavailable`
    /// (outcome still unknown ⇒ stays blocked), matching a pump whose history hasn't caught up.
    public var reconcileResultsById: [Int: BolusReconciliation] = [:]
    public func reconcile(bolusId: Int) async -> BolusReconciliation {
        reconcileResultsById[bolusId] ?? .unavailable
    }

    private var timer: Timer?

    public init(isMobi: Bool = true) { self.mobi = isMobi; seedHistory() }

    private func seedHistory() {
        let now = Date()
        // The seeded history ends deliberately in the PAST (older than the 6-minute stale threshold),
        // because a just-launched simulator has not yet received a live reading — so the seed reads as
        // stale, exactly like a real backend before its first poll lands. `tick()` then produces fresh
        // readings. Tests depend on this: a stale seed keeps a carb dose resolving off carbs-only, which
        // is deterministic. Use `seedFreshGlucose` to exercise the fresh path.
        let newest = now.addingTimeInterval(-600)
        var value = 120.0
        var readings: [GlucoseReading] = []
        // 3 hours of 5-minute CGM samples, gently oscillating.
        for i in stride(from: 36, through: 0, by: -1) {
            let t = newest.addingTimeInterval(TimeInterval(-i * 300))
            value += Double.random(in: -8...8)
            value = min(max(value, 70), 220)
            readings.append(GlucoseReading(date: t, mgdl: Int(value)))
        }
        glucoseHistory = readings
        // Sample IOB decay + a couple of boluses for the chart overlay.
        iobHistory = stride(from: 36, through: 0, by: -1).map {
            IOBSample(date: now.addingTimeInterval(TimeInterval(-$0 * 300)),
                      iob: max(0, 3.0 - Double(36 - $0) * 0.07))
        }
        bolusMarkers = [
            BolusMarker(date: now.addingTimeInterval(-3600), units: 2.0),
            BolusMarker(date: now.addingTimeInterval(-1500), units: 1.0),
        ]
        snapshot.glucose = readings.last?.mgdl
        // Group A: a backend MUST publish the reading's timestamp alongside its value. Leaving this nil
        // was the live reproducer for defect A1 — the phone correctly read "unknown age ⇒ stale" and
        // showed no recent CGM, while the Garmin watch stamped the same reading "now" and let it dose.
        // Any new backend has the same obligation; see `PumpSnapshot.isGlucoseStale`.
        snapshot.glucoseDate = readings.last?.date
        snapshot.iobUnits = 1.4
        // DIF-core: a backend must stamp WHEN it read the calc inputs, exactly as it does `glucoseDate`.
        // The simulator's IOB + therapy are "read" at seed time, so they start fresh (a real backend seeds
        // these on connect + poll). `refreshCalcInputsNow()` and `tick()` keep them fresh thereafter.
        let seededAt = Date()
        snapshot.iobDate = seededAt
        snapshot.therapyParamsDate = seededAt
        snapshot.reservoirUnits = 142
        snapshot.batteryPercent = 78
        snapshot.cgmActive = true
        snapshot.carbRatio = 10; snapshot.isf = 40; snapshot.targetBg = 110; snapshot.maxBolusUnits = 25
        snapshot.lastBolusUnits = 2.0
        snapshot.lastBolusDate = now.addingTimeInterval(-3600)
        snapshot.isMobi = mobi
        snapshot.pumpModelName = mobi ? "Mobi (simulated)" : "t:slim X2 (simulated)"
        snapshot.basalRateUnitsPerHour = 0.8
        snapshot.controlIQEnabled = true
        snapshot.cgmSessionActive = true
        snapshot.cartridgeLoadState = 6      // unknown/idle
    }

    public func connect() async {
        snapshot.connection = .scanning; onChange?()
        try? await Task.sleep(nanoseconds: 500_000_000)
        snapshot.connection = .connecting; onChange?()
        try? await Task.sleep(nanoseconds: 500_000_000)
        snapshot.connection = .connected; onChange?()
        startTicking()
    }

    public func disconnect() {
        timer?.invalidate(); timer = nil
        snapshot.connection = .disconnected; onChange?()
    }

    private func startTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard var last = glucoseHistory.last?.mgdl else { return }
        last = min(max(last + Int.random(in: -6...6), 60), 240)
        let at = Date()
        glucoseHistory.append(GlucoseReading(date: at, mgdl: last))
        if glucoseHistory.count > 72 { glucoseHistory.removeFirst() }
        snapshot.glucose = last
        snapshot.glucoseDate = at          // group A: value and timestamp move together, always
        snapshot.iobUnits = max(0, snapshot.iobUnits - 0.02)
        snapshot.iobDate = at              // DIF-core: IOB value and its receive-time move together, always
        onChange?()
    }

    /// Mock calculator: the same oracle-backed `BolusMath` as the real backend, with a fixed mock
    /// profile (carb ratio 10 g/U, ISF 40, target 110). Keeps the simulator in lockstep with the
    /// production dosing semantics (audit C-01).
    /// Test knob (FB-01): when true, `recommendBolus` reports the dose as computed from ASSUMED
    /// (unverified) settings, so callers must fail closed / require the assumptions ack.
    public var forceUnverifiedInputs = false
    /// Test knob (DIF-ux): force the IOB read to read as STALE even after the mock re-stamps it fresh in
    /// `refreshCalcInputsNow()`, so a test can exercise the warned include-last-known-IOB override path.
    public var forceIobStale = false
    /// Test knob (DIF-ux): force the therapy-params read to read as STALE, for the use-last-known-settings
    /// override path.
    public var forceTherapyStale = false
    /// Test knob (FB-02): when true, the NEXT `deliverBolus`/`deliverExtendedBolus` throws
    /// `.indeterminate` (as if the initiate response was lost after the write). One-shot.
    public var forceIndeterminateNextDelivery = false
    /// Test hook (P11/S6): when set, `deliverBolus`/`deliverExtendedBolus` awaits this once the delivery
    /// is IN FLIGHT (bolus id recorded, `.bolusing`, before completion) instead of the fixed sleep — so a
    /// test can hold one delivery open on the pump and issue a concurrent one to exercise the cross-client
    /// in-flight mutex. nil in production (like `commitBolusId` / `forceIndeterminateNextDelivery`).
    public var onDeliverInFlight: (@MainActor () async -> Void)?

    /// Test knob (GA-05): seed a FRESH glucose reading. The seeded history is deliberately 10 minutes
    /// old, so the default state is stale-with-a-known-age. Lets a test exercise the non-stale
    /// correction path. (It used to be stale because `glucoseDate` was nil — an unknown age. That was
    /// the group-A reproducer, since remotes could then invent a timestamp for it.)
    public func seedFreshGlucose(_ mgdl: Int, at date: Date = Date()) {
        snapshot.glucose = mgdl; snapshot.glucoseDate = date; onChange?()
    }
    /// Test knob (FB-04): set the LIVE IOB, so a test can prove a delivery sends the FROZEN calc IOB, not
    /// the live snapshot value.
    public func setLiveIob(_ u: Double) { snapshot.iobUnits = u; onChange?() }
    /// Spy (FB-04): the exact metadata the most recent delivery passed to the backend.
    public private(set) var lastDeliver: (units: Double, carbs: Double?, bg: Int?, iob: Double?)?
    /// DIF-core spy: how many times `refreshCalcInputsNow()` was invoked, so a test can prove the dose path
    /// forced a fresh op-115 + op-109 read (the mock's analogue of those pump reads) before recommending.
    public private(set) var refreshCalcInputsNowCount = 0

    /// DIF-core: the simulator's analogue of forcing a fresh op-115 + op-109 read — it re-stamps the calc
    /// inputs fresh (a real pump answers those reads) and counts the call for the spy.
    public func refreshCalcInputsNow() async {
        refreshCalcInputsNowCount += 1
        let now = Date()
        snapshot.iobDate = now
        snapshot.therapyParamsDate = now
        onChange?()
    }

    public func recommendBolus(carbsGrams: Double, bgMgdl: Int?) async -> BolusRecommendation {
        await recommendBolus(carbsGrams: carbsGrams, bgMgdl: bgMgdl, allowStaleIob: false, allowStaleTherapy: false)
    }

    public func recommendBolus(carbsGrams: Double, bgMgdl: Int?,
                               allowStaleIob: Bool, allowStaleTherapy: Bool) async -> BolusRecommendation {
        // DIF-core parity with the real backend: build the authoritative recommendation from FRESH inputs.
        await refreshCalcInputsNow()
        var rec = BolusRecommendation()
        rec.carbsGrams = carbsGrams
        rec.bgMgdl = bgMgdl
        rec.iobUnits = snapshot.iobUnits
        let now = Date()
        rec.iobDate = snapshot.iobDate
        rec.therapyParamsDate = snapshot.therapyParamsDate
        // Test knobs (DIF-ux) let a test force staleness independent of the just-re-stamped dates.
        rec.iobStale = forceIobStale || snapshot.isIobStale(now: now)
        rec.therapyStale = forceTherapyStale || snapshot.isTherapyStale(now: now)
        let profile = BolusMath.Profile(carbRatioGramsPerUnit: 10, isfMgdlPerUnit: 40,
                                        targetBgMgdl: 110, iobUnits: snapshot.iobUnits)
        let carbs: Double? = carbsGrams > 0 ? carbsGrams : nil
        let verified = !forceUnverifiedInputs && !rec.iobStale && !rec.therapyStale
        if verified {
            rec.recommendedUnits = BolusMath.recommendedUnits(carbsGrams: carbs, bgMgdl: bgMgdl, profile: profile)
            rec.inputsVerified = true
        } else {
            rec.inputsVerified = false
            rec.assumedProfile = profile
            // Mirror the TandemBackend DIF-ux override: only under an explicit owner override do we retain
            // the BG correction off the last-known (mock: fixed) profile; include-last-known IOB keeps
            // SUBTRACTING `snapshot.iobUnits` (never zeroes it). The mock always HAS last-known therapy.
            let overrideActive = allowStaleIob || allowStaleTherapy
            let therapyTrustworthy = !rec.therapyStale || allowStaleTherapy
            let overrideBg: Int? = (overrideActive && therapyTrustworthy) ? bgMgdl : nil
            rec.recommendedUnits = BolusMath.recommendedUnits(carbsGrams: carbs, bgMgdl: overrideBg, profile: profile)
        }
        rec.recommendedUnits = (rec.recommendedUnits * 20).rounded() / 20   // round to 0.05u
        return rec
    }

    public func deliverExtendedBolus(totalUnits: Double, nowUnits: Double, durationMinutes: Int,
                                     carbsGrams: Double?, bgMgdl: Int?, iobUnits: Double?) async throws -> Double {
        guard snapshot.connection == .connected else { throw BolusError.notConnected }
        guard totalUnits <= snapshot.maxBolusUnits else { throw BolusError.exceedsMax(snapshot.maxBolusUnits) }
        // Simulate the pump granting permission + assigning a bolus id BEFORE the initiate write (P0).
        let bolusId = nextBolusId; nextBolusId += 1; lastAssignedBolusId = bolusId
        // Round-3 §5: the host must durably record the id; abort pre-initiate if it can't.
        if let commit = commitBolusId, await commit(bolusId) == false {
            throw BolusError.pumpRejected("mock: could not record bolus id — not initiated")
        }
        if forceIndeterminateNextDelivery {
            forceIndeterminateNextDelivery = false
            throw BolusError.indeterminate("mock: initiate response lost after write")
        }
        snapshot.connection = .bolusing; onChange?()
        if let hook = onDeliverInFlight { await hook() } else { try? await Task.sleep(nanoseconds: 1_200_000_000) }
        snapshot.connection = .connected
        // (§3.2 R3 / Q5.4) INTENTIONAL simulator state, NOT the C4 invented-IOB defect: a MockBackend has
        // no pump to read, so its IOB is necessarily synthesized. The C4 violation was the REAL backend
        // fabricating IOB instead of reading the pump — removed in TandemBackend. Kept so a demo's IOB
        // responds to a demo bolus (use `setLiveIob` to override). See also the sibling site below.
        snapshot.iobUnits += totalUnits
        snapshot.lastBolusUnits = totalUnits
        snapshot.lastBolusDate = Date()
        bolusMarkers.append(BolusMarker(date: Date(), units: totalUnits))
        onChange?()
        return totalUnits
    }

    public func deliverBolus(units: Double, carbsGrams: Double?, bgMgdl: Int?, iobUnits: Double?) async throws -> Double {
        guard snapshot.connection == .connected else { throw BolusError.notConnected }
        guard units <= snapshot.maxBolusUnits else { throw BolusError.exceedsMax(snapshot.maxBolusUnits) }
        lastDeliver = (units, carbsGrams, bgMgdl, iobUnits)   // FB-04 spy: exactly what the caller passed
        // Simulate the pump granting permission + assigning a bolus id BEFORE the initiate write (P0), so
        // an indeterminate outcome still leaves a reconcilable id in the durable ledger.
        let bolusId = nextBolusId; nextBolusId += 1; lastAssignedBolusId = bolusId
        // Round-3 §5: the host must durably record the id; abort pre-initiate if it can't.
        if let commit = commitBolusId, await commit(bolusId) == false {
            throw BolusError.pumpRejected("mock: could not record bolus id — not initiated")
        }
        if forceIndeterminateNextDelivery {
            forceIndeterminateNextDelivery = false
            throw BolusError.indeterminate("mock: initiate response lost after write")
        }
        snapshot.connection = .bolusing; onChange?()
        if let hook = onDeliverInFlight { await hook() } else { try? await Task.sleep(nanoseconds: 1_200_000_000) }
        snapshot.connection = .connected
        snapshot.iobUnits += units   // (§3.2 R3 / Q5.4) intentional simulator IOB — see the carb-path note above (C4 N/A to a mock)
        snapshot.lastBolusUnits = units
        snapshot.lastBolusDate = Date()
        onChange?()
        return units
    }

    public func cancelBolus() async {
        snapshot.connection = .connected; onChange?()
    }

    // MARK: - Advanced control + Mobi workflows (fakes for Simulator testing)
    public func suspendDelivery() async throws { snapshot.deliverySuspended = true; onChange?() }
    public func resumeDelivery() async throws { snapshot.deliverySuspended = false; onChange?() }
    public func setTempBasal(percent: Int, durationMinutes: Int) async throws { onChange?() }
    public func stopTempBasal() async throws { onChange?() }
    public func setMode(_ command: ModeCommand) async throws {
        // Translate the typed command to the reported activity STATE the UI reads from controlIQMode
        // (the collision this typing exists to prevent: command .sleepOn=1 → state .sleep=1).
        switch command {
        case .sleepOn:    snapshot.controlIQMode = ControlIQActivity.sleep.rawValue
        case .exerciseOn: snapshot.controlIQMode = ControlIQActivity.exercise.rawValue
        case .sleepOff, .exerciseOff: snapshot.controlIQMode = ControlIQActivity.normal.rawValue
        }
        onChange?()
    }
    public func playFindMyPump() async throws {}

    public func startG6Session(transmitterId: String, sensorCode: Int) async throws { snapshot.cgmSessionActive = true; onChange?() }
    public func startG7Session(pairingCode: Int) async throws { snapshot.cgmSessionActive = true; onChange?() }
    public func setSensorType(_ typeId: Int) async throws {}
    public func stopCgmSession() async throws { snapshot.cgmSessionActive = false; onChange?() }
    public func refreshCgmSession() async {}

    public func enterChangeCartridgeMode() async throws {
        snapshot.deliverySuspended = true; snapshot.cartridgeLoadActive = true; snapshot.cartridgeLoadState = 0; onChange?()
    }
    public func exitChangeCartridgeMode() async throws { snapshot.cartridgeLoadState = 1; onChange?() }
    public func enterFillTubingMode() async throws { snapshot.cartridgeLoadState = 2; onChange?() }
    public func exitFillTubingMode() async throws { snapshot.cartridgeLoadState = 3; onChange?() }
    public func fillCannula(milliunits: Int) async throws {
        snapshot.cartridgeLoadActive = false; snapshot.cartridgeLoadState = 6; snapshot.deliverySuspended = false; onChange?()
    }
    public func refreshLoadStatus() async {}

    /// P14 S6: counts the therapy-defining control writes (max bolus/basal, Control-IQ) that reach the
    /// backend, so a test can prove they are ack-gated the same way `idpWriteCount` proves it for IDP CRUD.
    public private(set) var controlWriteCount = 0
    public func setMaxBolus(units: Double) async throws { controlWriteCount += 1; snapshot.maxBolusUnits = Interlocks.clampMaxBolusLimit(units); onChange?() }   // S9: clamp; S6: counted
    public func setMaxBasal(unitsPerHour: Double) async throws { controlWriteCount += 1 }
    public func syncTimeToNow() async throws {}

    public func setControlIQ(enabled: Bool, weightLbs: Int, totalDailyInsulinUnits: Int) async throws {
        controlWriteCount += 1
        snapshot.controlIQEnabled = enabled; snapshot.controlIQWeightLbs = weightLbs
        snapshot.controlIQTotalDailyInsulin = totalDailyInsulinUnits; onChange?()
    }
    public func refreshControlIQSettings() async {
        if snapshot.controlIQWeightLbs == 0 { snapshot.controlIQWeightLbs = 160; snapshot.controlIQTotalDailyInsulin = 45; onChange?() }
    }
    public func refreshProfiles() async {
        if snapshot.profiles.isEmpty {
            snapshot.profiles = [PumpProfileInfo(idpId: 1, name: "Default", active: true),
                                 PumpProfileInfo(idpId: 2, name: "Weekend", active: false)]
            onChange?()
        }
    }
    public func setActiveProfile(idpId: Int) async throws {
        idpWriteCount += 1
        snapshot.profiles = snapshot.profiles.map { PumpProfileInfo(idpId: $0.idpId, name: $0.name, active: $0.idpId == idpId) }; onChange?()
    }
    public func renameProfile(idpId: Int, name: String) async throws {
        idpWriteCount += 1
        snapshot.profiles = snapshot.profiles.map { $0.idpId == idpId ? PumpProfileInfo(idpId: $0.idpId, name: name, active: $0.active) : $0 }; onChange?()
    }
    public func deleteProfile(idpId: Int) async throws { idpWriteCount += 1; snapshot.profiles.removeAll { $0.idpId == idpId }; onChange?() }
    /// FB-06 test hook: counts IDP / CGM-alert writes that actually reached the backend, so a test can
    /// prove the central unverified-therapy gate fails **closed** (count stays 0 without an ack).
    public private(set) var idpWriteCount = 0
    public func createProfile(name: String, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double,
                              isf: Int, targetBg: Int, insulinDurationMinutes: Int) async throws {
        idpWriteCount += 1
        let newId = (snapshot.profiles.map { $0.idpId }.max() ?? 0) + 1
        snapshot.profiles.append(PumpProfileInfo(idpId: newId, name: name, active: false)); onChange?()
    }
    public func refreshProfileSegments(idpId: Int) async {
        if snapshot.viewedProfileSegments.isEmpty {
            snapshot.viewedProfileSegments = [PumpProfileSegment(idpId: idpId, segmentIndex: 0, startTimeMinutes: 0,
                                                                 basalRateUnitsPerHour: 0.8, carbRatioGramsPerUnit: 10, isf: 40, targetBg: 110)]
            onChange?()
        }
    }
    public func addProfileSegment(idpId: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
                                  carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async throws {
        idpWriteCount += 1
        let idx = (snapshot.viewedProfileSegments.map { $0.segmentIndex }.max() ?? -1) + 1
        snapshot.viewedProfileSegments.append(PumpProfileSegment(idpId: idpId, segmentIndex: idx, startTimeMinutes: startTimeMinutes,
                                                                 basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf, targetBg: targetBg))
        onChange?()
    }
    public func modifyProfileSegment(idpId: Int, segmentIndex: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
                                     carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async throws {
        idpWriteCount += 1
        snapshot.viewedProfileSegments = snapshot.viewedProfileSegments.map {
            $0.segmentIndex == segmentIndex ? PumpProfileSegment(idpId: idpId, segmentIndex: segmentIndex, startTimeMinutes: startTimeMinutes,
                                                                 basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf, targetBg: targetBg) : $0 }
        onChange?()
    }
    public func deleteProfileSegment(idpId: Int, segmentIndex: Int) async throws {
        idpWriteCount += 1
        snapshot.viewedProfileSegments.removeAll { $0.segmentIndex == segmentIndex }; onChange?()
    }
    public func setLowInsulinAlert(thresholdUnits: Int) async throws {}
    public func setAutoOffAlert(enabled: Bool, durationMinutes: Int) async throws {}
    public func setSiteChangeReminder(enabled: Bool, days: Int, timeOfDayMinutes: Int) async throws {}
    public func setAlertSnooze(enabled: Bool, durationMinutes: Int) async throws {}
    public func setCgmHighLowAlert(alertType: Int, thresholdMgdl: Int, repeatMinutes: Int, enabled: Bool) async throws { idpWriteCount += 1 }
    public func setCgmOutOfRangeAlert(enabled: Bool, delayMinutes: Int) async throws {}
    public func setCgmRiseFallAlert(alertType: Int, enabled: Bool, mgdlPerMin: Int) async throws {}
}
