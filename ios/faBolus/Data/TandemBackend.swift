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
    ///
    /// Note on time sync: `ChangeTimeDateRequest` is *unannotated* in the reverse-engineered protocol,
    /// so it falls back to `SupportedDevices.ALL` — but that default is an assumption, not a tested
    /// guarantee. On real t:slim X2 hardware the signed time write is **not** honored (the pump doesn't
    /// change its clock, and `sendControl` can't tell — it doesn't inspect the response status), so
    /// time sync stays Mobi-only.
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
        applyAutoRules(raw, now: now)
        activeNotifications = raw.filter { !acknowledged.keys.contains(noteKey($0)) }.map(Self.toAlert)
    }

    /// Apply the user's conditional auto-rules (time-of-day / kind / glucose → auto-snooze or
    /// auto-dismiss). Both actions record a local ack (hide + stop notifying); `autoDismiss` also
    /// fires a signed dismiss on pumps that honor it. SAFETY: alarms **and** malfunctions are never
    /// auto-acted — the malfunction list is excluded here, and the engine additionally refuses the
    /// `.alarm` kind.
    private func applyAutoRules(_ raw: [PumpNotification], now: Date) {
        let rules = AppSettings.shared.alertRules
        guard !rules.isEmpty else { return }
        let protectedKeys = Set((malfunctionList + alarmList).map(noteKey))
        for n in raw {
            let key = noteKey(n)
            if acknowledged[key] != nil || protectedKeys.contains(key) { continue }
            let alert = Self.toAlert(n)
            guard let action = AlertRuleEngine.action(for: alert, rules: rules, now: now,
                                                      glucose: snapshot.glucose) else { continue }
            acknowledged[key] = now   // hide locally + stop re-notifying (both actions)
            if action == .autoDismiss, capabilities.supportsRemoteAlertDismiss {
                Task { [weak self] in await self?.dismissNotification(alert) }
            }
        }
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

    // Oracle bolus-type bits (audit C-07, BolusDeliveryHistoryLog.BolusType): FOOD1 is used when there
    // ARE carbs, FOOD2 when there are none. `perform` selects between them by carb presence and OR-s in
    // EXTENDED for a combo bolus — it no longer hard-codes FOOD2 with carbs populated (which was
    // internally inconsistent with the reverse-engineered reference).
    private static let food1 = 1    // carbs present
    private static let food2 = 8    // units-only (no carbs)
    private static let extendedBit = 4
    private static let maxCarbGrams = 1000   // sanity bound before UInt/Int conversion (audit C-07)
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
    // Single-flight glucose refresh (audit C-05). Concurrent callers coalesce onto ONE in-flight pump
    // read and are all resumed exactly once when the CGM reading arrives, on timeout, or on disconnect —
    // fixing the old single-slot design where a second caller orphaned the first (permanent hang) and a
    // stale timeout could resume a newer request. The generation tag makes a timeout a no-op once its
    // read has completed.
    private var glucoseWaiters: [CheckedContinuation<Void, Never>] = []
    private var glucoseReadGeneration = 0
    private var glucoseReadInFlight = false
    private var cgmHwCont: CheckedContinuation<CGMHardwareInfoResponse?, Never>?
    /// Active IDP id from the last ProfileStatus read, to flag the active profile as IDPSettings arrive.
    private var profileActiveIdpId = -1
    /// The profile whose segments are being read into snapshot.viewedProfileSegments (-1 = none).
    private var viewedProfileId = -1

    /// One-shot reads used by the bolus-progress loop (routine polling is paused meanwhile). Both carry a
    /// bounded timeout (audit A-03) so a single lost status reply can't freeze the poll loop past its
    /// deadline; the timeout is gated on `pumpTxGeneration` so it can't misfire onto a later transaction.
    private func currentBolusStatus() async throws -> CurrentBolusStatusResponse {
        let gen = pumpTxGeneration
        return try await withCheckedThrowingContinuation { cont in
            bolusStatusCont = cont
            scheduleResponseTimeout(seconds: 4) { [weak self] in
                guard let self, self.pumpTxGeneration == gen, let c = self.bolusStatusCont else { return }
                self.bolusStatusCont = nil; c.resume(throwing: BolusError.pumpRejected("no bolus-status response (timeout)"))
            }
            do { try client.send(CurrentBolusStatusRequest()) } catch { bolusStatusCont = nil; cont.resume(throwing: error) }
        }
    }
    private func lastBolusStatus() async throws -> LastBolusStatusV2Response {
        let gen = pumpTxGeneration
        return try await withCheckedThrowingContinuation { cont in
            lastBolusCont = cont
            scheduleResponseTimeout(seconds: 4) { [weak self] in
                guard let self, self.pumpTxGeneration == gen, let c = self.lastBolusCont else { return }
                self.lastBolusCont = nil; c.resume(throwing: BolusError.pumpRejected("no last-bolus response (timeout)"))
            }
            do { try client.send(LastBolusStatusV2Request()) } catch { lastBolusCont = nil; cont.resume(throwing: error) }
        }
    }

    public var writePolicy: PumpBLEClient.WritePolicy {
        get { client.writePolicy } set { client.writePolicy = newValue }
    }

    // MARK: - Signed-transaction serialization (audit A-03)
    // Every top-level signed/control workflow (bolus, suspend/resume, temp-basal, modes, cartridge,
    // dismiss-notification) runs under this async lock so two never interleave and clobber each other's
    // response continuation slot. The in-bolus status polls + `cancelBolus` are intentionally NOT gated:
    // they operate within / against the already-held bolus transaction. `@MainActor` gives mutual
    // exclusion between awaits; the lock adds it across them.
    private var pumpTxBusy = false
    private var pumpTxWaiters: [CheckedContinuation<Void, Never>] = []
    /// Bumped on each acquire so a stale per-request timeout from a prior transaction can't fire on a
    /// later one that happens to reuse the same continuation slot.
    private var pumpTxGeneration = 0
    /// True while a bolus (standard/extended) is mid-flight — a second delivery is rejected, not queued
    /// (queuing manual double-taps would double-dose). Set synchronously right after the guard.
    private var deliveryInProgress = false

    private func acquirePumpTx() async {
        while pumpTxBusy {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in pumpTxWaiters.append(c) }
        }
        pumpTxBusy = true
        pumpTxGeneration &+= 1
    }
    private func releasePumpTx() {
        pumpTxBusy = false
        if !pumpTxWaiters.isEmpty { pumpTxWaiters.removeFirst().resume() }
    }
    /// Run a signed/control transaction under the serialization lock.
    private func withPumpTx<T>(_ body: () async throws -> T) async throws -> T {
        await acquirePumpTx()
        defer { releasePumpTx() }
        return try await body()
    }

    /// Fire `fire` after `seconds` on the main actor — used as a per-request response watchdog so a lost
    /// pump reply can't suspend a signed transaction forever (which would also skip the `defer` that
    /// restores `writePolicy`). The closure is a no-op if its transaction generation is stale or the
    /// continuation slot has already been cleared by the real response.
    private func scheduleResponseTimeout(seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            fire()
        }
    }

    /// Resume EVERY outstanding signed-flow continuation with an error (audit A-03). Called on disconnect
    /// and on a transport/parse error so a lost pump response can't leave a signed transaction suspended
    /// forever. Idempotent: each slot is nil-checked and cleared.
    private func failPumpWaiters(_ error: Error) {
        timeCont?.resume(throwing: error); timeCont = nil
        permissionCont?.resume(throwing: error); permissionCont = nil
        initiateCont?.resume(throwing: error); initiateCont = nil
        bolusStatusCont?.resume(throwing: error); bolusStatusCont = nil
        lastBolusCont?.resume(throwing: error); lastBolusCont = nil
        cgmHwCont?.resume(returning: nil); cgmHwCont = nil
        // Belt-and-suspenders: a terminated transaction must never leave delivery writes enabled on the
        // persistent client into the next connection.
        client.writePolicy = .readOnly
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
        predictivePollTimer?.invalidate(); predictivePollTimer = nil
        client.disconnect()
    }

    public func recommendBolus(carbsGrams: Double, bgMgdl: Int?) async -> BolusRecommendation {
        var rec = BolusRecommendation()
        rec.carbsGrams = carbsGrams; rec.bgMgdl = bgMgdl; rec.iobUnits = snapshot.iobUnits
        let carbs: Double? = carbsGrams > 0 ? carbsGrams : nil
        if let s = calcSnapshot, s.carbRatio > 0 {
            // Verified pump profile → the single oracle-backed calculator (audit C-01). Below-target
            // BG now correctly *reduces* the dose; IOB only offsets a BG correction, matching the pump.
            let profile = BolusMath.Profile(carbRatioGramsPerUnit: s.carbRatioGramsPerUnit,
                                            isfMgdlPerUnit: s.isf, targetBgMgdl: s.targetBg,
                                            iobUnits: snapshot.iobUnits)
            rec.recommendedUnits = BolusMath.recommendedUnits(carbsGrams: carbs, bgMgdl: bgMgdl, profile: profile)
            rec.inputsVerified = true
        } else {
            // Guarded fallback (audit C-01): the verified profile hasn't arrived. Use the SAME
            // calculator with an explicitly-assumed carb ratio and compute carbs-only (no correction
            // off an unknown ISF/target), then flag it so the UI requires the user to confirm the
            // assumed value before delivering — never auto-deliver on unverified inputs.
            let assumed = BolusMath.Profile(carbRatioGramsPerUnit: 10, isfMgdlPerUnit: 40,
                                            targetBgMgdl: 110, iobUnits: snapshot.iobUnits)
            rec.recommendedUnits = BolusMath.recommendedUnits(carbsGrams: carbs, bgMgdl: nil, profile: assumed)
            rec.inputsVerified = false
            rec.assumedProfile = assumed
        }
        rec.recommendedUnits = (rec.recommendedUnits * 20).rounded() / 20   // snap to 0.05 u pump increment
        return rec
    }

    /// Force a fresh CGM read and wait (bounded ~2.5 s) for it, so a correction uses the newest value.
    /// Single-flight (audit C-05): concurrent callers coalesce onto one pump read; all are resumed
    /// exactly once when the reading arrives, on timeout, or on disconnect.
    public func refreshGlucoseNow() async {
        guard snapshot.connection == .connected else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            glucoseWaiters.append(cont)
            if glucoseReadInFlight { return }   // join the in-flight read
            glucoseReadInFlight = true
            glucoseReadGeneration &+= 1
            let gen = glucoseReadGeneration
            try? client.send(CurrentEgvGuiDataV2Request())
            // Safety timeout so we never hang if the pump doesn't answer. Tagged by generation, so a
            // stale timeout whose read already completed is a no-op.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.glucoseReadInFlight, self.glucoseReadGeneration == gen else { return }
                self.completeGlucoseRead()
            }
        }
    }

    /// Resume every coalesced glucose waiter exactly once (CGM arrival, timeout, or disconnect).
    private func completeGlucoseRead() {
        glucoseReadInFlight = false
        let waiters = glucoseWaiters
        glucoseWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    /// Delivers a standard bolus via the validated signed path. Raises the write policy to
    /// `.allowDelivery` only for this call. `perform` picks FOOD1/FOOD2 by carb presence (audit C-07).
    public func deliverBolus(units: Double, carbsGrams: Double?, bgMgdl: Int?) async throws -> Double {
        try validateDeliver(total: units)
        let mu = UInt32((units * 1000).rounded())
        guard mu >= 50 else { throw BolusError.pumpRejected("below 0.05 u") }
        return try await perform(totalMu: mu, extendedMu: 0, extendedSeconds: 0,
                                 displayUnits: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
    }

    /// Delivers an **extended (combo)** bolus: `nowUnits` up front and the remainder over
    /// `durationMinutes`. Uses the full-form InitiateBolusRequest with the EXTENDED bit set (oracle-
    /// verified byte format); `perform` OR-s FOOD1/FOOD2 by carb presence. Total must be ≥ 0.40 U.
    public func deliverExtendedBolus(totalUnits: Double, nowUnits: Double, durationMinutes: Int,
                                     carbsGrams: Double?, bgMgdl: Int?) async throws -> Double {
        try validateDeliver(total: totalUnits)
        let safeNow = nowUnits.isFinite ? nowUnits : 0          // audit A-07: no NaN into UInt32(...)
        let now = max(0, min(safeNow, totalUnits))
        let nowMu = UInt32((now * 1000).rounded())
        let laterMu = UInt32((max(0, totalUnits - now) * 1000).rounded())
        guard (nowMu + laterMu) >= InitiateBolusRequest.minExtendedBolusMilliunits else {
            throw BolusError.pumpRejected("extended bolus below 0.40 u")
        }
        // Clamp duration to [1 min, 24 h] so `UInt32(minutes * 60)` can neither overflow nor trap.
        let clampedMinutes = max(1, min(durationMinutes, 24 * 60))
        let seconds = UInt32(clampedMinutes * 60)
        return try await perform(totalMu: nowMu, extendedMu: laterMu, extendedSeconds: seconds,
                                 displayUnits: totalUnits, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
    }

    /// Shared pre-flight validation for any delivery (standard or extended).
    private func validateDeliver(total: Double) throws {
        guard snapshot.connection == .connected || snapshot.connection == .bolusing else { throw BolusError.notConnected }
        guard isPaired else { throw BolusError.pumpRejected("not paired") }
        // Reject non-finite / negative before any `UInt32(... * 1000)` conversion, which would trap
        // (audit A-07). The max clamp only bounds the upper end.
        guard total.isFinite, total >= 0 else { throw BolusError.pumpRejected("invalid dose") }
        guard total <= snapshot.maxBolusUnits, total <= Interlocks.absoluteMaxUnits else {
            throw BolusError.exceedsMax(min(snapshot.maxBolusUnits, Interlocks.absoluteMaxUnits))
        }
    }

    /// The validated signed delivery flow, shared by standard + extended boluses. When `extendedMu > 0`
    /// it sends the full-form InitiateBolusRequest (now-portion `totalMu`, later-portion `extendedMu`
    /// over `extendedSeconds`); otherwise a standard units-only bolus.
    private func perform(totalMu: UInt32, extendedMu: UInt32, extendedSeconds: UInt32,
                         displayUnits units: Double,
                         carbsGrams: Double? = nil, bgMgdl: Int? = nil) async throws -> Double {
        // Audit A-03: reject a second bolus while one is mid-flight (set synchronously so a double-tap
        // can't slip past before the flag is raised). Then serialize behind any other signed transaction.
        guard !deliveryInProgress else { throw BolusError.pumpRejected("a bolus is already in progress") }
        deliveryInProgress = true
        defer { deliveryInProgress = false }
        await acquirePumpTx()
        defer { releasePumpTx() }
        let gen = pumpTxGeneration

        // Fresh signing timestamp (the pump validates the HMAC against its clock).
        let time: TimeSinceResetResponse = try await withCheckedThrowingContinuation { cont in
            timeCont = cont
            scheduleResponseTimeout(seconds: 5) { [weak self] in
                guard let self, self.pumpTxGeneration == gen, let c = self.timeCont else { return }
                self.timeCont = nil; c.resume(throwing: BolusError.pumpRejected("no time-sync response (timeout)"))
            }
            do { try client.send(TimeSinceResetRequest()) } catch { timeCont = nil; cont.resume(throwing: error) }
        }
        signingTimestamp = time.currentTime

        let previousPolicy = client.writePolicy
        client.writePolicy = .allowDelivery
        defer { client.writePolicy = previousPolicy }
        snapshot.connection = .bolusing; onChange?()

        let perm: BolusPermissionResponse = try await withCheckedThrowingContinuation { cont in
            permissionCont = cont
            scheduleResponseTimeout(seconds: 8) { [weak self] in
                guard let self, self.pumpTxGeneration == gen, let c = self.permissionCont else { return }
                self.permissionCont = nil; c.resume(throwing: BolusError.pumpRejected("no permission response (timeout)"))
            }
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

        // Record carbs/BG on the pump BEFORE initiating — this is what populates the carb amount on
        // the pump graph / t:connect and feeds Control-IQ's carb awareness. Metadata only (does NOT
        // change the delivered dose). Best-effort: a failed entry must NEVER abort the bolus, so the
        // InitiateBolus below still fires. Also mirrored inline in InitiateBolusRequest.bolusCarbs/BG.
        // Bound carbs before the Int/UInt16 conversion so a garbage value can't overflow or land as an
        // absurd pump record (audit C-07). BG is already an Int; clamp to a sane 16-bit-safe range.
        let carbsInt = max(0, min(Self.maxCarbGrams, carbsGrams.map { Int($0.rounded()) } ?? 0))
        let bgInt = max(0, min(600, bgMgdl ?? 0))
        // Oracle bolus-type selection (audit C-07): carbs → FOOD1, else FOOD2; | EXTENDED for a combo.
        let extended = extendedMu > 0
        let foodBit = carbsInt > 0 ? Self.food1 : Self.food2
        let bitmask = extended ? (foodBit | Self.extendedBit) : foodBit
        // For a standard carb bolus the reference puts the whole dose in `foodVolume` (correction 0);
        // units-only and the extended path keep foodVolume 0 (extended+carbs foodVolume is unverified —
        // see docs/UNVERIFIED-GUESSES.md).
        let foodVolume: UInt32 = (carbsInt > 0 && !extended) ? totalMu : 0
        if carbsInt > 0 {
            try? client.send(RemoteCarbEntryRequest(carbs: carbsInt, unknown: 1,
                                                    pumpTimeSecondsSinceBoot: signingTimestamp, bolusId: perm.bolusId),
                             authenticationKey: authenticationKey, pumpTimeSinceReset: signingTimestamp)
        }
        if bgInt > 0 {
            try? client.send(RemoteBgEntryRequest(bg: bgInt, useForCgmCalibration: false, isAutopopBg: false,
                                                  pumpTimeSecondsSinceBoot: signingTimestamp, bolusId: perm.bolusId),
                             authenticationKey: authenticationKey, pumpTimeSinceReset: signingTimestamp)
        }

        let ini: InitiateBolusResponse = try await withCheckedThrowingContinuation { cont in
            initiateCont = cont
            scheduleResponseTimeout(seconds: 8) { [weak self] in
                guard let self, self.pumpTxGeneration == gen, let c = self.initiateCont else { return }
                self.initiateCont = nil; c.resume(throwing: BolusError.pumpRejected("no initiate response (timeout)"))
            }
            do {
                let request: InitiateBolusRequest = extended
                    ? InitiateBolusRequest(totalVolume: totalMu, bolusID: perm.bolusId, bolusTypeBitmask: bitmask,
                                           foodVolume: foodVolume, correctionVolume: 0, bolusCarbs: carbsInt, bolusBG: bgInt, bolusIOB: 0,
                                           extendedVolume: extendedMu, extendedSeconds: extendedSeconds, extended3: 0)
                    : InitiateBolusRequest(totalVolume: totalMu, bolusID: perm.bolusId, bolusTypeBitmask: bitmask,
                                           foodVolume: foodVolume, correctionVolume: 0, bolusCarbs: carbsInt, bolusBG: bgInt, bolusIOB: 0,
                                           extendedVolume: 0, extendedSeconds: 0, extended3: 0)
                try client.send(request, authenticationKey: authenticationKey,
                                pumpTimeSinceReset: signingTimestamp, allowInsulinDelivery: true)
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
            // Poll ~2×/s so a small/finished bolus is detected quickly and the completion (and the
            // remote "delivered/cancelled" echo) fires promptly, instead of lingering ~1.2 s+.
            try? await Task.sleep(nanoseconds: 500_000_000)
            if cancelRequested { break }
            // Stop polling (and release the transaction lock) promptly if the link dropped — otherwise
            // a disconnect mid-bolus would spin here until the deadline holding the lock (audit A-03).
            guard snapshot.connection == .bolusing else { break }
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
        // Don't stomp a disconnect that happened mid-bolus back to `.connected` (audit A-03).
        if snapshot.connection == .bolusing { snapshot.connection = .connected }
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
        // Fresh signing timestamp for the HMAC. Serialized behind any other signed transaction and
        // timed-out so a lost time-sync reply can't hang / clobber another transaction (audit A-03).
        await acquirePumpTx()
        let gen = pumpTxGeneration
        let time: TimeSinceResetResponse
        do {
            time = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TimeSinceResetResponse, Error>) in
                timeCont = cont
                scheduleResponseTimeout(seconds: 5) { [weak self] in
                    guard let self, self.pumpTxGeneration == gen, let c = self.timeCont else { return }
                    self.timeCont = nil; c.resume(throwing: BolusError.pumpRejected("no time-sync response (timeout)"))
                }
                do { try client.send(TimeSinceResetRequest()) } catch { timeCont = nil; cont.resume(throwing: error) }
            }
        } catch { releasePumpTx(); return }
        signingTimestamp = time.currentTime

        let previous = client.writePolicy
        client.writePolicy = .allowNonDelivery
        defer { client.writePolicy = previous; releasePumpTx() }
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
        let gen = pumpTxGeneration
        let time: TimeSinceResetResponse = try await withCheckedThrowingContinuation { cont in
            timeCont = cont
            scheduleResponseTimeout(seconds: 5) { [weak self] in
                guard let self, self.pumpTxGeneration == gen, let c = self.timeCont else { return }
                self.timeCont = nil; c.resume(throwing: BolusError.pumpRejected("no time-sync response (timeout)"))
            }
            do { try client.send(TimeSinceResetRequest()) } catch { timeCont = nil; cont.resume(throwing: error) }
        }
        signingTimestamp = time.currentTime
    }

    /// Fresh-timestamp, policy-raised signed send for a control command. `delivery` selects the
    /// WritePolicy + the insulin-delivery signing flag. Fire-and-send: the response updates state.
    /// Serialized behind any other signed transaction (audit A-03) so its `timeCont` can't be clobbered.
    private func sendControl(_ message: Message, delivery: Bool) async throws {
        guard snapshot.connection == .connected || snapshot.connection == .bolusing else {
            throw BolusError.notConnected
        }
        try await withPumpTx {
            try await refreshSigningTimestamp()
            let previous = client.writePolicy
            client.writePolicy = delivery ? .allowDelivery : .allowNonDelivery
            defer { client.writePolicy = previous }
            _ = try client.send(message, authenticationKey: authenticationKey,
                                pumpTimeSinceReset: signingTimestamp, allowInsulinDelivery: delivery)
            // Let the signed ack arrive (didReceiveFrame updates the snapshot) before restoring policy.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
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

    // Control-IQ settings — non-insulin config.
    public func setControlIQ(enabled: Bool, weightLbs: Int, totalDailyInsulinUnits: Int) async throws {
        try await sendControl(ChangeControlIQSettingsRequest(enabled: enabled, weightLbs: weightLbs,
                                                             totalDailyInsulinUnits: totalDailyInsulinUnits), delivery: false)
    }
    public func refreshControlIQSettings() async {
        guard snapshot.connection == .connected else { return }
        try? client.send(ControlIQInfoV1Request())    // reply handled in didReceiveFrame
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    // Profiles (IDP). Switch/rename/delete change the active basal profile → insulin-affecting.
    public func refreshProfiles() async {
        guard snapshot.connection == .connected else { return }
        viewedProfileId = -1                           // list refresh must not trigger segment reads
        try? client.send(ProfileStatusRequest())      // → IDPSettings cascade in didReceiveFrame
        try? await Task.sleep(nanoseconds: 1_400_000_000)
    }
    public func setActiveProfile(idpId: Int) async throws {
        try await sendControl(SetActiveIDPRequest(idpId: idpId, profileIndex: 0), delivery: true)
        await refreshProfiles()
    }
    public func renameProfile(idpId: Int, name: String) async throws {
        try await sendControl(RenameIDPRequest(idpId: idpId, profileIndex: 0, profileName: name), delivery: true)
        await refreshProfiles()
    }
    public func deleteProfile(idpId: Int) async throws {
        try await sendControl(DeleteIDPRequest(idpId: idpId, profileIndex: 0), delivery: true)
        await refreshProfiles()
    }
    public func createProfile(name: String, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double,
                              isf: Int, targetBg: Int, insulinDurationMinutes: Int) async throws {
        try await sendControl(CreateIDPRequest(
            name: name,
            firstSegmentProfileCarbRatio: UInt32(max(0, (carbRatioGramsPerUnit * 1000).rounded())),
            firstSegmentProfileStartTime: 0,
            firstSegmentProfileBasalRate: Int((max(0, basalRateUnitsPerHour) * 1000).rounded()),
            firstSegmentProfileTargetBG: targetBg, firstSegmentProfileISF: isf,
            profileInsulinDuration: insulinDurationMinutes,
            timeSegmentBitmask: 1, bolusSettingsBitmask: 0, carbEntry: 1, idpSourceId: 0), delivery: true)
        await refreshProfiles()
    }
    public func refreshProfileSegments(idpId: Int) async {
        guard snapshot.connection == .connected else { return }
        viewedProfileId = idpId
        snapshot.viewedProfileSegments = []
        try? client.send(IDPSettingsRequest(idpId: idpId))   // → segment reads cascade in didReceiveFrame
        try? await Task.sleep(nanoseconds: 1_400_000_000)
    }
    public func addProfileSegment(idpId: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
                                  carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async throws {
        try await setSegment(idpId: idpId, segmentIndex: 0, operationId: 1, startTimeMinutes: startTimeMinutes,
                             basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf, targetBg: targetBg)
    }
    public func modifyProfileSegment(idpId: Int, segmentIndex: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
                                     carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async throws {
        try await setSegment(idpId: idpId, segmentIndex: segmentIndex, operationId: 0, startTimeMinutes: startTimeMinutes,
                             basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf, targetBg: targetBg)
    }
    public func deleteProfileSegment(idpId: Int, segmentIndex: Int) async throws {
        try await setSegment(idpId: idpId, segmentIndex: segmentIndex, operationId: 2, startTimeMinutes: 0,
                             basalRateUnitsPerHour: 0, carbRatioGramsPerUnit: 0, isf: 0, targetBg: 0)
    }
    // operationId: 0 modify, 1 create, 2 delete (IDPSegmentOperation). idpStatusId 0 = no special flags.
    private func setSegment(idpId: Int, segmentIndex: Int, operationId: Int, startTimeMinutes: Int,
                            basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async throws {
        try await sendControl(SetIDPSegmentRequest(
            idpId: idpId, profileIndex: 0, segmentIndex: segmentIndex, operationId: operationId,
            profileStartTime: startTimeMinutes,
            profileBasalRate: Int((max(0, basalRateUnitsPerHour) * 1000).rounded()),
            profileCarbRatio: UInt32(max(0, (carbRatioGramsPerUnit * 1000).rounded())),
            profileTargetBG: targetBg, profileISF: isf, idpStatusId: 0), delivery: true)
        await refreshProfileSegments(idpId: idpId)
    }

    // Reminders / alert thresholds — non-insulin config.
    public func setLowInsulinAlert(thresholdUnits: Int) async throws {
        try await sendControl(SetLowInsulinAlertRequest(insulinThreshold: thresholdUnits), delivery: false)
    }
    public func setAutoOffAlert(enabled: Bool, durationMinutes: Int) async throws {
        try await sendControl(SetAutoOffAlertRequest(enableAutoOff: enabled, autoOffDuration: durationMinutes, bitmask: 0), delivery: false)
    }
    public func setSiteChangeReminder(enabled: Bool, days: Int, timeOfDayMinutes: Int) async throws {
        try await sendControl(SetSiteChangeReminderRequest(enable: enabled, dayCount: days,
                                                           timeOfDayMinutes: UInt32(max(0, timeOfDayMinutes)), bitmask: 0), delivery: false)
    }
    public func setAlertSnooze(enabled: Bool, durationMinutes: Int) async throws {
        try await sendControl(SetPumpAlertSnoozeRequest(snoozeEnabled: enabled, snoozeDurationMins: durationMinutes), delivery: false)
    }
    public func setCgmHighLowAlert(alertType: Int, thresholdMgdl: Int, repeatMinutes: Int, enabled: Bool) async throws {
        try await sendControl(CgmHighLowAlertRequest(alertType: alertType, threshold: thresholdMgdl,
                                                     repeatDurationMinutes: repeatMinutes, enableAlert: enabled, bitmask: 0), delivery: false)
    }
    public func setCgmOutOfRangeAlert(enabled: Bool, delayMinutes: Int) async throws {
        try await sendControl(CgmOutOfRangeAlertRequest(enable: enabled, alertDelay: delayMinutes, bitmask: 0), delivery: false)
    }
    public func setCgmRiseFallAlert(alertType: Int, enabled: Bool, mgdlPerMin: Int) async throws {
        try await sendControl(CgmRiseFallAlertRequest(alertType: alertType, enable: enabled, mgPerDl: mgdlPerMin, bitmask: 0), delivery: false)
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
                           ApiVersionRequest(), ControlIQInfoV2Request(), BasalLimitSettingsRequest()] {
            try? client.send(r)
        }
    }

    // MARK: - CGM reading time + predictive polling (Bug 5)

    /// Latest CGM reading time seen from the pump (its own clock), used to detect a *new* reading.
    private var lastCgmPumpSec: UInt32 = 0
    private var predictivePollTimer: Timer?
    private var predictiveBurstDeadline: Date?
    /// Predictive burst tuning. CGM cadence is ~5 min; start a little early and keep trying past the
    /// expected time until the reading advances, polling only the single EGV request (battery-light).
    private static let cgmIntervalSec: Double = 300
    private static let predictiveLeadSec: Double = 20
    private static let predictiveWindowSec: Double = 150
    private static let predictivePollEverySec: Double = 10
    /// Master switch; if predictive polling ever proves costly, set false to fall back to age-fix-only.
    var predictivePollingEnabled = true

    /// Convert a pump-clock reading timestamp to a real `Date` via the phone↔pump anchor. Clamps to
    /// `now`; falls back to `now` when there's no anchor or the result is implausibly far off (a sign
    /// the timestamp base is wrong), so a bad value can never masquerade as fresh or ancient.
    private func cgmReadingDate(pumpSec: UInt32, now: Date) -> Date {
        guard pumpSec > 0, let a = pumpTimeAnchor else { return now }
        let candidate = a.phone.addingTimeInterval(Double(Int64(pumpSec) - Int64(a.pump)))
        if candidate > now.addingTimeInterval(60) { return now }                 // future → clamp
        if now.timeIntervalSince(candidate) > 24 * 60 * 60 { return now }         // absurd past → fall back
        return candidate
    }

    /// Line up a short EGV-only poll burst around the next expected reading (~5 min after this one).
    /// A newly-arrived reading reschedules this, which naturally ends the previous burst.
    private func schedulePredictiveBurst(afterReadingAt readingDate: Date) {
        guard predictivePollingEnabled else { return }
        predictivePollTimer?.invalidate(); predictivePollTimer = nil
        let expected = readingDate.addingTimeInterval(Self.cgmIntervalSec)
        predictiveBurstDeadline = expected.addingTimeInterval(Self.predictiveWindowSec)
        let delay = max(1, expected.addingTimeInterval(-Self.predictiveLeadSec).timeIntervalSinceNow)
        predictivePollTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { self.runPredictiveBurst() }
        }
    }

    private func runPredictiveBurst() {
        predictivePollTimer?.invalidate(); predictivePollTimer = nil
        // Skip while a bolus is delivering (that path already fast-polls) or when disconnected.
        guard predictivePollingEnabled, snapshot.connection == .connected else { return }
        try? client.send(CurrentEgvGuiDataV2Request())
        predictivePollTimer = Timer.scheduledTimer(withTimeInterval: Self.predictivePollEverySec, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard self.snapshot.connection == .connected,
                      let deadline = self.predictiveBurstDeadline, Date() < deadline else {
                    self.predictivePollTimer?.invalidate(); self.predictivePollTimer = nil; return
                }
                try? self.client.send(CurrentEgvGuiDataV2Request())
            }
        }
    }

    private func startPolling() {
        fastRead(); staticRead()
        scheduleAlertRead()
        pollTick = 0
        pollTimer?.invalidate()
        predictivePollTimer?.invalidate(); predictivePollTimer = nil
        lastCgmPumpSec = 0
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
            // Collapse readings that fall in the same time bucket. The pump logs more than one CGM
            // record type per interval (typeIds 256 + 399 — filtered + raw), each with its own
            // glucose value at the same pump timestamp; keeping both plotted them as vertical stacks
            // of dots at each time. CGM is ~5 min apart, so keep only the FIRST reading within any
            // ~150 s window (regardless of value) — one point per interval.
            var deduped: [GlucoseReading] = []
            for r in merged {
                if let last = deduped.last, r.date.timeIntervalSince(last.date) < 150 { continue }
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
            // Resume any glucose-refresh waiters so they don't hang across a disconnect (audit C-05).
            if glucoseReadInFlight || !glucoseWaiters.isEmpty { completeGlucoseRead() }
            // Resume every signed-flow continuation with an error + drop delivery writes (audit A-03).
            failPumpWaiters(BolusError.notConnected)
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
        case let m as ControlIQInfoV1Response:
            snapshot.controlIQEnabled = m.closedLoopEnabled
            snapshot.controlIQWeightLbs = m.weight
            snapshot.controlIQTotalDailyInsulin = m.totalDailyInsulin
        case let m as ProfileStatusResponse:
            profileActiveIdpId = m.activeIdpId
            snapshot.profiles = []
            for id in m.presentIdpIds where id >= 0 { try? client.send(IDPSettingsRequest(idpId: id)) }
        case let m as IDPSettingsResponse:
            snapshot.profiles.removeAll { $0.idpId == m.idpId }
            snapshot.profiles.append(PumpProfileInfo(idpId: m.idpId, name: m.name, active: m.idpId == profileActiveIdpId,
                                                     insulinDurationMinutes: m.insulinDuration))
            snapshot.profiles.sort { $0.idpId < $1.idpId }
            // When viewing a specific profile's segments, read each one.
            if m.idpId == viewedProfileId {
                for i in 0..<max(0, m.numberOfProfileSegments) { try? client.send(IDPSegmentRequest(idpId: m.idpId, segmentIndex: i)) }
            }
        case let m as IDPSegmentResponse where m.idpId == viewedProfileId:
            snapshot.viewedProfileSegments.removeAll { $0.segmentIndex == m.segmentIndex }
            snapshot.viewedProfileSegments.append(PumpProfileSegment(
                idpId: m.idpId, segmentIndex: m.segmentIndex, startTimeMinutes: m.profileStartTime,
                basalRateUnitsPerHour: Double(m.profileBasalRate) / 1000.0,
                carbRatioGramsPerUnit: Double(m.profileCarbRatio) / 1000.0,
                isf: m.profileISF, targetBg: m.profileTargetBG))
            snapshot.viewedProfileSegments.sort { $0.segmentIndex < $1.segmentIndex }
        case let m as CurrentEgvGuiDataV2Response:
            snapshot.cgmActive = m.hasValidReading
            snapshot.trend = m.trendArrow
            if m.hasValidReading {
                // Age must reflect the pump's OWN reading time, not when the phone happened to poll
                // it (which understated age and lagged the pump). Convert `bgReadingTimestampSeconds`
                // via the same phone↔pump clock anchor the LastBolus case uses (timezone-agnostic).
                // Fall back to receive time if there's no anchor yet or the timestamp looks bad.
                let now = Date()
                let readingDate = cgmReadingDate(pumpSec: m.bgReadingTimestampSeconds, now: now)
                snapshot.glucose = m.cgmReading
                snapshot.glucoseDate = readingDate
                // Append on a value change OR every ~4.5 min, so a stable BG still advances the
                // plot (a value-only de-dup left the newest point drifting into the past).
                if let last = glucoseHistory.last {
                    if last.mgdl != m.cgmReading || readingDate.timeIntervalSince(last.date) > 270 {
                        glucoseHistory.append(GlucoseReading(date: readingDate, mgdl: m.cgmReading))
                    }
                } else {
                    glucoseHistory.append(GlucoseReading(date: readingDate, mgdl: m.cgmReading))
                }
                if glucoseHistory.count > 288 { glucoseHistory.removeFirst() }
                // Predictive polling: as soon as the pump's reading timestamp advances, line up a
                // short burst near the next expected reading so the phone grabs it within seconds.
                if m.bgReadingTimestampSeconds > lastCgmPumpSec {
                    lastCgmPumpSec = m.bgReadingTimestampSeconds
                    schedulePredictiveBurst(afterReadingAt: readingDate)
                }
            }
            // Wake any coalesced `refreshGlucoseNow()` waiters now that a reading has arrived.
            if glucoseReadInFlight { completeGlucoseRead() }
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
        case let m as BasalLimitSettingsResponse:
            snapshot.maxBasalUnitsPerHour = m.basalLimitUnitsPerHour
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
        snapshot.connection = .disconnected
        // A transport error orphans any in-flight signed transaction — resume its waiters and drop
        // delivery writes so nothing hangs and the next connection starts read-only (audit A-03).
        if glucoseReadInFlight || !glucoseWaiters.isEmpty { completeGlucoseRead() }
        failPumpWaiters(error)
        onChange?()
    }
}
