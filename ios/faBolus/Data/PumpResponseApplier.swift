import Foundation
import faBolusCore
import TandemMessages
import os

/// Phase 09 Wave 4, Target B part 2 (D-07): the BLE read cascade's **response-application** side,
/// extracted verbatim out of `TandemBackend`'s `didReceiveFrame` delegate `switch`, behind the unchanged
/// `PumpBackend` seam. Owns every status-response APPLICATION case — the IDP cascade
/// (`ProfileStatusResponse`→`IDPSettingsRequest`→`IDPSegmentRequest`), the history cascade
/// (`TimeSinceResetResponse`→`HistoryLogStatusRequest`→`beginGapSync`→stream), the op-115/op-109
/// completion stamps (`ControlIQIOBResponse`/`BolusCalcDataSnapshotResponse`), `applyEgvReading`, and
/// every other snapshot-populating case — plus the notification/alert merge, dismiss-ack,
/// sleep-schedule write-error, and CGM-hardware-info continuation cases.
///
/// CRITICAL (D-07): this type contains NO `.authorization` branch and NEVER calls `coordinator?.handle`
/// or `ResponseParser.parse` — the pairing auth-CRC gate and the parse boundary stay in `TandemBackend`,
/// which hands this type only the ALREADY-PARSED `Message` for a non-pairing characteristic. The
/// coordinator-consumed-when-unsolicited cases (`LastBolusStatusV2Response`/`TimeSinceResetResponse`)
/// keep applying only the unsolicited-refresh path, exactly as they did inline (PX-08).
///
/// Depends ONLY on injected closures/providers (D-04 hook pattern, mirroring `PumpReadScheduler`/
/// `DeliveryLedgerCoordinator`) — never a whole-`TandemBackend` back-pointer: a `PumpSnapshot` mutation
/// sink, glucose/IOB history sinks, the outgoing `send(Message)` sink (same `tx`/`client.send` routing,
/// swallow-on-failure, as before), the `PumpReadScheduler` completion/scheduling hooks, the gap-sync
/// entry point + backfill-active accessor, the history-sync-state get/set, the alert-list
/// setters/`noteAlert`/`mergeNotifications`, the dismiss-ack setter/`renderDebug`, the calc-snapshot
/// setter, the sleep-schedule-write-error setter, the profile/time-anchor/model-detection accessors, and
/// the CGM-hardware-info continuation resolver. `var`s with safe no-op defaults, assigned by
/// `TandemBackend` as separate statements right after construction (Swift's two-phase init forbids a
/// `[weak self]`-capturing closure inside the very expression that initializes the property holding it —
/// the same pattern `PumpReadScheduler`/`DeliveryLedgerCoordinator`'s hooks use).
///
/// NO wire bytes, cascade order, or application logic changes (D-07) — every case below is a verbatim
/// move (including its fix-cycle doc-comment history) from `TandemBackend.swift`'s `didReceiveFrame`,
/// mechanically rewrapped only where a value-type (`PumpSnapshot`, the history arrays) required an
/// inject sink instead of direct field access.
@MainActor
final class PumpResponseApplier {
    /// Same subsystem/category as `TandemBackend.pairingLog` — declared separately (that constant is
    /// `private` to `TandemBackend`) so the merged `log show` timeline still shows this type's
    /// "pump error ←" line alongside every other pairing/read line TandemBackend logs.
    private static let pairingLog = Logger(subsystem: "com.fabolus.app", category: "ble")

    // MARK: - Injected seams (settable post-construction, D-04 hook pattern)

    /// Bound to a closure that mutates `TandemBackend.snapshot` in place (its setter is `private(set)`,
    /// so only code living in `TandemBackend.swift` — this wiring closure — can write it).
    var withSnapshot: ((inout PumpSnapshot) -> Void) -> Void = { _ in }
    /// Bound to a closure that mutates `TandemBackend.glucoseHistory` in place.
    var withGlucoseHistory: ((inout [GlucoseReading]) -> Void) -> Void = { _ in }
    /// Bound to a closure that mutates `TandemBackend.iobHistory` in place.
    var withIOBHistory: ((inout [IOBSample]) -> Void) -> Void = { _ in }
    /// Bound to `{ try? tx.send($0, authenticationKey: [], pumpTimeSinceReset: 0, allowInsulinDelivery: false) }`
    /// — the SAME swallow-on-failure `tx`/`client.send` routing every chained IDP/history request used
    /// inline before this move (incl. the `HistoryLogStatusRequest` gated on `AppSettings.historySyncEnabled`).
    var send: (Message) -> Void = { _ in }
    /// Bound to `readScheduler.noteCalcInputArrived(iob:)`.
    var noteCalcInputArrived: (Bool) -> Void = { _ in }
    /// Bound to `readScheduler.completeGlucoseRead()`.
    var completeGlucoseRead: () -> Void = {}
    /// Bound to `readScheduler.schedulePredictiveBurst(afterReadingAt:)`.
    var schedulePredictiveBurst: (Date) -> Void = { _ in }
    /// Bound to `readScheduler.cgmReadingDate(pumpSec:now:)`.
    var cgmReadingDate: (UInt32, Date) -> Date = { _, now in now }
    /// Bound to `readScheduler.insertBadOpcode(_:)`.
    var insertBadOpcode: (UInt8) -> Void = { _ in }
    /// Bound to `TandemBackend.beginGapSync(pumpFirst:pumpLast:)`.
    var beginGapSync: (UInt32, UInt32) -> Void = { _, _ in }
    /// Bound to `{ backfillActive }`.
    var isBackfillActive: () -> Bool = { false }
    /// Bound to a closure that appends one history-log stream frame's records into the backfill buffers
    /// and (re)schedules the stream-end debounce — moved verbatim as one TandemBackend-owned action
    /// (rather than exposing the three backfill buffer arrays individually), since it's tightly coupled
    /// to the rest of the (unmoved, D-07) gap-sync paging machinery.
    var appendHistoryStreamFrame: (HistoryLogStreamResponse) -> Void = { _ in }
    /// Bound to `{ historySyncState }`.
    var historySyncState: () -> HistorySyncState = { .idle(lastSynced: nil) }
    /// Bound to `{ historySyncState = $0 }`.
    var setHistorySyncState: (HistorySyncState) -> Void = { _ in }
    /// Bound to `{ historyStatusRequestedThisConnection }` — shared with `applyTimeResponse` (the
    /// coordinator-consumed path, which stays in `TandemBackend`).
    var historyStatusRequestedThisConnection: () -> Bool = { false }
    /// Bound to `{ historyStatusRequestedThisConnection = $0 }`.
    var setHistoryStatusRequestedThisConnection: (Bool) -> Void = { _ in }
    /// Bound to `{ pumpTimeAnchor }` — shared with `applyTimeResponse` and `readScheduler`'s own
    /// `pumpTimeAnchor` read hook.
    var pumpTimeAnchor: () -> (pump: UInt32, phone: Date)? = { nil }
    /// Bound to `{ pumpTimeAnchor = $0 }`.
    var setPumpTimeAnchor: ((pump: UInt32, phone: Date)) -> Void = { _ in }
    /// Bound to `{ viewedProfileId }` — set elsewhere (`refreshProfileSegments`), read-only here.
    var viewedProfileId: () -> Int = { -1 }
    /// Bound to `{ detectedIsMobi }` — set at BLE-name discovery, read-only here.
    var detectedIsMobi: () -> Bool? = { nil }
    /// Bound to `{ pumpFeatureBits = $0 }`.
    var setPumpFeatureBits: (PumpFeatureBits) -> Void = { _ in }
    /// Bound to `{ calcSnapshot = $0 }` — read elsewhere (the dose-calculator path).
    var setCalcSnapshot: (BolusCalcDataSnapshotResponse) -> Void = { _ in }
    /// Bound to `{ sleepScheduleWriteError = $0 }`.
    var setSleepScheduleWriteError: (String?) -> Void = { _ in }
    // Alert-list setters: `alertList`/`alarmList`/`cgmAlertList`/`reminderList`/`malfunctionList` are
    // each read elsewhere by `mergeNotifications`/dismiss handling, which stay in `TandemBackend`.
    var setAlertList: ([PumpNotification]) -> Void = { _ in }
    var setAlarmList: ([PumpNotification]) -> Void = { _ in }
    var setCGMAlertList: ([PumpNotification]) -> Void = { _ in }
    var setReminderList: ([PumpNotification]) -> Void = { _ in }
    var setMalfunctionList: ([PumpNotification]) -> Void = { _ in }
    /// Bound to `TandemBackend.noteAlert(_:_:)`.
    var noteAlert: (String, UInt64) -> Void = { _, _ in }
    /// Bound to `TandemBackend.mergeNotifications()`.
    var mergeNotifications: () -> Void = {}
    /// Bound to `{ lastDismissAck = $0 }`.
    var setLastDismissAck: (String) -> Void = { _ in }
    /// Bound to `TandemBackend.renderDebug()`.
    var renderDebug: () -> Void = {}
    /// Bound to a closure resolving `TandemBackend.cgmHwCont` — mirrors the inline
    /// `if let c = cgmHwCont { cgmHwCont = nil; c.resume(returning: m) }` this case ran before the move.
    var resumeCGMHardwareInfoContinuation: (CGMHardwareInfoResponse) -> Void = { _ in }

    // MARK: - State exclusively owned by the moved cascades (D-07: never read/written outside them)

    /// Active IDP id from the last `ProfileStatus` read, to flag the active profile as `IDPSettings`
    /// arrive. Moved verbatim — used only by the two IDP-cascade cases below.
    private var profileActiveIdpId = -1
    /// Latest CGM reading time seen from the pump (its own clock), used by `applyEgvReading` to detect a
    /// *new* reading (Bug 5). Moved verbatim — used only by `applyEgvReading`; its
    /// reset-on-fresh-connection-cycle still runs via `readScheduler`'s injected
    /// `onStartPollingCycleBegin` hook, now retargeted at `resetCycleState()` below (Phase 09 Wave 4).
    private var lastCgmPumpSec: UInt32 = 0
    /// E8: once the pump's OWN `HomeScreenMirrorResponse` trend arrow has ever landed, `applyEgvReading`'s
    /// client-derived fallback retires permanently. Moved verbatim — used only by these two cases.
    private var pumpTrendEverReceived = false

    /// Reset the fresh-connection-cycle state this type owns (Phase 09 Wave 3, D-06's
    /// `onStartPollingCycleBegin` hook — retargeted here in Wave 4 since `lastCgmPumpSec` moved with
    /// `applyEgvReading`).
    func resetCycleState() { lastCgmPumpSec = 0 }

    // MARK: - Entry point

    /// Apply one already-parsed, non-pairing pump message (D-07). `TandemBackend.didReceiveFrame` calls
    /// this with `parsed.message` after its `.authorization` CRC gate + `ResponseParser.parse` boundary —
    /// both stay there, untouched.
    func apply(_ message: Message) {
        switch message {
        case let m as ControlIQIOBResponse:
            withSnapshot { snap in
                snap.iobUnits = m.iobUnits
                // DIF-core: stamp the receive time so the dose path can prove the active-insulin term is
                // fresh (mirrors `glucoseDate`).
                snap.iobDate = Date()
            }
            // Wake any coalesced `refreshCalcInputsNow()` waiter once both the IOB (op-109) and therapy
            // (op-115) frames have landed since the refresh began.
            noteCalcInputArrived(true)
            // Accumulate an IOB time series (append on change or every ~4.5 min) for the chart.
            let now = Date()
            withIOBHistory { history in
                if let last = history.last {
                    if abs(last.iob - m.iobUnits) > 0.001 || now.timeIntervalSince(last.date) > 270 {
                        history.append(IOBSample(date: now, iob: m.iobUnits))
                    }
                } else { history.append(IOBSample(date: now, iob: m.iobUnits)) }
                if history.count > 288 { history.removeFirst() }
            }
        case let m as InsulinStatusResponse:
            withSnapshot { $0.reservoirUnits = Double(m.currentInsulinAmount) }
        case let m as CurrentBatteryV2Response:
            withSnapshot { $0.batteryPercent = m.batteryPercent }
        case let m as CGMStatusResponse:
            withSnapshot { $0.cgmSessionActive = m.sessionActive }
        case let m as LoadStatusResponse:
            withSnapshot { snap in
                snap.cartridgeLoadState = m.loadStateId
                snap.cartridgeLoadActive = m.isLoadingActive
            }
        case let m as ControlIQInfoV1Response:
            withSnapshot { snap in
                snap.controlIQEnabled = m.closedLoopEnabled
                snap.controlIQWeightLbs = m.weight
                snap.controlIQTotalDailyInsulin = m.totalDailyInsulin
            }
        case let m as ControlIQSleepScheduleResponse:
            // Universal read (Phase 09.10 D-04) — decode-boundary projection into faBolusCore's
            // neutral PumpSleepScheduleSlot; TandemKit's SleepSchedule never crosses this boundary.
            withSnapshot { snap in
                snap.sleepSchedules = m.schedules.enumerated().map { i, s in
                    PumpSleepScheduleSlot(slot: i, enabled: s.enabled, activeDays: s.activeDays,
                                          startMinute: s.startTime, endMinute: s.endTime)
                }
            }
        case let m as SetSleepScheduleResponse:
            // Write ack (Phase 09.10 D-04). No optimistic mutation of `snapshot.sleepSchedules` — a
            // follow-up `refreshSleepSchedule()` reflects the actual pump state, mirroring `setControlIQ`.
            // Copy fixed by UI-SPEC's Copywriting Contract; consumed one-shot by `AppModel.setSleepSchedule`.
            if m.status != 0 {
                setSleepScheduleWriteError("The pump rejected the sleep-schedule change (status \(m.status)).")
            }
        case let m as ProfileStatusResponse:
            profileActiveIdpId = m.activeIdpId
            withSnapshot { $0.profiles = [] }
            // Phase 09.2 Task 3 (D-01, gap B3): routed through `tx` (== `client` in production, since
            // `injectedTransport` is always nil outside tests — byte-identical wire behavior) instead of
            // `client` directly, so a test can inject a `ProfileStatusResponse` via `FakePumpTransport` and
            // observe the resulting `IDPSettingsRequest` cascade via `fake.sent` — the same pattern already
            // used one case below for `HistoryLogStatusRequest`. No other behavior changes: same defaults
            // (`authenticationKey: []`, `pumpTimeSinceReset: 0`, `allowInsulinDelivery: false`) `client.send`
            // itself used, same per-id loop/order, same `try?` swallow-on-failure.
            for id in m.presentIdpIds where id >= 0 {
                send(IDPSettingsRequest(idpId: id))
            }
        case let m as IDPSettingsResponse:
            withSnapshot { snap in
                snap.profiles.removeAll { $0.idpId == m.idpId }
                snap.profiles.append(PumpProfileInfo(idpId: m.idpId, name: m.name, active: m.idpId == profileActiveIdpId,
                                                     insulinDurationMinutes: m.insulinDuration))
                snap.profiles.sort { $0.idpId < $1.idpId }
            }
            // When viewing a specific profile's segments, read each one. Same `tx`-routing note as the
            // `ProfileStatusResponse` case above (gap B3).
            if m.idpId == viewedProfileId() {
                for i in 0..<max(0, m.numberOfProfileSegments) {
                    send(IDPSegmentRequest(idpId: m.idpId, segmentIndex: i))
                }
            }
        case let m as IDPSegmentResponse where m.idpId == viewedProfileId():
            withSnapshot { snap in
                snap.viewedProfileSegments.removeAll { $0.segmentIndex == m.segmentIndex }
                snap.viewedProfileSegments.append(PumpProfileSegment(
                    idpId: m.idpId, segmentIndex: m.segmentIndex, startTimeMinutes: m.profileStartTime,
                    basalRateUnitsPerHour: Double(m.profileBasalRate) / 1000.0,
                    carbRatioGramsPerUnit: Double(m.profileCarbRatio) / 1000.0,
                    isf: m.profileISF, targetBg: m.profileTargetBG))
                snap.viewedProfileSegments.sort { $0.segmentIndex < $1.segmentIndex }
            }
        case let m as HomeScreenMirrorResponse:
            // C8 / defect E8: the trend comes from the PUMP, not from us. This is the icon the pump is
            // showing on its own home screen, so it cannot disagree with the pump — including its
            // explicit "no arrow" state, which a client-side derivation from `trendRate` cannot express.
            withSnapshot { $0.trend = m.cgmTrendArrow }
            pumpTrendEverReceived = true   // E8: the pump's trend channel is now authoritative — retire the fallback

        case let m as CurrentEGVGuiDataResponse:
            // SEVENTH fix cycle (`.planning/debug/pump-pairing-loop.md`, on-device capture #6): the
            // response to the V1 `CurrentEGVGuiDataRequest` (op34) `fastRead()`/`refreshGlucoseNow()`/
            // `runPredictiveBurst()` now send exclusively — see `fastRead()`'s doc comment for why V2
            // (op192) is never sent. This case was MISSING when the V1 send sites were introduced: the
            // kit parses op35 (`ResponseParser.swift`) and delivers it here, but with no case it fell
            // through to `default: break`, so every CGM reading was silently discarded. Shares one
            // applier with the V2 case below, since both responses carry identical cargo semantics.
            applyEgvReading(hasValidReading: m.hasValidReading,
                            cgmReading: m.cgmReading,
                            pumpSec: UInt32(truncatingIfNeeded: m.bgReadingTimestampSeconds),
                            derivedTrendArrow: m.trendArrow)
        case let m as CurrentEgvGuiDataV2Response:
            // Defensive only: the app never sends `CurrentEgvGuiDataV2Request` (op192) itself — see
            // `fastRead()`'s doc comment — but keeps this case in case a V2 frame ever arrives
            // unsolicited, so it's applied rather than silently dropped.
            applyEgvReading(hasValidReading: m.hasValidReading,
                            cgmReading: m.cgmReading,
                            pumpSec: m.bgReadingTimestampSeconds,
                            derivedTrendArrow: m.trendArrow)
        case let m as LastBolusStatusV2Response:
            // PX-08: normally consumed by the coordinator (awaited via `lastBolusStatus()`); this delegate
            // path only fires for an UNSOLICITED last-bolus frame, for which we still refresh the snapshot.
            withSnapshot { snap in
                snap.lastBolusUnits = m.deliveredUnits
                if let a = pumpTimeAnchor() {
                    snap.lastBolusDate = a.phone.addingTimeInterval(Double(Int64(m.timestamp) - Int64(a.pump)))
                }
            }
        case let m as DismissNotificationResponse:
            setLastDismissAck("ack \(m.status)\(m.status == 0 ? " (accepted)" : " (rejected)")")
            renderDebug()
        case let m as BolusCalcDataSnapshotResponse:
            setCalcSnapshot(m)
            withSnapshot { snap in
                if m.maxBolusAmount > 0 { snap.maxBolusUnits = Double(m.maxBolusAmount) / 1000.0 }
                snap.carbRatio = m.carbRatioGramsPerUnit
                snap.isf = m.isf
                snap.targetBg = m.targetBg
                // DIF-core: stamp the receive time (one op-115 frame resolves the active profile+segment
                // to a self-consistent CR/ISF/target set).
                snap.therapyParamsDate = Date()
            }
            // Wake a coalesced `refreshCalcInputsNow()` waiter.
            noteCalcInputArrived(false)
        case let m as TimeSinceResetResponse:
            // PX-08: awaited time responses are consumed by the coordinator (side-effects applied in
            // `applyTimeResponse`); this handles any unsolicited time frame.
            setPumpTimeAnchor((m.currentTime, Date()))
            if !historyStatusRequestedThisConnection() {
                setHistoryStatusRequestedThisConnection(true)
                // D-01: same auto-sync gate as `applyTimeResponse` — this handles an UNSOLICITED time
                // frame, but the toggle governs both paths identically.
                if AppSettings.shared.historySyncEnabled {
                    send(HistoryLogStatusRequest())
                }
            }
        case let m as HistoryLogStatusResponse:
            guard !isBackfillActive() else { break }
            guard m.numEntries > 0 else {
                // D-05: resolve an optimistic `.syncing` (set by `triggerManualHistorySync` before this
                // response landed) back to idle when the pump reports nothing at all yet — otherwise a
                // manual "Sync now" against a brand-new pump would leave the busy spinner stuck forever.
                if case .syncing = historySyncState() {
                    setHistorySyncState(.idle(lastSynced: AppSettings.shared.historyLastSyncedAt))
                }
                break
            }
            beginGapSync(m.firstSequenceNum, m.lastSequenceNum)
        case let m as HistoryLogStreamResponse:
            guard isBackfillActive() else { break }
            appendHistoryStreamFrame(m)
        case let m as AlertStatusResponse:
            setAlertList(m.notifications); noteAlert("al", m.bitmap); mergeNotifications()
        case let m as AlarmStatusResponse:
            setAlarmList(m.notifications); noteAlert("am", m.bitmap); mergeNotifications()
        case let m as CGMAlertStatusResponse:
            setCGMAlertList(m.notifications); noteAlert("c", m.bitmap); mergeNotifications()
        case let m as ReminderStatusResponse:
            setReminderList(m.notifications); noteAlert("r", m.bitmap); mergeNotifications()
        case let m as MalfunctionBitmaskStatusResponse:
            setMalfunctionList(m.notifications); noteAlert("m", m.bitmap); mergeNotifications()
        // PX-08: BolusPermission / InitiateBolus / CurrentBolusStatus responses are consumed by the
        // transaction coordinator (awaited in `perform`), so they no longer need a delegate case here.
        // Workstream B: pump model + basal + Control-IQ status.
        case let m as ApiVersionResponse:
            withSnapshot { snap in
                snap.softwareVersion = "\(m.majorVersion).\(m.minorVersion)"
                // The BLE name (set at discovery) is authoritative for the model. Only fall back to the
                // API-version heuristic if the name didn't identify it (e.g. name was unavailable).
                if detectedIsMobi() == nil {
                    snap.isMobi = m.isMobi
                    snap.pumpModelName = m.isMobi ? "Mobi" : "t:slim X2"
                    PumpModelStore.set(isMobi: m.isMobi)
                }
                snap.softwareVersion = "\(m.majorVersion).\(m.minorVersion)"
            }
        case let m as ErrorResponse:
            // SEVENTH fix cycle (`.planning/debug/pump-pairing-loop.md`, on-device capture #6): the
            // pump replies with this when it rejects a request (e.g. BAD_OPCODE for an unsupported
            // opcode) — previously silently discarded by `default: break`, which is exactly why the
            // pump's own explanation for the teardown that followed was invisible on-device. PHI-safe:
            // requestCodeId/errorCodeId are protocol tokens (an opcode 0-255 and a small error-code
            // enum ordinal), never payload/PHI. Logged PERMANENTLY (standing diagnostic, not
            // debug-session scaffolding) so any FUTURE unsupported-opcode rejection on any pump is
            // immediately visible, not just this session's op192 case.
            let badOpcode = UInt8(truncatingIfNeeded: m.requestCodeId)
            insertBadOpcode(badOpcode)
            Self.pairingLog.log("pump error ← requestOpcode=\(badOpcode, privacy: .public) errorCode=\(m.errorCodeId, privacy: .public) badOpcode=\(m.isBadOpcode, privacy: .public) — will not resend this opcode")
        case let m as PumpFeaturesV1Response:
            // P13: cache the pump's own capability bitmask; `capabilities` derives from it (narrowing
            // the model preset). Registered in the kit's ResponseParser (op 79/.currentStatus), so it
            // arrives here with no extra wiring.
            let bits = TandemBackend.featureBits(from: m)
            setPumpFeatureBits(bits)
            // P13c: surface the controller variant (CIQ vs CIQ+, O7) on the snapshot so the controller
            // descriptor is reachable from pump state. Identity only — no capability gate reads it.
            withSnapshot { $0.controllerVariant = bits.controllerVariant }
        case let m as CurrentBasalStatusResponse:
            withSnapshot { $0.basalRateUnitsPerHour = m.currentBasalUnitsPerHour }
        case let m as BasalLimitSettingsResponse:
            withSnapshot { $0.maxBasalUnitsPerHour = m.basalLimitUnitsPerHour }
        case let m as ControlIQInfoV2Response:
            withSnapshot { snap in
                snap.controlIQMode = m.currentUserModeType
                snap.controlIQEnabled = m.closedLoopEnabled
            }
        case let m as CGMHardwareInfoResponse:
            resumeCGMHardwareInfoContinuation(m)
        case let m as SuspendPumpingResponse:
            if m.accepted { withSnapshot { $0.deliverySuspended = true } }
        case let m as ResumePumpingResponse:
            if m.accepted { withSnapshot { $0.deliverySuspended = false } }
        default: break
        }
    }

    // MARK: - Helpers moved with the cascades

    // MARK: - CGM reading application (Bug 5)

    /// Apply one decoded EGV reading to the snapshot/history/predictive-burst state.
    ///
    /// SEVENTH fix cycle: shared by BOTH `CurrentEGVGuiDataResponse` (op35, the V1 request `fastRead()`
    /// now sends exclusively — see its doc comment) and `CurrentEgvGuiDataV2Response` (op193, kept as a
    /// defensive parse case in case an unsolicited V2 frame ever arrives, though the app itself never
    /// requests it). The two responses carry identical cargo semantics, so the behaviour must not
    /// diverge by which one is handled; one applier makes that structural rather than a convention two
    /// `case` blocks have to keep in sync.
    private func applyEgvReading(hasValidReading: Bool,
                                 cgmReading: Int,
                                 pumpSec: UInt32,
                                 derivedTrendArrow: String?) {
        withSnapshot { snap in
            snap.cgmActive = hasValidReading
            // Fallback only, and only until the first HomeScreenMirror trend is EVER received: never
            // overwrite the pump's own arrow with a derived one — including its explicit "no arrow" ("")
            // (E8: the old `snapshot.trend.isEmpty`-only guard conflated "pump says no arrow" with "not
            // polled yet", so a derived arrow overwrote the pump's authoritative empty). And never invent
            // one when the rate is unknown (an INVALID/UNAVAILABLE frame carries a sentinel rate).
            if !pumpTrendEverReceived, snap.trend.isEmpty, let derived = derivedTrendArrow { snap.trend = derived }
        }
        if hasValidReading {
            // Age must reflect the pump's OWN reading time, not when the phone happened to poll
            // it (which understated age and lagged the pump). Convert `bgReadingTimestampSeconds`
            // via the same phone↔pump clock anchor the LastBolus case uses (timezone-agnostic).
            // Fall back to receive time if there's no anchor yet or the timestamp looks bad.
            let now = Date()
            let readingDate = cgmReadingDate(pumpSec, now)
            withSnapshot { snap in
                snap.glucose = cgmReading
                snap.glucoseDate = readingDate
            }
            // Append on a value change OR every ~4.5 min, so a stable BG still advances the
            // plot (a value-only de-dup left the newest point drifting into the past).
            withGlucoseHistory { history in
                if let last = history.last {
                    if last.mgdl != cgmReading || readingDate.timeIntervalSince(last.date) > 270 {
                        history.append(GlucoseReading(date: readingDate, mgdl: cgmReading))
                    }
                } else {
                    history.append(GlucoseReading(date: readingDate, mgdl: cgmReading))
                }
                if history.count > 288 { history.removeFirst() }
            }
            // Predictive polling: as soon as the pump's reading timestamp advances, line up a
            // short burst near the next expected reading so the phone grabs it within seconds.
            if pumpSec > lastCgmPumpSec {
                lastCgmPumpSec = pumpSec
                schedulePredictiveBurst(readingDate)
            }
        }
        // Wake any coalesced `refreshGlucoseNow()` waiters now that a reading has arrived. Unconditional
        // (no outer `if glucoseReadInFlight` guard — that flag is private to `readScheduler`;
        // `completeGlucoseRead()` is a no-op when nothing is in flight, so this is behavior-identical).
        completeGlucoseRead()
    }
}
