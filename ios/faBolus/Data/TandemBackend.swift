import Foundation
import faBolusCore
import CoreBluetooth
import PumpX2Messages
import PumpX2Auth
import PumpX2BLE

/// Real pump data source over `PumpX2Kit`'s Core Bluetooth transport: scan → connect → JPAKE
/// pair → poll status; and a signed bolus flow (permission → initiate → status) matching the
/// signed delivery path. Read-only by default; `deliverBolus` briefly
/// raises the write policy to `.allowDelivery` for the signed sequence only.
///
/// Runs on a physical device only (the Simulator has no Bluetooth).
@MainActor
public final class TandemBackend: NSObject, PumpBackend {
    /// Tandem (via PumpX2Kit) supports the full bolus/status feature set. Advanced control
    /// (suspend/resume, temp basal, modes, profiles, CIQ settings, limits, cartridge/fill, time
    /// sync) is Mobi-only on real hardware, so it's advertised only once we detect a Mobi via
    /// ApiVersionResponse. The UI still additionally gates on `AppSettings.advancedControlEnabled`.
    public var capabilities: PumpCapabilities {
        var caps = snapshot.isMobi ? PumpCapabilities.mobiAdvanced : PumpCapabilities.full
        // t:slim X2 firmware silently rejects *remote* notification dismissal (Tandem's own app
        // disables it there); only Mobi honors it. On t:slim, "Clear" only snoozes locally in faBolus.
        caps.supportsRemoteAlertDismiss = snapshot.isMobi
        return caps
    }
    public private(set) var snapshot = PumpSnapshot()
    public private(set) var glucoseHistory: [GlucoseReading] = []
    public private(set) var iobHistory: [IOBSample] = []
    public private(set) var bolusMarkers: [BolusMarker] = []
    public private(set) var activeNotifications: [PumpAlert] = []
    public var onChange: (@MainActor () -> Void)?

    /// Map a PumpX2 notification onto the backend-neutral `PumpAlert`.
    private static func toAlert(_ n: PumpNotification) -> PumpAlert {
        PumpAlert(id: n.id, kind: PumpAlertKind(rawValue: n.kind.rawValue) ?? .alert,
                  title: n.title, detail: n.detail ?? "", isDismissable: n.dismissable)
    }

    // Active notifications by kind (merged into `activeNotifications`, most serious first).
    private var alarmList: [PumpNotification] = []
    private var malfunctionList: [PumpNotification] = []
    private var alertList: [PumpNotification] = []
    private var cgmAlertList: [PumpNotification] = []
    private var reminderList: [PumpNotification] = []
    // Locally-acknowledged (snoozed) alerts: key -> the time the user tapped Clear. Some pump
    // alerts are *condition-based* (e.g. a CGM "high glucose" while glucose is genuinely still
    // high): the signed dismiss is accepted, but the pump re-raises it on the next poll. To match
    // what a CGM app does, a cleared alert is hidden until the pump condition actually clears
    // (the alert drops off the pump's bitmap) or the snooze window elapses, at which point it
    // re-nags. Truly-dismissable alerts just clear on the pump and never come back.
    private var acknowledged: [String: Date] = [:]
    private static let snoozeWindow: TimeInterval = 30 * 60   // re-nag after 30 min, like a CGM re-alert
    private func noteKey(_ n: PumpNotification) -> String { "\(n.kind.rawValue):\(n.id)" }
    private func mergeNotifications() {
        let raw = malfunctionList + alarmList + alertList + cgmAlertList + reminderList
        let present = Set(raw.map(noteKey))
        let now = Date()
        // Expire acks whose alert is gone from the pump (condition resolved) or whose snooze has
        // elapsed, so a genuinely new occurrence shows (and re-notifies) again.
        acknowledged = acknowledged.filter { present.contains($0.key) && now.timeIntervalSince($0.value) < Self.snoozeWindow }
        activeNotifications = raw.filter { !acknowledged.keys.contains(noteKey($0)) }.map(Self.toAlert)
    }
    // Diagnostic: raw bitmaps + how many alert responses we've received (surfaced on the HUD to
    // confirm the pump is actually answering the alert polls).
    public private(set) var alertDebug: String = "alerts: not polled yet"
    private var alertBits: [String: UInt64] = [:]
    private var alertRespCount = 0
    // Last DismissNotificationResponse status, kept separate so a poll doesn't clobber it before it
    // can be read: 0 = pump accepted the dismiss (a still-showing alert is then condition-based and
    // re-raising), non-zero = pump rejected it (e.g. a signing problem for opcode 184).
    private var lastDismissAck = ""
    private func renderDebug() {
        let hex: (String) -> String = { String(format: "%llX", self.alertBits[$0] ?? 0) }
        var s = "polls \(alertRespCount) · Al=\(hex("al")) Am=\(hex("am")) C=\(hex("c")) R=\(hex("r")) M=\(hex("m"))"
        if !lastDismissAck.isEmpty { s += " · \(lastDismissAck)" }
        alertDebug = s
    }
    private func noteAlert(_ key: String, _ bmp: UInt64) {
        alertBits[key] = bmp; alertRespCount += 1
        renderDebug()
    }

    // Restore identifier enables CoreBluetooth state restoration: iOS relaunches the app on pump
    // BLE events (with `bluetooth-central` background mode) and hands the connection back.
    private let client = PumpBLEClient(restoreIdentifier: "com.fabolus.app.pump")
    private var coordinator: PairingCoordinator?
    private var pollTimer: Timer?

    /// 6-digit JPAKE pairing code (from the pump screen). Set before `connect()`.
    public var pairingCode: String = ""
    private var authenticationKey: [UInt8] = []
    private var signingTimestamp: UInt32 = 0
    private var currentBolusId: Int = 0
    private var isPaired: Bool { !authenticationKey.isEmpty }

    /// Latest bolus-calculator settings (carb ratio / ISF / target) for recommendBolus.
    private var calcSnapshot: BolusCalcDataSnapshotResponse?

    private static let food2 = 8   // manual units-only bolus type
    /// Anchor mapping the pump's clock to the phone's, so pump timestamps convert correctly
    /// regardless of the pump's timezone/epoch. Refreshed from TimeSinceReset.
    private var pumpTimeAnchor: (pump: UInt32, phone: Date)?

    // CGM history backfill: pages backward through the pump's history log (in 255-record pages)
    // until it has enough CGM readings to fill the chart, then merges them. Paging is driven by
    // a debounce timer (each page's stream ends when frames stop) rather than an exact record
    // count, because sequence numbers can be non-contiguous. Re-runs on each connect.
    private var didBackfill = false
    /// Model detected from the BLE advertised name at discovery (Mobi advertises "…Mobi…"). This is
    /// the reliable, direct model signal — the API version does NOT cleanly separate the two (newer
    /// t:slim X2 firmware reports API >= 3.5). nil = name didn't identify it → fall back to API version.
    private var detectedIsMobi: Bool?
    private var backfillActive = false
    private var backfillBuffer: [(pumpSec: UInt32, mgdl: Int)] = []
    // Completed boluses recovered from the same history pages (for the chart's bolus bars + to seed
    // the IOB series so both show pump history, not just data since the app connected).
    private var backfillBoluses: [(pumpSec: UInt32, units: Double, iob: Double)] = []
    // Decoded typed history-log events for the Logbook (B2). Buffered across pages, mapped to
    // neutral HistoryEvents in finishBackfill (where the pump→phone date conversion lives).
    private var backfillEventLogs: [any HistoryLogEvent] = []
    public private(set) var historyEvents: [HistoryEvent] = []
    private var backfillNextEnd: UInt32 = 0     // upper sequence number for the next page
    private var backfillFirstSeq: UInt32 = 0    // oldest available sequence number
    private var backfillPages = 0
    private var backfillTimer: Timer?
    private static let backfillPageSize = 255   // numberOfLogs is one byte
    private static let backfillMaxPages = 20    // safety cap (~5100 records) — cover a full day
    private static let backfillTargetReadings = 288  // ~24 h @ 5-min

    // Bolus-in-progress tracking so the UI keeps a live cancel window + reports partial delivery.
    private var cancelRequested = false
    public private(set) var lastBolusCancelled = false

    // Continuations bridging the delegate callbacks to async/await for the signed flow.
    private var timeCont: CheckedContinuation<TimeSinceResetResponse, Error>?
    private var permissionCont: CheckedContinuation<BolusPermissionResponse, Error>?
    private var initiateCont: CheckedContinuation<InitiateBolusResponse, Error>?
    private var bolusStatusCont: CheckedContinuation<CurrentBolusStatusResponse, Error>?
    private var lastBolusCont: CheckedContinuation<LastBolusStatusV2Response, Error>?
    private var cgmHwCont: CheckedContinuation<CGMHardwareInfoResponse?, Never>?

    /// One-shot reads used by the bolus-progress loop (routine polling is paused meanwhile).
    private func currentBolusStatus() async throws -> CurrentBolusStatusResponse {
        try await withCheckedThrowingContinuation { cont in
            bolusStatusCont = cont
            do { try client.send(CurrentBolusStatusRequest()) } catch { bolusStatusCont = nil; cont.resume(throwing: error) }
        }
    }
    private func lastBolusStatus() async throws -> LastBolusStatusV2Response {
        try await withCheckedThrowingContinuation { cont in
            lastBolusCont = cont
            do { try client.send(LastBolusStatusV2Request()) } catch { lastBolusCont = nil; cont.resume(throwing: error) }
        }
    }

    public var writePolicy: PumpBLEClient.WritePolicy {
        get { client.writePolicy } set { client.writePolicy = newValue }
    }

    public override init() {
        super.init()
        client.writePolicy = .readOnly
        client.delegate = self
    }

    // MARK: - PumpDataSource

    public func connect() async {
        snapshot.connection = .scanning; onChange?()
        client.startScan()
    }

    public func disconnect() {
        pollTimer?.invalidate(); pollTimer = nil
        client.disconnect()
    }

    public func recommendBolus(carbsGrams: Double, bgMgdl: Int?) async -> BolusRecommendation {
        var rec = BolusRecommendation()
        rec.carbsGrams = carbsGrams; rec.bgMgdl = bgMgdl; rec.iobUnits = snapshot.iobUnits
        if let s = calcSnapshot, s.carbRatio > 0 {
            let food = carbsGrams / s.carbRatioGramsPerUnit
            let correction = (bgMgdl != nil && s.isf > 0)
                ? max(0, Double(bgMgdl! - s.targetBg) / Double(s.isf) - snapshot.iobUnits) : 0
            rec.recommendedUnits = max(0, food + correction)
        } else {
            rec.recommendedUnits = max(0, carbsGrams / 10.0 - snapshot.iobUnits)
        }
        rec.recommendedUnits = (rec.recommendedUnits * 20).rounded() / 20   // 0.05 u steps
        return rec
    }

    /// Delivers a units-only (FOOD2) bolus via the validated signed path. Raises the write
    /// policy to `.allowDelivery` only for this call.
    public func deliverBolus(units: Double) async throws -> Double {
        guard snapshot.connection == .connected || snapshot.connection == .bolusing else { throw BolusError.notConnected }
        guard isPaired else { throw BolusError.pumpRejected("not paired") }
        guard units <= snapshot.maxBolusUnits, units <= Interlocks.absoluteMaxUnits else {
            throw BolusError.exceedsMax(min(snapshot.maxBolusUnits, Interlocks.absoluteMaxUnits))
        }
        let mu = UInt32((units * 1000).rounded())
        guard mu >= 50 else { throw BolusError.pumpRejected("below 0.05 u") }

        // Fresh signing timestamp (the pump validates the HMAC against its clock).
        let time: TimeSinceResetResponse = try await withCheckedThrowingContinuation { cont in
            timeCont = cont
            do { try client.send(TimeSinceResetRequest()) } catch { timeCont = nil; cont.resume(throwing: error) }
        }
        signingTimestamp = time.currentTime

        let previousPolicy = client.writePolicy
        client.writePolicy = .allowDelivery
        defer { client.writePolicy = previousPolicy }
        snapshot.connection = .bolusing; onChange?()

        let perm: BolusPermissionResponse = try await withCheckedThrowingContinuation { cont in
            permissionCont = cont
            do {
                try client.send(BolusPermissionRequest(), authenticationKey: authenticationKey,
                                pumpTimeSinceReset: signingTimestamp)
            } catch { permissionCont = nil; cont.resume(throwing: error) }
        }
        guard perm.granted else {
            snapshot.connection = .connected; onChange?()
            throw BolusError.pumpRejected("permission not granted (nack \(perm.nackReasonId))")
        }
        currentBolusId = perm.bolusId

        let ini: InitiateBolusResponse = try await withCheckedThrowingContinuation { cont in
            initiateCont = cont
            do {
                try client.send(
                    InitiateBolusRequest(totalVolume: mu, bolusID: perm.bolusId, bolusTypeBitmask: Self.food2),
                    authenticationKey: authenticationKey, pumpTimeSinceReset: signingTimestamp,
                    allowInsulinDelivery: true)
            } catch { initiateCont = nil; cont.resume(throwing: error) }
        }
        guard ini.accepted else {
            snapshot.connection = .connected; onChange?()
            throw BolusError.pumpRejected("initiate not accepted (status \(ini.status))")
        }

        // Delivery has started on the pump. Keep the UI in `.bolusing` and poll the pump until
        // the bolus finishes or is cancelled — this gives the user a real cancel window and lets
        // us report the ACTUAL delivered amount (important for partial delivery after a cancel).
        cancelRequested = false
        lastBolusCancelled = false
        snapshot.lastBolusDate = Date()
        onChange?()
        pollTimer?.invalidate()   // pause routine polling so its LastBolus reads don't interfere

        let deadline = Date().addingTimeInterval(min(600.0, max(60.0, units * 90.0)))   // upper bound
        while Date() < deadline && !cancelRequested {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if cancelRequested { break }
            if let st = try? await currentBolusStatus(), st.bolusId != currentBolusId || !st.isActive {
                break   // pump reports the bolus is no longer active
            }
        }

        // Read the actual delivered amount for this bolus.
        var delivered = units
        if let last = try? await lastBolusStatus(), last.bolusId == currentBolusId {
            delivered = last.deliveredUnits
        } else if cancelRequested {
            delivered = 0   // couldn't confirm; assume unknown-partial reported by caller
        }

        lastBolusCancelled = cancelRequested
        cancelRequested = false
        currentBolusId = 0
        snapshot.connection = .connected
        snapshot.lastBolusUnits = delivered
        snapshot.iobUnits += delivered
        if delivered > 0 {
            bolusMarkers.append(BolusMarker(date: Date(), units: delivered))
            if bolusMarkers.count > 60 { bolusMarkers.removeFirst() }
        }
        onChange?()
        startPolling()            // resume routine polling
        return delivered
    }

    /// Request a bolus cancel. The in-flight `deliverBolus` loop detects this, stops, and reports
    /// the partial delivered amount. Safe to call from the phone HUD or a remote.
    public func cancelBolus() async {
        guard currentBolusId != 0 else { return }
        cancelRequested = true
        let previous = client.writePolicy
        client.writePolicy = .allowDelivery
        _ = try? client.send(CancelBolusRequest(bolusId: currentBolusId),
                             authenticationKey: authenticationKey, pumpTimeSinceReset: signingTimestamp)
        client.writePolicy = previous
    }

    /// Clear a pump notification with a signed DismissNotificationRequest. It's a signed CONTROL
    /// message but does NOT modify insulin delivery, so it runs under `.allowNonDelivery`.
    public func dismissNotification(_ alert: PumpAlert) async {
        guard isPaired else { return }
        let kind = NotificationKind(rawValue: alert.kind.rawValue) ?? .alert
        let ackKey = "\(alert.kind.rawValue):\(alert.id)"
        // On pumps that don't honor remote dismissal (t:slim X2), skip the futile signed send and just
        // snooze locally in faBolus so it stops nagging here. The pump keeps its own alert until the
        // condition clears or it's dismissed on the pump itself.
        guard capabilities.supportsRemoteAlertDismiss else {
            acknowledged[ackKey] = Date()
            lastDismissAck = "local snooze (this pump model can't be dismissed remotely)"
            alertDebug = "local-snoozed id \(alert.id) kind \(alert.kind.rawValue) — t:slim X2 rejects remote dismiss"
            mergeNotifications()
            onChange?()
            return
        }
        // Fresh signing timestamp for the HMAC.
        guard let time = try? await withCheckedThrowingContinuation({ (cont: CheckedContinuation<TimeSinceResetResponse, Error>) in
            timeCont = cont
            do { try client.send(TimeSinceResetRequest()) } catch { timeCont = nil; cont.resume(throwing: error) }
        }) else { return }
        signingTimestamp = time.currentTime

        let previous = client.writePolicy
        client.writePolicy = .allowNonDelivery
        defer { client.writePolicy = previous }
        lastDismissAck = ""   // cleared; the pump's DismissNotificationResponse (185) sets it below
        alertDebug = "cleared id \(alert.id) kind \(alert.kind.rawValue) — snoozed if condition persists"
        // Surface a send failure directly (the request otherwise fails silently) so a non-arriving
        // ack can be told apart from a request that never went out.
        do {
            _ = try client.send(DismissNotificationRequest(kind: kind, notificationId: alert.id),
                                authenticationKey: authenticationKey, pumpTimeSinceReset: signingTimestamp)
        } catch {
            lastDismissAck = "send failed: \(error)"
        }
        // Record a local acknowledge, then re-poll. The signed dismiss clears any truly-dismissable
        // alert on the pump; for a condition-based alert (e.g. CGM high while BG is genuinely high)
        // the pump re-raises it, but the ack keeps it hidden (and un-notified) until the condition
        // clears on the pump or the snooze elapses.
        acknowledged[ackKey] = Date()
        mergeNotifications()
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.alertRead() }
        // If the pump never answers the dismiss, say so — distinguishes "rejected/no response" from
        // "accepted but condition persists" on the next test.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, self.lastDismissAck.isEmpty else { return }
            self.lastDismissAck = "no ack (no pump response)"
            self.renderDebug(); self.onChange?()
        }
    }

    // MARK: - Advanced control (B3)
    // Each command is signed with a fresh pump-clock timestamp and sent under a raised WritePolicy
    // that is restored via `defer`. Insulin-affecting commands use `.allowDelivery` +
    // `allowInsulinDelivery: true`; non-insulin ones use `.allowNonDelivery`. The pump's response
    // (parsed in didReceiveFrame) updates the snapshot. The UI only reaches these behind the
    // advanced-control + Mobi gate; the WritePolicy + pump-side checks are the enforcement backstop.

    private func refreshSigningTimestamp() async throws {
        let time: TimeSinceResetResponse = try await withCheckedThrowingContinuation { cont in
            timeCont = cont
            do { try client.send(TimeSinceResetRequest()) } catch { timeCont = nil; cont.resume(throwing: error) }
        }
        signingTimestamp = time.currentTime
    }

    /// Fresh-timestamp, policy-raised signed send for a control command. `delivery` selects the
    /// WritePolicy + the insulin-delivery signing flag. Fire-and-send: the response updates state.
    private func sendControl(_ message: Message, delivery: Bool) async throws {
        guard snapshot.connection == .connected || snapshot.connection == .bolusing else {
            throw BolusError.notConnected
        }
        try await refreshSigningTimestamp()
        let previous = client.writePolicy
        client.writePolicy = delivery ? .allowDelivery : .allowNonDelivery
        defer { client.writePolicy = previous }
        _ = try client.send(message, authenticationKey: authenticationKey,
                            pumpTimeSinceReset: signingTimestamp, allowInsulinDelivery: delivery)
        // Let the signed ack arrive (didReceiveFrame updates the snapshot) before restoring policy.
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    public func suspendDelivery() async throws { try await sendControl(SuspendPumpingRequest(), delivery: true) }
    public func resumeDelivery() async throws { try await sendControl(ResumePumpingRequest(), delivery: true) }
    public func setTempBasal(percent: Int, durationMinutes: Int) async throws {
        try await sendControl(SetTempRateRequest(minutes: durationMinutes, percent: percent), delivery: true)
    }
    public func stopTempBasal() async throws { try await sendControl(StopTempRateRequest(), delivery: true) }
    public func setMode(bitmap: Int) async throws { try await sendControl(SetModesRequest(bitmap: bitmap), delivery: true) }
    public func playFindMyPump() async throws { try await sendControl(PlaySoundRequest(), delivery: false) }

    // MARK: - Mobi workflows (A4)

    // CGM session — all non-insulin (`.allowNonDelivery`).
    public func startG6Session(transmitterId: String, sensorCode: Int) async throws {
        let tx = transmitterId.trimmingCharacters(in: .whitespaces).uppercased()
        if !tx.isEmpty {
            try await sendControl(SetG6TransmitterIdRequest(txId: tx), delivery: false)
            try? await Task.sleep(nanoseconds: 750_000_000)   // let the pump store the id (per controlX2)
        }
        try await sendControl(StartDexcomG6SensorSessionRequest(sensorCode: sensorCode), delivery: false)
        await refreshCgmSession()
    }
    public func startG7Session(pairingCode: Int) async throws {
        try await sendControl(SetDexcomG7PairingCodeRequest(pairingCode: pairingCode), delivery: false)
        await refreshCgmSession()
    }
    public func setSensorType(_ typeId: Int) async throws {
        try await sendControl(SetSensorTypeRequest(cgmSensorType: typeId), delivery: false)
    }
    public func stopCgmSession() async throws {
        try await sendControl(StopDexcomCGMSensorSessionRequest(), delivery: false)
        await refreshCgmSession()
    }
    public func refreshCgmSession() async {
        guard snapshot.connection == .connected else { return }
        try? client.send(CGMStatusRequest())          // reply handled in didReceiveFrame
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    // Cartridge / fill — enter-mode + fill-cannula are insulin-affecting (`.allowDelivery`); the
    // exits are not. The UI runs these behind the advanced-control + Mobi gate with confirmation.
    public func enterChangeCartridgeMode() async throws { try await sendControl(EnterChangeCartridgeModeRequest(), delivery: true) }
    public func exitChangeCartridgeMode() async throws { try await sendControl(ExitChangeCartridgeModeRequest(), delivery: false) }
    public func enterFillTubingMode() async throws { try await sendControl(EnterFillTubingModeRequest(), delivery: true) }
    public func exitFillTubingMode() async throws { try await sendControl(ExitFillTubingModeRequest(), delivery: false) }
    public func fillCannula(milliunits: Int) async throws {
        let clamped = max(0, min(milliunits, FillLimits.maxCannulaMilliunits))   // defense-in-depth bound
        try await sendControl(FillCannulaRequest(primeSize: clamped), delivery: true)
    }
    public func refreshLoadStatus() async {
        guard snapshot.connection == .connected else { return }
        try? client.send(LoadStatusRequest())          // reply handled in didReceiveFrame
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    // Settings — non-insulin config.
    public func setMaxBolus(units: Double) async throws {
        let clamped = max(0.05, min(units, Interlocks.absoluteMaxUnits))
        try await sendControl(SetMaxBolusLimitRequest(maxBolusMilliunits: Int((clamped * 1000).rounded())), delivery: false)
    }
    public func setMaxBasal(unitsPerHour: Double) async throws {
        let clamped = max(0, unitsPerHour)
        try await sendControl(SetMaxBasalLimitRequest(maxHourlyBasalMilliunits: UInt32((clamped * 1000).rounded())), delivery: false)
    }
    public func syncTimeToNow() async throws {
        let tandemEpoch = UInt32(max(0, Date().timeIntervalSince1970 - 1_199_145_600))   // Jan 1 2008 base
        try await sendControl(ChangeTimeDateRequest(tandemEpochTime: tandemEpoch), delivery: false)
    }

    /// Read the paired G6 CGM transmitter ID from the pump (CGMHardwareInfoResponse.hardwareInfoString),
    /// so the CGM-failover setup can auto-fill it instead of the user looking it up. Requires a live
    /// connection; returns nil on timeout / not connected / empty.
    public func readG6TransmitterId() async -> String? {
        guard snapshot.connection == .connected || snapshot.connection == .bolusing else { return nil }
        let resp: CGMHardwareInfoResponse? = await withCheckedContinuation { cont in
            cgmHwCont = cont
            // 6 s timeout so the button never hangs if the pump doesn't answer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, let c = self.cgmHwCont else { return }
                self.cgmHwCont = nil; c.resume(returning: nil)
            }
            do { try client.send(CGMHardwareInfoRequest()) }
            catch { if let c = cgmHwCont { cgmHwCont = nil; c.resume(returning: nil) } }
        }
        let id = resp?.hardwareInfoString.trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty ?? true) ? nil : id
    }

    // MARK: - Helpers (tiered polling to spare phone + pump battery)

    private var pollTick = 0

    /// Fast-changing state (~60 s): IOB, glucose, reservoir, last bolus, battery.
    private func fastRead() {
        for r: Message in [ControlIQIOBRequest(), CurrentEgvGuiDataV2Request(),
                           InsulinStatusRequest(), LastBolusStatusV2Request(), CurrentBatteryV2Request()] {
            try? client.send(r)
        }
    }

    /// Alerts/alarms/reminders/malfunctions — sent as a separate burst (spaced from fastRead) so
    /// the pump isn't asked for 10 things at once, which was dropping the later requests.
    private func alertRead() {
        for r: Message in [AlertStatusRequest(), AlarmStatusRequest(), CGMAlertStatusRequest(),
                           ReminderStatusRequest(), MalfunctionStatusRequest()] {
            try? client.send(r)
        }
    }

    /// Slow/static settings (once per connect + every ~10 min): basal, calculator snapshot
    /// (carb ratio/ISF/target/max), and the pump-clock anchor.
    private func staticRead() {
        for r: Message in [CurrentBasalStatusRequest(), BolusCalcDataSnapshotRequest(), TimeSinceResetRequest(),
                           ApiVersionRequest(), ControlIQInfoV2Request()] {
            try? client.send(r)
        }
    }

    private func startPolling() {
        fastRead(); staticRead()
        scheduleAlertRead()
        pollTick = 0
        pollTimer?.invalidate()
        // Tick every 15 s: alerts every tick (~15 s, so a new alert appears quickly on phone +
        // watch), the fuller fast-read every 4th tick (~60 s), settings every ~10 min. Alert
        // reads are cheap empty-cargo requests, so the tighter cadence barely affects battery.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.pollTick += 1
                self.scheduleAlertRead()                            // ~15 s
                if self.pollTick % 4 == 0 { self.fastRead() }       // ~60 s
                if self.pollTick % 40 == 0 { self.staticRead() }    // ~10 min
            }
        }
    }

    /// Send the alert reads ~1.5 s after the fast reads so they aren't in the same request burst.
    private func scheduleAlertRead() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.alertRead() }
    }

    /// Request one page of history (255 records) ending at `backfillNextEnd`, walking backward.
    private func requestBackfillPage() {
        guard backfillNextEnd >= backfillFirstSeq, backfillPages < Self.backfillMaxPages else {
            finishBackfill(); return
        }
        let available = backfillNextEnd - backfillFirstSeq + 1
        let count = min(UInt32(Self.backfillPageSize), available)
        guard count > 0 else { finishBackfill(); return }
        let startLog = backfillNextEnd - (count - 1)
        backfillPages += 1
        try? client.send(HistoryLogRequest(startLog: startLog, numberOfLogs: Int(count)))
        backfillNextEnd = startLog > 0 ? startLog - 1 : 0   // next (older) page
        scheduleBackfillTick()
    }

    /// Debounce: a page's stream has ended once ~1.5 s pass with no new frames.
    private func scheduleBackfillTick() {
        backfillTimer?.invalidate()
        backfillTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
            MainActor.assumeIsolated { self.backfillPageDone() }
        }
    }

    private func backfillPageDone() {
        // Keep paging backward until we have enough CGM readings or run out of history.
        if backfillBuffer.count < Self.backfillTargetReadings && backfillNextEnd >= backfillFirstSeq {
            requestBackfillPage()
        } else {
            finishBackfill()
        }
    }

    /// Merge the buffered CGM history into the chart. Places each reading at its TRUE pump-clock
    /// time (`pumpTimeSec + Jan-1-2008 epoch`, the same conversion controlX2/tconnectsync use) so
    /// it aligns with the correct live `Date()`-stamped readings — no "anchor newest to now",
    /// which previously shifted older data forward onto the present.
    private func finishBackfill() {
        backfillTimer?.invalidate(); backfillTimer = nil
        backfillActive = false
        defer { backfillBuffer.removeAll(keepingCapacity: false); backfillBoluses.removeAll(keepingCapacity: false) }
        let now = Date()
        // The pump logs time as local wall-clock. Adding the 2008 epoch treats it as UTC, which
        // lands records a timezone away (they showed ~7-8 h in the past in PDT); subtract the
        // local UTC offset to place them at the correct real instant, aligned with live data.
        let tzOffset = Double(TimeZone.current.secondsFromGMT())
        let pumpDate: (UInt32) -> Date = { sec in
            min(Date(timeIntervalSince1970: HistoryLog.jan12008UnixEpoch + Double(sec) - tzOffset), now)
        }

        // --- CGM readings ---
        if !backfillBuffer.isEmpty {
            var merged = glucoseHistory
            for b in backfillBuffer { merged.append(GlucoseReading(date: pumpDate(b.pumpSec), mgdl: b.mgdl)) }
            merged.sort { $0.date < $1.date }
            // Drop near-duplicates: same value within ~150 s of the previously kept reading.
            var deduped: [GlucoseReading] = []
            for r in merged {
                if let last = deduped.last, last.mgdl == r.mgdl,
                   r.date.timeIntervalSince(last.date) < 150 { continue }
                deduped.append(r)
            }
            if deduped.count > 288 { deduped.removeFirst(deduped.count - 288) }
            glucoseHistory = deduped
            if let last = deduped.last { snapshot.glucose = last.mgdl; snapshot.glucoseDate = last.date }
        }

        // --- Boluses (bars) + IOB samples seeded from history ---
        if !backfillBoluses.isEmpty {
            var markers = bolusMarkers
            var iob = iobHistory
            let existingBolus = Set(bolusMarkers.map { $0.date.timeIntervalSince1970.rounded() })
            var existingIOB = Set(iobHistory.map { $0.date.timeIntervalSince1970.rounded() })
            for b in backfillBoluses {
                let date = pumpDate(b.pumpSec)
                let key = date.timeIntervalSince1970.rounded()
                if !existingBolus.contains(key) {
                    markers.append(BolusMarker(date: date, units: b.units))
                }
                if b.iob > 0, !existingIOB.contains(key) {
                    iob.append(IOBSample(date: date, iob: b.iob)); existingIOB.insert(key)
                }
            }
            markers.sort { $0.date < $1.date }
            if markers.count > 100 { markers.removeFirst(markers.count - 100) }
            bolusMarkers = markers
            iob.sort { $0.date < $1.date }
            if iob.count > 288 { iob.removeFirst(iob.count - 288) }
            iobHistory = iob
        }

        // --- Logbook events (B2): map decoded typed events → neutral, newest first ---
        if !backfillEventLogs.isEmpty {
            var events = historyEvents
            var seen = Set(historyEvents.map { $0.id })
            for e in backfillEventLogs {
                guard !seen.contains(e.sequenceNum), let ne = Self.neutralEvent(e, date: pumpDate(e.pumpTimeSec)) else { continue }
                seen.insert(e.sequenceNum); events.append(ne)
            }
            events.sort { $0.date > $1.date }          // newest first
            if events.count > 500 { events.removeLast(events.count - 500) }
            historyEvents = events
        }
        onChange?()
    }

    /// Maps a PumpX2Kit typed history-log event to a neutral `HistoryEvent` for the Logbook.
    /// Returns nil to skip high-frequency / non-user-facing records (e.g. raw CGM samples — those
    /// are shown on the chart, not the logbook). A curated set of the user-meaningful families.
    static func neutralEvent(_ e: any HistoryLogEvent, date: Date) -> HistoryEvent? {
        func u(_ f: Float) -> String { String(format: "%.2f U", f) }
        let seq = e.sequenceNum
        // Resolve a pump alert/alarm/CGM-alert id to its (title, detail) using the same name tables
        // the live-alert path uses (the history-log id shares that numbering). Falls back to a
        // generic label + the raw id so an unknown id is still distinguishable, never mislabeled.
        func alertName(_ id: Int) -> (String, String) {
            if let n = AlertStatusResponse.name(for: id) { return (n.title, n.detail ?? "") }
            return ("Alert", "id \(id)")
        }
        func alarmName(_ id: Int) -> (String, String) {
            if let n = AlarmStatusResponse.name(for: id) { return (n.title, n.detail ?? "") }
            return ("Alarm", "id \(id)")
        }
        func cgmAlertName(_ id: Int) -> (String, String) {
            if let n = CGMAlertStatusResponse.name(for: id) { return (n.title, n.detail ?? "") }
            return ("CGM alert", "id \(id)")
        }
        switch e {
        case let m as BolusCompletedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .bolus, title: "Bolus delivered", detail: u(m.insulinDelivered))
        case let m as BolexCompletedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .bolus, title: "Extended bolus", detail: u(m.insulinDelivered))
        case let m as CarbEnteredHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .carbs, title: "Carbs entered", detail: String(format: "%.0f g", m.carbs))
        case let m as BGHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .bg, title: "BG entered", detail: "\(m.bg) mg/dL")
        case let m as BasalRateChangeHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .basal, title: "Basal rate change", detail: u(m.commandBasalRate) + "/hr")
        case let m as TempRateActivatedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .tempRate, title: "Temp rate started", detail: String(format: "%.0f%%", m.percent))
        case is TempRateCompletedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .tempRate, title: "Temp rate ended")
        case let m as PumpingSuspendedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .pumping, title: "Insulin suspended", detail: m.reasonId == 0 ? "" : "reason \(m.reasonId)")
        case is PumpingResumedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .pumping, title: "Insulin resumed")
        case let m as CartridgeFilledHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .cartridge, title: "Cartridge filled", detail: u(m.insulinActual))
        case is CannulaFilledHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .cartridge, title: "Cannula filled")
        case is TubingFilledHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .cartridge, title: "Tubing filled")
        case is CartridgeInsertedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .cartridge, title: "Cartridge inserted")
        case is CartridgeRemovedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .cartridge, title: "Cartridge removed")
        case let m as AlarmActivatedHistoryLog:
            let n = alarmName(m.alarmId)
            return HistoryEvent(id: seq, date: date, category: .alarm, title: n.0, detail: n.1)
        case let m as AlarmClearedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .alarm, title: alarmName(m.alarmId).0 + " cleared")
        case let m as AlarmAckHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .alarm, title: alarmName(m.alarmId).0 + " acknowledged")
        case let m as AlertActivatedHistoryLog:
            let n = alertName(m.alertId)
            return HistoryEvent(id: seq, date: date, category: .alert, title: n.0, detail: n.1)
        case let m as AlertClearedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .alert, title: alertName(m.alertId).0 + " cleared")
        case let m as AlertAckHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .alert, title: alertName(m.alertId).0 + " acknowledged")
        case let m as CgmAlertActivatedHistoryLog:
            let n = cgmAlertName(m.alertId)
            return HistoryEvent(id: seq, date: date, category: .alert, title: n.0, detail: n.1)
        case let m as ReminderActivatedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .reminder, title: "Reminder", detail: "id \(m.reminderId)")
        default:
            return nil   // skip unmapped / high-frequency records (e.g. CGM samples shown on the chart)
        }
    }
}

// PumpBLEClientDelegate is @MainActor; PumpBLEClient delivers all callbacks on the main actor.
extension TandemBackend: PumpBLEClientDelegate {
    public func pumpClient(_ c: PumpBLEClient, didChange state: PumpBLEClient.State) {
        switch state {
        case .scanning: snapshot.connection = .scanning
        case .connecting, .discovering: snapshot.connection = .connecting
        case .ready: snapshot.connection = .connected
        case .disconnected, .idle:
            snapshot.connection = .disconnected
            // Re-backfill on the next connect so the gap from this disconnect gets filled.
            didBackfill = false; backfillActive = false
            backfillTimer?.invalidate(); backfillTimer = nil
            backfillBuffer.removeAll(); backfillBoluses.removeAll(); backfillEventLogs.removeAll()
            detectedIsMobi = nil   // re-detect the model on the next connect
        default: break
        }
        onChange?()
    }

    public func pumpClient(_ c: PumpBLEClient, didDiscover peripheral: CBPeripheral, rssi: Int) {
        // Authoritative model detection from the BLE advertised name: the Mobi advertises with
        // "Mobi" in its name; anything else Tandem is a t:slim X2. This directly names the model,
        // unlike the API version (a current t:slim X2 can report API >= 3.5, which would falsely
        // read as Mobi). ApiVersionResponse is only a fallback when the name doesn't identify it.
        if let name = peripheral.name, !name.isEmpty {
            let isMobi = name.localizedCaseInsensitiveContains("mobi")
            detectedIsMobi = isMobi
            snapshot.isMobi = isMobi
            snapshot.pumpModelName = isMobi ? "Mobi" : "t:slim X2"
            PumpModelStore.set(isMobi: isMobi)
        }
        c.connect(peripheral)
    }

    public func pumpClientDidBecomeReady(_ c: PumpBLEClient) {
        // Prefer resume (no code) when a prior pairing is saved; else full pair with the code.
        let coord: PairingCoordinator
        let isFullPairing: Bool
        if pairingCode.isEmpty, let stored = PairingStore.load() {
            coord = PairingCoordinator(resumeDerivedSecret: stored); isFullPairing = false
        } else if let full = try? PairingCoordinator(pairingCode: pairingCode), !pairingCode.isEmpty {
            coord = full; isFullPairing = true
        } else {
            startPolling(); return   // no code and no saved pairing — reads will be rejected
        }
        coord.onSendRequest = { msg in try? c.send(msg) }   // AUTHORIZATION passes the interlock
        coord.onError = { [weak self] _ in
            // Resume can fail if the pump forgot us; drop the saved secret so the UI re-pairs.
            if !isFullPairing { PairingStore.clear() }
            self?.snapshot.connection = .error; self?.onChange?()
        }
        coord.onPaired = { [weak self] key, _ in
            self?.authenticationKey = key
            if isFullPairing {
                PairingStore.save(coord.derivedSecret)   // enable future quick-pair
                self?.pairingCode = ""                    // subsequent connects resume
            }
            self?.startPolling()
        }
        coordinator = coord
        coord.start()
    }

    public var hasStoredPairing: Bool { PairingStore.load() != nil }
    public func forgetPairing() { PairingStore.clear(); authenticationKey = [] }

    public func pumpClient(_ c: PumpBLEClient, didReceiveFrame frame: [UInt8], on ch: Characteristic) {
        if ch == .authorization { coordinator?.handle(frame: frame); return }
        guard let parsed = try? ResponseParser.parse(frame: frame, characteristic: ch) else { return }
        switch parsed.message {
        case let m as ControlIQIOBResponse:
            snapshot.iobUnits = m.iobUnits
            // Accumulate an IOB time series (append on change or every ~4.5 min) for the chart.
            let now = Date()
            if let last = iobHistory.last {
                if abs(last.iob - m.iobUnits) > 0.001 || now.timeIntervalSince(last.date) > 270 {
                    iobHistory.append(IOBSample(date: now, iob: m.iobUnits))
                }
            } else { iobHistory.append(IOBSample(date: now, iob: m.iobUnits)) }
            if iobHistory.count > 288 { iobHistory.removeFirst() }
        case let m as InsulinStatusResponse: snapshot.reservoirUnits = Double(m.currentInsulinAmount)
        case let m as CurrentBatteryV2Response: snapshot.batteryPercent = m.batteryPercent
        case let m as CGMStatusResponse: snapshot.cgmSessionActive = m.sessionActive
        case let m as LoadStatusResponse:
            snapshot.cartridgeLoadState = m.loadStateId
            snapshot.cartridgeLoadActive = m.isLoadingActive
        case let m as CurrentEgvGuiDataV2Response:
            snapshot.cgmActive = m.hasValidReading
            snapshot.trend = m.trendArrow
            if m.hasValidReading {
                let now = Date()
                snapshot.glucose = m.cgmReading
                snapshot.glucoseDate = now
                // Append on a value change OR every ~4.5 min, so a stable BG still advances the
                // plot to "now" (a value-only de-dup left the newest point drifting into the past).
                if let last = glucoseHistory.last {
                    if last.mgdl != m.cgmReading || now.timeIntervalSince(last.date) > 270 {
                        glucoseHistory.append(GlucoseReading(date: now, mgdl: m.cgmReading))
                    }
                } else {
                    glucoseHistory.append(GlucoseReading(date: now, mgdl: m.cgmReading))
                }
                if glucoseHistory.count > 288 { glucoseHistory.removeFirst() }
            }
        case let m as LastBolusStatusV2Response:
            if let cont = lastBolusCont { cont.resume(returning: m); lastBolusCont = nil }
            snapshot.lastBolusUnits = m.deliveredUnits
            // Convert the pump timestamp using the pump↔phone clock anchor (timezone-agnostic).
            if let a = pumpTimeAnchor {
                snapshot.lastBolusDate = a.phone.addingTimeInterval(Double(Int64(m.timestamp) - Int64(a.pump)))
            }
        case let m as CurrentBolusStatusResponse:
            bolusStatusCont?.resume(returning: m); bolusStatusCont = nil
        case let m as DismissNotificationResponse:
            lastDismissAck = "ack \(m.status)\(m.status == 0 ? " (accepted)" : " (rejected)")"
            renderDebug()
        case let m as BolusCalcDataSnapshotResponse:
            calcSnapshot = m
            if m.maxBolusAmount > 0 { snapshot.maxBolusUnits = Double(m.maxBolusAmount) / 1000.0 }
            snapshot.carbRatio = m.carbRatioGramsPerUnit
            snapshot.isf = m.isf
            snapshot.targetBg = m.targetBg
        case let m as TimeSinceResetResponse:
            pumpTimeAnchor = (m.currentTime, Date())
            timeCont?.resume(returning: m); timeCont = nil
            // Kick off the CGM history backfill once per connect (after we can talk to the pump).
            if !didBackfill { didBackfill = true; try? client.send(HistoryLogStatusRequest()) }
        case let m as HistoryLogStatusResponse:
            guard !backfillActive, m.numEntries > 0 else { break }
            backfillActive = true
            backfillBuffer.removeAll(keepingCapacity: true)
            backfillBoluses.removeAll(keepingCapacity: true)
            backfillEventLogs.removeAll(keepingCapacity: true)
            backfillFirstSeq = m.firstSequenceNum
            backfillNextEnd = m.lastSequenceNum
            backfillPages = 0
            requestBackfillPage()
        case let m as HistoryLogStreamResponse:
            guard backfillActive else { break }
            for r in m.cgmReadings { backfillBuffer.append((r.pumpTimeSec, r.glucoseMgdl)) }
            for b in m.bolusRecords { backfillBoluses.append((b.pumpTimeSec, b.deliveredUnits, b.iobUnits)) }
            backfillEventLogs.append(contentsOf: m.events)
            if backfillEventLogs.count > 2000 { backfillEventLogs.removeFirst(backfillEventLogs.count - 2000) }
            scheduleBackfillTick()   // debounce: page ends when frames stop arriving
        case let m as AlertStatusResponse: alertList = m.notifications; noteAlert("al", m.bitmap); mergeNotifications()
        case let m as AlarmStatusResponse: alarmList = m.notifications; noteAlert("am", m.bitmap); mergeNotifications()
        case let m as CGMAlertStatusResponse: cgmAlertList = m.notifications; noteAlert("c", m.bitmap); mergeNotifications()
        case let m as ReminderStatusResponse: reminderList = m.notifications; noteAlert("r", m.bitmap); mergeNotifications()
        case let m as MalfunctionBitmaskStatusResponse: malfunctionList = m.notifications; noteAlert("m", m.bitmap); mergeNotifications()
        case let m as BolusPermissionResponse: permissionCont?.resume(returning: m); permissionCont = nil
        case let m as InitiateBolusResponse: initiateCont?.resume(returning: m); initiateCont = nil
        // Workstream B: pump model + basal + Control-IQ status.
        case let m as ApiVersionResponse:
            snapshot.softwareVersion = "\(m.majorVersion).\(m.minorVersion)"
            // The BLE name (set at discovery) is authoritative for the model. Only fall back to the
            // API-version heuristic if the name didn't identify it (e.g. name was unavailable).
            if detectedIsMobi == nil {
                snapshot.isMobi = m.isMobi
                snapshot.pumpModelName = m.isMobi ? "Mobi" : "t:slim X2"
                PumpModelStore.set(isMobi: m.isMobi)
            }
            snapshot.softwareVersion = "\(m.majorVersion).\(m.minorVersion)"
        case let m as CurrentBasalStatusResponse:
            snapshot.basalRateUnitsPerHour = m.currentBasalUnitsPerHour
        case let m as ControlIQInfoV2Response:
            snapshot.controlIQMode = m.currentUserModeType
            snapshot.controlIQEnabled = m.closedLoopEnabled
        case let m as CGMHardwareInfoResponse:
            if let c = cgmHwCont { cgmHwCont = nil; c.resume(returning: m) }
        case let m as SuspendPumpingResponse:
            if m.accepted { snapshot.deliverySuspended = true }
        case let m as ResumePumpingResponse:
            if m.accepted { snapshot.deliverySuspended = false }
        default: break
        }
        onChange?()
    }

    public func pumpClient(_ c: PumpBLEClient, didError error: Error) {
        snapshot.connection = .disconnected; onChange?()
    }
}
