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
    public var onBolusIdAssigned: (@MainActor (Int) -> Void)?
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
        var value = 120.0
        var readings: [GlucoseReading] = []
        // 3 hours of 5-minute CGM samples, gently oscillating.
        for i in stride(from: 36, through: 0, by: -1) {
            let t = now.addingTimeInterval(TimeInterval(-i * 300))
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
        snapshot.iobUnits = 1.4
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
        glucoseHistory.append(GlucoseReading(date: Date(), mgdl: last))
        if glucoseHistory.count > 72 { glucoseHistory.removeFirst() }
        snapshot.glucose = last
        snapshot.iobUnits = max(0, snapshot.iobUnits - 0.02)
        onChange?()
    }

    /// Mock calculator: the same oracle-backed `BolusMath` as the real backend, with a fixed mock
    /// profile (carb ratio 10 g/U, ISF 40, target 110). Keeps the simulator in lockstep with the
    /// production dosing semantics (audit C-01).
    /// Test knob (FB-01): when true, `recommendBolus` reports the dose as computed from ASSUMED
    /// (unverified) settings, so callers must fail closed / require the assumptions ack.
    public var forceUnverifiedInputs = false
    /// Test knob (FB-02): when true, the NEXT `deliverBolus`/`deliverExtendedBolus` throws
    /// `.indeterminate` (as if the initiate response was lost after the write). One-shot.
    public var forceIndeterminateNextDelivery = false

    /// Test knob (GA-05): seed a FRESH glucose reading (default staleness leaves `glucoseDate` nil →
    /// always stale). Lets a test exercise the non-stale correction path.
    public func seedFreshGlucose(_ mgdl: Int, at date: Date = Date()) {
        snapshot.glucose = mgdl; snapshot.glucoseDate = date; onChange?()
    }

    public func recommendBolus(carbsGrams: Double, bgMgdl: Int?) async -> BolusRecommendation {
        var rec = BolusRecommendation()
        rec.carbsGrams = carbsGrams
        rec.bgMgdl = bgMgdl
        rec.iobUnits = snapshot.iobUnits
        let profile = BolusMath.Profile(carbRatioGramsPerUnit: 10, isfMgdlPerUnit: 40,
                                        targetBgMgdl: 110, iobUnits: snapshot.iobUnits)
        rec.recommendedUnits = BolusMath.recommendedUnits(carbsGrams: carbsGrams > 0 ? carbsGrams : nil,
                                                          bgMgdl: bgMgdl, profile: profile)
        rec.recommendedUnits = (rec.recommendedUnits * 20).rounded() / 20   // round to 0.05u
        if forceUnverifiedInputs { rec.inputsVerified = false; rec.assumedProfile = profile }
        return rec
    }

    public func deliverExtendedBolus(totalUnits: Double, nowUnits: Double, durationMinutes: Int,
                                     carbsGrams: Double?, bgMgdl: Int?, iobUnits: Double?) async throws -> Double {
        guard snapshot.connection == .connected else { throw BolusError.notConnected }
        guard totalUnits <= snapshot.maxBolusUnits else { throw BolusError.exceedsMax(snapshot.maxBolusUnits) }
        // Simulate the pump granting permission + assigning a bolus id BEFORE the initiate write (P0).
        let bolusId = nextBolusId; nextBolusId += 1; lastAssignedBolusId = bolusId
        onBolusIdAssigned?(bolusId)
        if forceIndeterminateNextDelivery {
            forceIndeterminateNextDelivery = false
            throw BolusError.indeterminate("mock: initiate response lost after write")
        }
        snapshot.connection = .bolusing; onChange?()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        snapshot.connection = .connected
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
        // Simulate the pump granting permission + assigning a bolus id BEFORE the initiate write (P0), so
        // an indeterminate outcome still leaves a reconcilable id in the durable ledger.
        let bolusId = nextBolusId; nextBolusId += 1; lastAssignedBolusId = bolusId
        onBolusIdAssigned?(bolusId)
        if forceIndeterminateNextDelivery {
            forceIndeterminateNextDelivery = false
            throw BolusError.indeterminate("mock: initiate response lost after write")
        }
        snapshot.connection = .bolusing; onChange?()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        snapshot.connection = .connected
        snapshot.iobUnits += units
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
    public func setMode(bitmap: Int) async throws {
        // Translate the command bitmap (1=sleepOn,2=sleepOff,3=exOn,4=exOff) to the reported
        // state (0=normal,1=sleep,2=exercise) the UI reads from controlIQMode.
        switch bitmap {
        case 1: snapshot.controlIQMode = 1
        case 3: snapshot.controlIQMode = 2
        default: snapshot.controlIQMode = 0   // sleepOff / exerciseOff → normal
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

    public func setMaxBolus(units: Double) async throws { snapshot.maxBolusUnits = units; onChange?() }
    public func setMaxBasal(unitsPerHour: Double) async throws {}
    public func syncTimeToNow() async throws {}

    public func setControlIQ(enabled: Bool, weightLbs: Int, totalDailyInsulinUnits: Int) async throws {
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
