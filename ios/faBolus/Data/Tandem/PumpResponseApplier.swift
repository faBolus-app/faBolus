import Foundation
import faBolusCore
import TandemMessages
import os

/// BLE read cascade **response-application** side. Owns every status-response APPLICATION case.
/// Contains NO `.authorization` branch and NEVER calls `coordinator?.handle` or `ResponseParser.parse`
/// — the pairing auth-CRC gate and the parse boundary stay in `TandemBackend`. Depends only on
/// injected closures — never a whole-`TandemBackend` back-pointer. No wire bytes, cascade order, or
/// application logic changes.
@MainActor
final class PumpResponseApplier {
    /// Same subsystem/category as `TandemBackend.pairingLog` — declared separately (that constant is
    /// `private` to `TandemBackend`) so the merged `log show` timeline still shows this type's
    /// "pump error ←" line alongside every other pairing/read line TandemBackend logs.
    private static let pairingLog = Logger(subsystem: "com.fabolus.app", category: "ble")

    // MARK: - Injected seams (settable post-construction)

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
    /// Bound to `readScheduler.cgmReadingDate(pumpSec:now:)`. `nil` ⇒ the reading time is untrustworthy.
    var cgmReadingDate: (UInt32, Date) -> Date? = { _, _ in nil }
    /// Bound to `readScheduler.resolveErrorResponse(requestCodeId:errorCodeId:txId:)`. Resolves an
    /// inbound op77 `ErrorResponse` to the true failing opcode — the cargo's `requestCodeId` when the
    /// pump names it, else the outstanding read correlated by the echoed txId (frame[1]) — records it
    /// in the never-resend `badOpcodes` set, and returns it for the diagnostic log (0 when
    /// unresolvable, so opcode 0 is never suppressed). Default trusts the cargo, used only before
    /// wiring.
    ///
    /// `errorCodeId` is passed through because it decides whether the exclusion may be made DURABLE:
    /// only `BAD_OPCODE(6)` is a statement about opcode support, so a transient error must not
    /// permanently delete a working read (debug session `tslim-reservoir-battery-zero` — five ordinary
    /// reads were lost that way on a brand-new t:slim X2). See `PumpErrorClass`.
    var resolveBadOpcodeForError: (_ requestCodeId: Int, _ errorCodeId: Int, _ txId: UInt8) -> UInt8 = {
        requestCodeId, _, _ in
        UInt8(truncatingIfNeeded: requestCodeId)
    }
    /// Bound to `TandemBackend.beginGapSync(pumpFirst:pumpLast:)`.
    var beginGapSync: (UInt32, UInt32) -> Void = { _, _ in }
    /// Bound to `{ backfillActive }`.
    var isBackfillActive: () -> Bool = { false }
    /// Bound to a closure that appends one history-log stream frame's records into the backfill
    /// buffers and (re)schedules the stream-end debounce — one TandemBackend-owned action rather
    /// than exposing the three backfill buffer arrays individually.
    var appendHistoryStreamFrame: (HistoryLogStreamResponse) -> Void = { _ in }
    /// Notified for EVERY incoming `HistoryLogStreamResponse` frame, unconditionally — unlike
    /// `appendHistoryStreamFrame`, this is NOT gated on `isBackfillActive()`.
    /// `TandemBackend.findBolusInHistory(bolusId:)` issues its own `HistoryLogRequest` pages
    /// independently of the routine gap-sync state machine, so it needs an always-fires observation
    /// point. Default no-op so a bare applier is unchanged.
    var historyStreamFrameObserved: (HistoryLogStreamResponse) -> Void = { _ in }
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
    /// Called once the bootstrap `ApiVersionResponse` (op33) has populated pump identity
    /// (`snapshot.isMobi` + `softwareVersion`), so `PumpReadScheduler` can consult the static
    /// `PumpKnownUnsupportedReads` registry and dispatch deferred identity-gated reads —
    /// suppressing op20 BEFORE the first send on a known-bad combo. Default no-op.
    var noteBootstrapVersionIdentified: () -> Void = {}
    /// Re-wire the kit's device-support MODEL gate (`client.setDeviceContext(model:)`) every
    /// connection cycle once op33 has identified the pump. `setDeviceContext` resets to nil on
    /// every link change and `didDiscover` does NOT re-fire on a silent reconnect, so op33 is
    /// the robust per-cycle re-wire point.
    ///
    /// `trusted` is computed at the op33 call site from `detectedIsMobi() != nil` (name available
    /// this cycle, whether from a fresh `didDiscover` OR from
    /// `PumpConnectionLifecycle.reapplyTrustedIdentityIfKnown()`) BEFORE this closure is called,
    /// so the op33 API-version heuristic itself is NEVER forwarded as trusted.
    ///
    /// Signature is `(isMobi, apiVersion, trusted)`. The real negotiated `ApiVersion` op33 just
    /// reported is forwarded so the kit's `MessageProps.minApi` floors actually bite (they were
    /// inert while apiVersion stayed nil / fail-open). Blast radius is fail-safe: every auto-sent
    /// read is unrestricted EXCEPT op20 LoadStatus (already statically suppressed on the API-2.5
    /// t:slim; below-floor elsewhere it no-sends → cartridgeReadiness discloses `.unknown`).
    /// Mobi (API ≥ 3.5) passes all its reads. Default no-op.
    var applyDeviceContext: (Bool, ApiVersion?, Bool) -> Void = { _, _, _ in }
    /// Bound to `{ pumpFeatureBits = $0 }`.
    var setPumpFeatureBits: (PumpFeatureBits) -> Void = { _ in }
    /// Bound to `{ calcSnapshot = $0 }` — read elsewhere (the dose-calculator path).
    var setCalcSnapshot: (BolusCalcDataSnapshotResponse) -> Void = { _ in }
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

    // MARK: - State exclusively owned by the moved cascades

    /// Active IDP id from the last `ProfileStatus` read, to flag the active profile as `IDPSettings`
    /// arrive. Used only by the two IDP-cascade cases below.
    private var profileActiveIdpId = -1
    /// Latest CGM reading time seen from the pump (its own clock), used by `applyEgvReading` to
    /// detect a *new* reading. Reset on a fresh connection cycle via `readScheduler`'s
    /// `onStartPollingCycleBegin` hook, retargeted at `resetCycleState()`.
    private var lastCgmPumpSec: UInt32 = 0
    /// Once the pump's own `HomeScreenMirrorResponse` trend arrow has ever landed,
    /// `applyEgvReading`'s client-derived fallback retires permanently.
    private var pumpTrendEverReceived = false

    /// Reset the fresh-connection-cycle state this type owns (`lastCgmPumpSec` lives with
    /// `applyEgvReading`).
    func resetCycleState() { lastCgmPumpSec = 0 }

    // MARK: - Entry point

    /// Apply one already-parsed, non-pairing pump message. `TandemBackend.didReceiveFrame` calls this
    /// with `parsed.message` after its `.authorization` CRC gate + `ResponseParser.parse` boundary —
    /// both stay there. `txId` is `parsed.txId` (frame[1]); consumed only by the op77 `ErrorResponse`
    /// correlation backstop and ignored by every other case.
    ///
    /// `characteristic` is the BLE characteristic the frame arrived on. Consumed ONLY by the op77
    /// case: the pinned kit registers `ErrorResponse` on BOTH `.currentStatus` and `.control`, so a
    /// NACKed control/delivery WRITE's op77 also reaches this method on `.opcodeFIFO` pumps
    /// (Mobi/default). Such a `.control` op77 says NOTHING about read support and must NEVER mutate
    /// the read-only `badOpcodes` set — only a `.currentStatus` op77 (a rejected READ) is correlated
    /// + recorded. Every other case ignores it.
    func apply(_ message: Message, txId: UInt8, characteristic: Characteristic) {
        switch message {
        case let m as ControlIQIOBResponse:
            withSnapshot { snap in
                snap.iobUnits = m.iobUnits
                // Stamp receive time so the dose path can prove the active-insulin term is fresh
                // (mirrors `glucoseDate`).
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
                } else {
                    history.append(IOBSample(date: now, iob: m.iobUnits))
                }
                if history.count > 288 { history.removeFirst() }
            }
        case let m as InsulinStatusResponse:
            withSnapshot {
                $0.reservoirUnits = Double(m.currentInsulinAmount)
                // Stamp the read receipt so display can tell a GENUINE 0 (empty cartridge) from
                // "the pump never answered op-36" — which is exactly what a durably-excluded read
                // produced on the owner's t:slim X2 (debug `tslim-reservoir-battery-zero`).
                $0.reservoirDate = Date()
            }
        case let m as CurrentBatteryV2Response:
            withSnapshot { snap in
                snap.batteryPercent = m.batteryPercent
                // Read receipt — see `reservoirDate` above. Stamped on EVERY reply (not just the
                // first), matching `iobDate`'s last-received semantics.
                snap.batteryDate = Date()
                // Mirror the oracle's `isCharging()` — only a POSITIVE `chargingStatus == 1` reads as
                // charging; any other/unknown value fails closed to `false`. Unconditional assign
                // (never "if let"-preserved), same shape as `batteryPercent` on this same frame.
                snap.batteryCharging = (m.chargingStatus == 1)
            }
        case let m as CGMStatusResponse:
            withSnapshot { $0.cgmSessionActive = m.sessionActive }
        case let m as LoadStatusResponse:
            withSnapshot { snap in
                snap.cartridgeLoadState = m.loadStateId
                snap.cartridgeLoadActive = m.isLoadingActive
                // A genuine op-20 reply CONFIRMS cartridge state, so `cartridgeReadiness` can report
                // `.ready`/`.notReady` instead of the fail-open `.unknown` default. On a pump that
                // auto-excludes op-20 this line never runs, so readiness stays `.unknown` and the app
                // discloses it relies on the pump's own protection rather than presenting confirmed-ready.
                snap.cartridgeLoadStateConfirmed = true
            }
        case let m as ControlIQSleepScheduleResponse:
            // Universal read — decode-boundary projection into faBolusCore's
            // PumpSleepScheduleSlot; TandemKit's SleepSchedule never crosses this boundary.
            withSnapshot { snap in
                snap.sleepSchedules = m.schedules.enumerated().map { i, s in
                    PumpSleepScheduleSlot(
                        slot: i, enabled: s.enabled, activeDays: s.activeDays,
                        startMinute: s.startTime, endMinute: s.endTime)
                }
            }
        case let m as ProfileStatusResponse:
            profileActiveIdpId = m.activeIdpId
            withSnapshot { $0.profiles = [] }
            // Routed through `tx` (== `client` in production) instead of `client` directly, so a
            // test can inject a `ProfileStatusResponse` via `FakePumpTransport` and observe the
            // resulting `IDPSettingsRequest` cascade. Same defaults (`authenticationKey: []`,
            // `pumpTimeSinceReset: 0`, `allowInsulinDelivery: false`) `client.send` itself used.
            for id in m.presentIdpIds where id >= 0 {
                send(IDPSettingsRequest(idpId: id))
            }
        case let m as IDPSettingsResponse:
            withSnapshot { snap in
                snap.profiles.removeAll { $0.idpId == m.idpId }
                snap.profiles.append(
                    PumpProfileInfo(
                        idpId: m.idpId, name: m.name, active: m.idpId == profileActiveIdpId,
                        insulinDurationMinutes: m.insulinDuration))
                snap.profiles.sort { $0.idpId < $1.idpId }
            }
            // When viewing a specific profile's segments, read each one. Same `tx` routing as
            // the `ProfileStatusResponse` case above.
            if m.idpId == viewedProfileId() {
                for i in 0..<max(0, m.numberOfProfileSegments) {
                    send(IDPSegmentRequest(idpId: m.idpId, segmentIndex: i))
                }
            }
        case let m as IDPSegmentResponse where m.idpId == viewedProfileId():
            withSnapshot { snap in
                snap.viewedProfileSegments.removeAll { $0.segmentIndex == m.segmentIndex }
                snap.viewedProfileSegments.append(
                    PumpProfileSegment(
                        idpId: m.idpId, segmentIndex: m.segmentIndex, startTimeMinutes: m.profileStartTime,
                        basalRateUnitsPerHour: Double(m.profileBasalRate) / 1000.0,
                        carbRatioGramsPerUnit: Double(m.profileCarbRatio) / 1000.0,
                        isf: m.profileISF, targetBg: m.profileTargetBG))
                snap.viewedProfileSegments.sort { $0.segmentIndex < $1.segmentIndex }
            }
        case let m as HomeScreenMirrorResponse:
            // Trend comes from the PUMP, not from us. This is the icon the pump is showing on its
            // own home screen, so it cannot disagree with the pump — including its explicit "no
            // arrow" state, which a client-side derivation from `trendRate` cannot express.
            withSnapshot { $0.trend = m.cgmTrendArrow }
            pumpTrendEverReceived = true  // pump's trend channel is now authoritative — retire the fallback

        case let m as CurrentEGVGuiDataResponse:
            // Response to the V1 `CurrentEGVGuiDataRequest` (op34) that `fastRead()` /
            // `refreshGlucoseNow()` / `runPredictiveBurst()` send exclusively — see `fastRead()`'s
            // doc comment for why V2 (op192) is never sent. Without this case the kit still parses
            // op35 and delivers it here, but it would fall through to `default: break` and every
            // CGM reading would be silently discarded. Shares one applier with the V2 case below;
            // both responses carry identical cargo semantics.
            applyEgvReading(
                hasValidReading: m.hasValidReading,
                cgmReading: m.cgmReading,
                pumpSec: UInt32(truncatingIfNeeded: m.bgReadingTimestampSeconds),
                derivedTrendArrow: m.trendArrow)
        case let m as CurrentEgvGuiDataV2Response:
            // Defensive only: the app never sends `CurrentEgvGuiDataV2Request` (op192) itself — see
            // `fastRead()`'s doc comment — but keeps this case in case a V2 frame ever arrives
            // unsolicited, so it's applied rather than silently dropped.
            applyEgvReading(
                hasValidReading: m.hasValidReading,
                cgmReading: m.cgmReading,
                pumpSec: m.bgReadingTimestampSeconds,
                derivedTrendArrow: m.trendArrow)
        case let m as LastBolusStatusV2Response:
            // Normally consumed by the coordinator (awaited via `lastBolusStatus()`); this path
            // only fires for an unsolicited last-bolus frame, for which we still refresh the snapshot.
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
                // Stamp receive time (one op-115 frame resolves the active profile+segment
                // to a self-consistent CR/ISF/target set).
                snap.therapyParamsDate = Date()
            }
            // Wake a coalesced `refreshCalcInputsNow()` waiter.
            noteCalcInputArrived(false)
        case let m as TimeSinceResetResponse:
            // Awaited time responses are consumed by the coordinator (side-effects applied in
            // `applyTimeResponse`); this handles any unsolicited time frame.
            setPumpTimeAnchor((m.currentTime, Date()))
            if !historyStatusRequestedThisConnection() {
                setHistoryStatusRequestedThisConnection(true)
                // Same auto-sync gate as `applyTimeResponse` — this handles an unsolicited time
                // frame, but the toggle governs both paths identically.
                if AppSettings.shared.historySyncEnabled {
                    send(HistoryLogStatusRequest())
                }
            }
        case let m as HistoryLogStatusResponse:
            guard !isBackfillActive() else { break }
            guard m.numEntries > 0 else {
                // Resolve an optimistic `.syncing` (set by `triggerManualHistorySync` before this
                // response landed) back to idle when the pump reports nothing — otherwise a
                // "Sync now" against a brand-new pump would leave the spinner stuck forever.
                if case .syncing = historySyncState() {
                    setHistorySyncState(.idle(lastSynced: AppSettings.shared.historyLastSyncedAt))
                }
                break
            }
            beginGapSync(m.firstSequenceNum, m.lastSequenceNum)
        case let m as HistoryLogStreamResponse:
            // Observed unconditionally, independent of the routine backfill's active state —
            // see `historyStreamFrameObserved`'s doc comment.
            historyStreamFrameObserved(m)
            guard isBackfillActive() else { break }
            appendHistoryStreamFrame(m)
        case let m as AlertStatusResponse:
            setAlertList(m.notifications)
            noteAlert("al", m.bitmap)
            mergeNotifications()
        case let m as AlarmStatusResponse:
            setAlarmList(m.notifications)
            noteAlert("am", m.bitmap)
            mergeNotifications()
        case let m as CGMAlertStatusResponse:
            setCGMAlertList(m.notifications)
            noteAlert("c", m.bitmap)
            mergeNotifications()
        case let m as ReminderStatusResponse:
            setReminderList(m.notifications)
            noteAlert("r", m.bitmap)
            mergeNotifications()
        case let m as MalfunctionBitmaskStatusResponse:
            setMalfunctionList(m.notifications)
            noteAlert("m", m.bitmap)
            mergeNotifications()
        // BolusPermission / InitiateBolus / CurrentBolusStatus responses are consumed by the
        // transaction coordinator (awaited in `perform`), so they no longer need a delegate case here.
        // Pump model + basal + Control-IQ status.
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
            // Trust bit is computed HERE, before the fallback substitution below, from whether
            // the name is available THIS cycle (a fresh `didDiscover` OR a restore from
            // `reapplyTrustedIdentityIfKnown()`). The op33 API-version heuristic (`m.isMobi`,
            // used only when the name is unavailable) is ALWAYS forwarded UNTRUSTED, so it can
            // never satisfy the kit's trusted-identity send gate.
            let nameAvailableThisCycle = detectedIsMobi() != nil
            // Re-wire the MODEL gate AND supply the real negotiated apiVersion every connection
            // cycle (survives a silent reconnect where didDiscover doesn't re-fire). Same
            // major.minor op33 just reported — so the kit's minApi floors bite for THIS pump
            // instead of failing open on nil.
            applyDeviceContext(
                detectedIsMobi() ?? m.isMobi,
                ApiVersion(major: m.majorVersion, minor: m.minorVersion),
                nameAvailableThisCycle)
            // Pump is now IDENTIFIED (model class + firmware just written above), so the
            // scheduler can consult the static known-unsupported registry and dispatch deferred
            // identity-gated reads (op20) — suppressing op20 before the first send on the
            // known-bad t:slim X2 sw-2.5 combo. Called AFTER the snapshot write so the scheduler
            // reads the fresh identity. Idempotent per connection cycle (guarded scheduler-side).
            noteBootstrapVersionIdentified()
        case let m as ErrorResponse:
            // The pump replies with this when it rejects a request (e.g. BAD_OPCODE for an
            // unsupported opcode). Previously silently discarded by `default: break`, which hid
            // the pump's own explanation for the teardown that followed.
            //
            // Some pumps name the failing opcode in the cargo (`requestCodeId != 0`). The API-2.5
            // t:slim X2 answers an unsupported currentStatus read with a size-2 cargo of `[0,0]` —
            // NO opcode — so trusting the cargo recorded opcode 0 and the read was re-sent every
            // reconnect. `resolveBadOpcodeForError` recovers the true opcode by correlating the
            // error to the outstanding read (echoed request txId in frame[1], else in-order FIFO)
            // so the never-resend guard actually suppresses it — and never records opcode 0.
            // requestCodeId/errorCodeId/txId are protocol tokens, never payload/PHI. Logged
            // permanently so any future unsupported-opcode rejection is immediately visible.
            //
            // `badOpcodes` governs ONLY the `.currentStatus` READ path. The pinned kit also
            // registers `ErrorResponse` on `.control`, so a NACKed control/delivery WRITE's op77
            // reaches this case too on `.opcodeFIFO` pumps. Such a `.control` op77 identifies a
            // failing WRITE, which says nothing about read support — correlating it (whether by
            // the cargo's named opcode, which may collide with a supported read like op164/op144,
            // or by txId/FIFO against outstanding READS) would durably blacklist an innocent
            // supported read. Resolve + record only for `.currentStatus`; a `.control` op77 is
            // logged but never touches `badOpcodes`.
            if characteristic == .currentStatus {
                let resolved = resolveBadOpcodeForError(m.requestCodeId, m.errorCodeId, txId)
                Self.pairingLog.log(
                    "pump error ← requestOpcode=\(resolved, privacy: .public) errorCode=\(m.errorCodeId, privacy: .public) badOpcode=\(m.isBadOpcode, privacy: .public) — will not resend this opcode"
                )
            } else {
                // Diagnostic only — the pump rejected a control/delivery WRITE (or an error on another
                // characteristic); never a READ, so `badOpcodes` is left untouched.
                Self.pairingLog.log(
                    "pump error ← (\(characteristic.name, privacy: .public)) requestOpcode=\(m.requestCodeId, privacy: .public) errorCode=\(m.errorCodeId, privacy: .public) badOpcode=\(m.isBadOpcode, privacy: .public) — control/non-read error; read never-resend set untouched"
                )
            }
        case let m as PumpFeaturesV1Response:
            // Cache the pump's own capability bitmask; `capabilities` derives from it (narrowing
            // the model preset). Registered in the kit's ResponseParser (op 79/.currentStatus).
            let bits = TandemBackend.featureBits(from: m)
            setPumpFeatureBits(bits)
            // Surface the controller variant (CIQ vs CIQ+) on the snapshot so the controller
            // descriptor is reachable from pump state. Identity only — no capability gate reads it.
            withSnapshot { $0.controllerVariant = bits.controllerVariant }
        case let m as CurrentBasalStatusResponse:
            // Mark the basal rate as KNOWN so a genuine 0 U/hr (suspend / zero temp) renders as
            // "0/hr" rather than the unknown em-dash — the default 0 stays "unknown" until this
            // frame lands.
            withSnapshot {
                $0.basalRateUnitsPerHour = m.currentBasalUnitsPerHour
                $0.basalRateKnown = true
            }
        case let m as BasalLimitSettingsResponse:
            withSnapshot { $0.maxBasalUnitsPerHour = m.basalLimitUnitsPerHour }
        case let m as ControlIQInfoV2Response:
            withSnapshot { snap in
                snap.controlIQMode = m.currentUserModeType
                snap.controlIQEnabled = m.closedLoopEnabled
                // Zone words are Tandem's own labels; `controlStateType` is already decoded.
                // UNVERIFIED GUESS mapping, see `ControlIQZone.fromControlStateType` —
                // unmapped ⇒ nil ⇒ renders absent.
                snap.ciqZone = ControlIQZone.fromControlStateType(m.controlStateType)?.rawValue
                // Only assert a Control-IQ-attributed suspend when the pump's OWN control-state
                // says so. The start instant is captured ONCE at the transition into the
                // attributed state (never re-stamped on every subsequent op-179 read while it
                // stays true), mirroring glucoseDate's epoch-not-age convention. Unconditional
                // assign-or-clear — a stale `true` must never survive past the moment the pump's
                // own state actually changed.
                let attributed = ControlIQSuspendAttribution.isCiqAttributedSuspend(
                    controlStateType: m.controlStateType)
                if attributed {
                    if snap.ciqSuspendedForLow != true { snap.ciqSuspendStartDate = Date() }
                    snap.ciqSuspendedForLow = true
                } else {
                    snap.ciqSuspendedForLow = false
                    snap.ciqSuspendStartDate = nil
                }
            }
        default: break
        }
    }

    // MARK: - Helpers moved with the cascades

    // MARK: - CGM reading application

    /// Apply one decoded EGV reading to the snapshot/history/predictive-burst state.
    ///
    /// Shared by BOTH `CurrentEGVGuiDataResponse` (op35, the V1 request `fastRead()` now sends
    /// exclusively — see its doc comment) and `CurrentEgvGuiDataV2Response` (op193, kept as a
    /// defensive parse case in case an unsolicited V2 frame ever arrives, though the app itself
    /// never requests it). The two responses carry identical cargo semantics, so the behaviour
    /// must not diverge by which one is handled.
    private func applyEgvReading(
        hasValidReading: Bool,
        cgmReading: Int,
        pumpSec: UInt32,
        derivedTrendArrow: String?
    ) {
        withSnapshot { snap in
            snap.cgmActive = hasValidReading
            // Fallback only, and only until the first HomeScreenMirror trend is EVER received: never
            // overwrite the pump's own arrow with a derived one — including its explicit "no arrow" ("")
            // (the old `snapshot.trend.isEmpty`-only guard conflated "pump says no arrow" with "not
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
            let readingDate = cgmReadingDate(pumpSec, now)  // Date? — nil when untrusted
            withSnapshot { snap in
                snap.glucose = cgmReading
                snap.glucoseDate = readingDate  // nil ⇒ GlucoseFreshness.isStale == true (fail-closed for dosing)
            }
            // Append on a value change OR every ~4.5 min, so a stable BG still advances the
            // plot (a value-only de-dup left the newest point drifting into the past).
            // History/plot: only seed with a trustworthy reading time (an untrusted time must not be
            // promoted into the live snapshot via the plot history).
            if let readingDate {
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
            }
            // Predictive polling (a polling-cadence optimization, NOT a dose input): as soon as the
            // pump's reading timestamp advances, line up a short burst near the next expected reading
            // so the phone grabs it within seconds — falling back to `now` when the time is untrusted
            // so the phone keeps chasing a good reading.
            if pumpSec > lastCgmPumpSec {
                lastCgmPumpSec = pumpSec
                schedulePredictiveBurst(readingDate ?? now)
            }
        }
        // Wake any coalesced `refreshGlucoseNow()` waiters now that a reading has arrived. Unconditional
        // (no outer `if glucoseReadInFlight` guard — that flag is private to `readScheduler`;
        // `completeGlucoseRead()` is a no-op when nothing is in flight, so this is behavior-identical).
        completeGlucoseRead()
    }
}
