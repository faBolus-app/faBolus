// This is a Tandem-only importer that intentionally stays in `Data/App/`, NOT in
// `Data/Tandem/` — it is gate-adjacent (history-log gap sync, no delivery opcode).
import Foundation
import faBolusCore
import TandemMessages

/// Read-only history-log gap-sync state machine, behind injected closures. Published fields
/// (`historySyncState`, `historyEvents`, `snapshot`, histories, `bolusMarkers`) stay owned by
/// `TandemBackend` and are mutated only via sinks. Coverage/paging state is the sole store here.
/// Zero delivery opcode is reachable from this type — every send is an unsigned history-log read,
/// and `allowInsulinDelivery` is never `true` on the injected `send` closure.
@MainActor
final class PumpHistorySyncCoordinator {

    // MARK: - Injected seams (settable post-construction)

    /// Bound to `{ [weak self] msg in try? self?.tx.send(msg, authenticationKey: [], pumpTimeSinceReset: 0,
    /// allowInsulinDelivery: false) }` — the SAME swallow-on-failure `tx`/`client.send` routing every
    /// history-log send used inline before this move (byte-identical wire path).
    var send: (Message) -> Void = { _ in }
    /// Bound to `{ [weak self] in self?.snapshot.connection == .connected }`.
    var isConnected: () -> Bool = { false }
    /// Bound to `{ [weak self] in self?.historySyncState ?? .idle(lastSynced: nil) }`.
    var historySyncState: () -> HistorySyncState = { .idle(lastSynced: nil) }
    /// Bound to `{ [weak self] state in self?.historySyncState = state }`.
    var setHistorySyncState: (HistorySyncState) -> Void = { _ in }
    /// Bound to a closure that mutates `TandemBackend.snapshot` in place (its setter is `private(set)`).
    var withSnapshot: ((inout PumpSnapshot) -> Void) -> Void = { _ in }
    /// Bound to a closure that mutates `TandemBackend.glucoseHistory` in place.
    var withGlucoseHistory: ((inout [GlucoseReading]) -> Void) -> Void = { _ in }
    /// Bound to a closure that mutates `TandemBackend.iobHistory` in place.
    var withIOBHistory: ((inout [IOBSample]) -> Void) -> Void = { _ in }
    /// Bound to a closure that mutates `TandemBackend.bolusMarkers` in place.
    var withBolusMarkers: ((inout [BolusMarker]) -> Void) -> Void = { _ in }
    /// Bound to a closure that mutates `TandemBackend.historyEvents` in place (its setter is
    /// `private(set)`).
    var withHistoryEvents: ((inout [HistoryEvent]) -> Void) -> Void = { _ in }
    /// Bound to `{ [weak self] in self?.onChange?() }`.
    var onChange: () -> Void = {}

    // MARK: - Coverage/paging state (sole store here)

    /// `#if DEBUG` test seam: the zone `finishBackfill` re-anchors history records into (production
    /// reads `TimeZone.current`). Forwarded by `TandemBackend.historyBackfillTimeZoneForTesting` so the
    /// existing test-facing API is unchanged.
    #if DEBUG
    var historyBackfillTimeZoneForTesting: TimeZone?
    #endif
    /// `private(set)` (not `private`): `TandemBackend` reads this (e.g. the `isBackfillActive`/
    /// `historyLog`-unparseable-frame call sites) but every WRITE happens inside this type — single
    /// source of truth, no dual state.
    private(set) var backfillActive = false
    private var backfillBuffer: [(pumpSec: UInt32, mgdl: Int)] = []
    private var backfillBoluses: [(pumpSec: UInt32, units: Double, iob: Double)] = []
    private var backfillEventLogs: [any HistoryLogEvent] = []
    private var pendingGapWindows: [ClosedRange<UInt32>] = []
    private var currentGapWindow: ClosedRange<UInt32>?
    /// The set of sequence numbers whose RESPONSE frames actually arrived for the current
    /// gap window (recorded from the received records in `appendHistoryStreamFrame`, not the
    /// request cursor). `creditCurrentWindow()` credits ONLY the top-anchored contiguous received
    /// sub-range.
    private var receivedSeqsThisWindow: Set<UInt32> = []
    private var backfillNextEnd: UInt32 = 0     // upper sequence number for the next page within currentGapWindow
    private var backfillFirstSeq: UInt32 = 0    // lower bound of currentGapWindow
    private var backfillPages = 0
    private var backfillTimer: Timer?
    private static let backfillPageSize = 255   // numberOfLogs is one byte
    private static let backfillMaxPages = 20    // safety cap (~5100 records total, across every window)

    // MARK: - Pure gap computation (unit-testable, no BLE)

    /// Pure gap computation — no BLE, directly unit-testable. Given the pump's reported
    /// `[pumpFirst, pumpLast]` range, the retention floor (see `retentionFloorSequence`), and the
    /// locally HELD coverage ranges, returns the ordered list of sequence ranges still missing:
    /// both a trailing FORWARD gap (records the pump logged during a disconnect) and any
    /// INTERIOR/non-sequential holes. Subtracts each held range from the running remainder in turn.
    static func missingRanges(pumpFirst: UInt32, pumpLast: UInt32, retentionFloor: UInt32,
                              held: [ClosedRange<UInt32>]) -> [ClosedRange<UInt32>] {
        let lower = max(pumpFirst, retentionFloor)
        guard lower <= pumpLast else { return [] }
        var missing: [ClosedRange<UInt32>] = [lower...pumpLast]
        for h in held.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            missing = missing.flatMap { m -> [ClosedRange<UInt32>] in
                guard h.overlaps(m) else { return [m] }
                var pieces: [ClosedRange<UInt32>] = []
                if m.lowerBound < h.lowerBound { pieces.append(m.lowerBound...(h.lowerBound - 1)) }
                if m.upperBound > h.upperBound { pieces.append((h.upperBound + 1)...m.upperBound) }
                return pieces
            }
        }
        return missing
    }

    /// Retention-floor sequence for `missingRanges`. `historyRetentionDays == 0` means "keep
    /// everything" (`AppSettings`'s own default), so it must resolve to `pumpFirst` (the full
    /// available range), never to a "now"/zero sentinel. For `> 0`, there is no sequence↔date
    /// mapping available BEFORE any records are fetched, so this deliberately returns `pumpFirst`
    /// in both cases: a superset fetch, with the EXACT date boundary enforced by
    /// `AppModel.applyRetention` store-side pruning.
    static func retentionFloorSequence(pumpFirst: UInt32, pumpLast: UInt32, retentionDays: Int) -> UInt32 {
        pumpFirst
    }

    // MARK: - Entry points

    /// Entry point for a gap-aware sync: compute the missing windows against the persisted
    /// coverage map and, if any exist, start paging them. `PumpResponseApplier`'s
    /// `HistoryLogStatusResponse` case calls this whenever `m.numEntries > 0`.
    func beginGapSync(pumpFirst: UInt32, pumpLast: UInt32) {
        let held = AppSettings.shared.historyCoverage.ranges
        let floor = Self.retentionFloorSequence(pumpFirst: pumpFirst, pumpLast: pumpLast,
                                                retentionDays: AppSettings.shared.historyRetentionDays)
        let windows = Self.missingRanges(pumpFirst: pumpFirst, pumpLast: pumpLast, retentionFloor: floor, held: held)
        guard !windows.isEmpty else {
            // Already fully synced against the pump's reported range — a check that confirms
            // nothing was missing is still a completed sync, not a stuck `.syncing` spinner.
            AppSettings.shared.historyLastSyncedAt = Date()
            setHistorySyncState(.idle(lastSynced: AppSettings.shared.historyLastSyncedAt))
            return
        }
        setHistorySyncState(.syncing)
        backfillActive = true
        backfillBuffer.removeAll(keepingCapacity: true)
        backfillBoluses.removeAll(keepingCapacity: true)
        backfillEventLogs.removeAll(keepingCapacity: true)
        receivedSeqsThisWindow.removeAll(keepingCapacity: true)   // clean slate at the start of each sync
        backfillPages = 0
        pendingGapWindows = windows
        advanceToNextGapWindow()
    }

    /// Pop the next gap window off the queue and start paging it, or finish the sync if the queue
    /// is empty or the safety cap has already been reached.
    private func advanceToNextGapWindow() {
        guard !pendingGapWindows.isEmpty, backfillPages < Self.backfillMaxPages else {
            finishBackfill(); return
        }
        let window = pendingGapWindows.removeFirst()
        currentGapWindow = window
        receivedSeqsThisWindow.removeAll(keepingCapacity: true)   // fresh per-window received-sequence accumulator
        backfillFirstSeq = window.lowerBound
        backfillNextEnd = window.upperBound
        requestBackfillPage()
    }

    /// Request one page of the CURRENT gap window (255 records max), walking backward from
    /// `backfillNextEnd` — unchanged paging shape from the prior single-walk backfill, just
    /// driven by the gap-window queue instead of one unconditional range.
    private func requestBackfillPage() {
        guard backfillNextEnd >= backfillFirstSeq, backfillPages < Self.backfillMaxPages else {
            creditCurrentWindowAndAdvance(); return
        }
        let available = backfillNextEnd - backfillFirstSeq + 1
        let count = min(UInt32(Self.backfillPageSize), available)
        guard count > 0 else { creditCurrentWindowAndAdvance(); return }
        let startLog = backfillNextEnd - (count - 1)
        backfillPages += 1
        send(HistoryLogRequest(startLog: startLog, numberOfLogs: Int(count)))
        backfillNextEnd = startLog > 0 ? startLog - 1 : 0   // next (older) page within this window
        scheduleBackfillTick()
    }

    /// Debounce: a page's stream has ended once ~2.5 s pass with no new frames. There is no
    /// explicit end-of-page marker in the protocol, so silence is the only signal a page is done.
    private func scheduleBackfillTick() {
        backfillTimer?.invalidate()
        backfillTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
            MainActor.assumeIsolated { self.backfillPageDone() }
        }
    }

    /// `func` (not `private`): `TandemBackend.fireHistorySyncTickForTesting()` calls this directly as the
    /// test-seam substitute for the real 2.5 s `Timer`.
    func backfillPageDone() {
        if backfillNextEnd >= backfillFirstSeq, backfillPages < Self.backfillMaxPages {
            requestBackfillPage()
        } else {
            creditCurrentWindowAndAdvance()
        }
    }

    /// Record into the persisted coverage map ONLY the sub-range of `currentGapWindow` whose
    /// response frames were actually RECEIVED — never the request cursor. Pages walk backward from
    /// `window.upperBound`, so received sequences form a top-anchored contiguous run; walk down from
    /// the top while each sequence arrived and credit exactly `[lowest ... window.upperBound]`.
    private func creditCurrentWindow() {
        guard let window = currentGapWindow else { return }
        // Nothing received at the top of the window → credit nothing (never mark an un-received range covered).
        guard receivedSeqsThisWindow.contains(window.upperBound) else { return }
        var lowest = window.upperBound
        while lowest > window.lowerBound, receivedSeqsThisWindow.contains(lowest - 1) {
            lowest -= 1
        }
        AppSettings.shared.historyCoverage = AppSettings.shared.historyCoverage.inserting(lowest...window.upperBound)
    }

    /// Credit the current window (see `creditCurrentWindow`), then move on to the next queued window
    /// (or finish the sync).
    private func creditCurrentWindowAndAdvance() {
        creditCurrentWindow()
        currentGapWindow = nil
        advanceToNextGapWindow()
    }

    /// Manual "Sync now": runs the SAME gap-sync entry point as the on-connect check, regardless
    /// of `AppSettings.historySyncEnabled` — the toggle only gates the AUTOMATIC on-connect trigger,
    /// not an explicit user request. Requires the pump to already be connected; a sync already in
    /// progress is a no-op rather than restarting mid-fetch.
    func triggerManualHistorySync() {
        guard isConnected(), !backfillActive else { return }
        setHistorySyncState(.syncing)
        send(HistoryLogStatusRequest())
        onChange()
    }

    /// User-initiated abort of an in-progress gap sync. Non-destructive — only the sub-range of
    /// the current window actually fetched is credited to the persisted coverage map, exactly like
    /// a safety-cap trip.
    func cancelHistorySync() {
        guard backfillActive else { return }
        backfillTimer?.invalidate(); backfillTimer = nil
        creditCurrentWindow()
        backfillActive = false
        pendingGapWindows.removeAll(); currentGapWindow = nil
        backfillBuffer.removeAll(); backfillBoluses.removeAll(); backfillEventLogs.removeAll()
        setHistorySyncState(.paused)
        onChange()
    }

    /// Abort the in-progress backfill with a genuine sync-failure error — called from
    /// `TandemBackend.didReceiveFrame`'s unparseable-`.historyLog`-frame branch. A no-op when no
    /// backfill is active, mirroring `cancelHistorySync`'s guard shape.
    func abortWithSyncError(_ message: String) {
        guard backfillActive else { return }
        backfillTimer?.invalidate(); backfillTimer = nil
        backfillActive = false
        pendingGapWindows.removeAll(); currentGapWindow = nil
        backfillBuffer.removeAll(); backfillBoluses.removeAll(); backfillEventLogs.removeAll()
        setHistorySyncState(.error(message))
        onChange()
    }

    /// The history subset of `TandemBackend.linkDroppedCleanup()` — called from the still-in-place
    /// `linkDroppedCleanup`. `historyStatusRequestedThisConnection` stays TandemBackend's own field
    /// and is reset there, not here.
    func linkDropped() {
        // A sync mid-flight when the link drops is a benign, resumable pause — the persisted
        // coverage map guarantees the next connect resumes correctly — never a red error.
        // `.syncing` is the only in-progress state this can interrupt.
        if case .syncing = historySyncState() { setHistorySyncState(.paused) }
        backfillActive = false
        backfillTimer?.invalidate(); backfillTimer = nil
        backfillBuffer.removeAll(); backfillBoluses.removeAll(); backfillEventLogs.removeAll()
        pendingGapWindows.removeAll(); currentGapWindow = nil
    }

    /// Called by `PumpResponseApplier`'s `HistoryLogStreamResponse` case (via `TandemBackend`'s injected
    /// `appendHistoryStreamFrame` closure) for every stream frame WHILE a backfill is active. Appends one
    /// frame's records into the backfill buffers and (re)schedules the stream-end debounce.
    func appendHistoryStreamFrame(_ m: HistoryLogStreamResponse) {
        // App-side defense-in-depth — refuse to append/advance a page when the frame's actual
        // record count disagrees with its own advertised `numberOfHistoryLogs` header byte.
        guard m.records.count == m.numberOfHistoryLogs else { return }
        for r in m.cgmReadings { backfillBuffer.append((r.pumpTimeSec, r.glucoseMgdl)) }
        for b in m.bolusRecords { backfillBoluses.append((b.pumpTimeSec, b.deliveredUnits, b.iobUnits)) }
        backfillEventLogs.append(contentsOf: m.events)
        if backfillEventLogs.count > 2000 { backfillEventLogs.removeFirst(backfillEventLogs.count - 2000) }
        // Record every RECEIVED sequence that falls inside the current gap window.
        if let window = currentGapWindow {
            for e in m.events where window.contains(e.sequenceNum) { receivedSeqsThisWindow.insert(e.sequenceNum) }
        }
        scheduleBackfillTick()   // debounce: page ends when frames stop arriving
    }

    /// Merge the buffered CGM history into the chart. Places each reading at its TRUE pump-clock
    /// time (`pumpTimeSec + Jan-1-2008 epoch`, the same conversion controlX2/tconnectsync use) so
    /// it aligns with the correct live `Date()`-stamped readings — no "anchor newest to now",
    /// which previously shifted older data forward onto the present.
    private func finishBackfill() {
        backfillTimer?.invalidate(); backfillTimer = nil
        backfillActive = false
        pendingGapWindows.removeAll(); currentGapWindow = nil
        defer { backfillBuffer.removeAll(keepingCapacity: false); backfillBoluses.removeAll(keepingCapacity: false) }
        let now = Date()
        // The pump logs time as local WALL-CLOCK (the clock reading shown on its face), so each
        // record must be placed using the UTC offset in effect at THAT record's own instant — not a
        // single offset captured today.
        #if DEBUG
        let pumpTZ = historyBackfillTimeZoneForTesting ?? TimeZone.current   // test seam (nil ⇒ TimeZone.current)
        #else
        let pumpTZ = TimeZone.current
        #endif
        var utcCal = Calendar(identifier: .gregorian); utcCal.timeZone = TimeZone(identifier: "UTC")!
        var zoneCal = Calendar(identifier: .gregorian); zoneCal.timeZone = pumpTZ
        // FAILABLE — an un-synced pump clock, west travel, or a forced-read failure can re-anchor
        // a record's naive wall-clock components into an instant more than
        // `GlucoseFreshness.futureSkewTolerance` (5 min) beyond `now`. Reject, never clamp-to-now.
        let pumpDate: (UInt32) -> Date? = { sec in
            let naive = Date(timeIntervalSince1970: HistoryLog.jan12008UnixEpoch + Double(sec))
            let c = utcCal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: naive)
            let instant = zoneCal.date(from: c) ?? naive
            return instant <= now.addingTimeInterval(GlucoseFreshness.futureSkewTolerance) ? instant : nil
        }

        // --- CGM readings ---
        if !backfillBuffer.isEmpty {
            withGlucoseHistory { history in
                var merged = history
                for b in backfillBuffer {
                    guard let date = pumpDate(b.pumpSec) else { continue }   // drop, never clamp
                    merged.append(GlucoseReading(date: date, mgdl: b.mgdl))
                }
                merged.sort { $0.date < $1.date }
                // Collapse readings that fall in the same time bucket — keep only the FIRST reading
                // within any ~150 s window (regardless of value): one point per interval.
                var deduped: [GlucoseReading] = []
                for r in merged {
                    if let last = deduped.last, r.date.timeIntervalSince(last.date) < 150 { continue }
                    deduped.append(r)
                }
                if deduped.count > 288 { deduped.removeFirst(deduped.count - 288) }
                history = deduped
                // Backfill NEVER writes the live dosing snapshot — a backfilled/mis-anchored
                // historical record must never taint the latest-glucose dosing read. The live
                // dosing glucose stays owned exclusively by `PumpResponseApplier.applyEgvReading`;
                // a pre-existing live value is PRESERVED here.
            }
        }

        // --- Boluses (bars) + IOB samples seeded from history ---
        if !backfillBoluses.isEmpty {
            withBolusMarkers { markers in
                withIOBHistory { iob in
                    let existingBolus = Set(markers.map { $0.date.timeIntervalSince1970.rounded() })
                    var existingIOB = Set(iob.map { $0.date.timeIntervalSince1970.rounded() })
                    for b in backfillBoluses {
                        guard let date = pumpDate(b.pumpSec) else { continue }   // drop, never clamp
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
                    iob.sort { $0.date < $1.date }
                    if iob.count > 288 { iob.removeFirst(iob.count - 288) }
                }
            }
        }

        // --- Logbook events (B2): map decoded typed events → neutral, newest first ---
        if !backfillEventLogs.isEmpty {
            var finalEvents: [HistoryEvent] = []
            withHistoryEvents { events in
                var seen = Set(events.map { $0.id })
                for e in backfillEventLogs {
                    // Drop, never clamp — a future-anchored event is dropped BEFORE `neutralEvent`
                    // (which takes a concrete, non-optional `Date`), consistent with the other loops.
                    guard !seen.contains(e.sequenceNum), let date = pumpDate(e.pumpTimeSec),
                          let ne = Self.neutralEvent(e, date: date) else { continue }
                    seen.insert(e.sequenceNum); events.append(ne)
                }
                events.sort { $0.date > $1.date }          // newest first
                if events.count > 500 { events.removeLast(events.count - 500) }
                finalEvents = events
            }
            // Surface the single LATEST instant of each into PumpSnapshot so it can propagate to
            // remotes as a lightweight marker — `finalEvents` is already newest-first, so the first
            // match after filtering is the latest.
            if let latest = finalEvents.first(where: { $0.category == .autoCorrection }) {
                withSnapshot { $0.lastAutoCorrectionDate = latest.date }
            }
            if let latest = finalEvents.first(where: { $0.category == .couldNotDeliver }) {
                withSnapshot { $0.ciqLastCouldNotDeliverDate = latest.date }
            }
        }
        // A completed gap sync (whether or not this pass actually fetched new records) is a
        // successful sync for "Last synced" purposes.
        AppSettings.shared.historyLastSyncedAt = Date()
        setHistorySyncState(.idle(lastSynced: AppSettings.shared.historyLastSyncedAt))
        onChange()
    }

    /// Maps a TandemKit typed history-log event to a neutral `HistoryEvent` for the Logbook.
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
        case let m as BolusDeliveryHistoryLog where m.bolusSource == 7:
            // `BolusDeliveryHistoryLog` already decodes `bolusSource`; `bolusSource == 7` marks a
            // Control-IQ auto-correction. Display-only, never a dose input; the latest instant is
            // surfaced into `PumpSnapshot.lastAutoCorrectionDate` above.
            return HistoryEvent(id: seq, date: date, category: .autoCorrection, title: "Control-IQ auto-corrected")
        case let m as BolexCompletedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .bolus, title: "Extended bolus", detail: u(m.insulinDelivered))
        case let m as CarbEnteredHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .carbs, title: "Carbs entered", detail: String(format: "%.0f g", m.carbs))
        case let m as BGHistoryLog:
            // The Logbook tab is a mainline surface, not debug-only — route through the
            // display-unit funnel like every other glucose display.
            let bgUnit = AppSettings.shared.glucoseDisplayUnit
            let bgStr = "\(bgUnit.format(mgdl: m.bg)) \(bgUnit == .mmol ? "mmol/L" : "mg/dL")"
            return HistoryEvent(id: seq, date: date, category: .bg, title: "BG entered", detail: bgStr)
        case let m as BasalRateChangeHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .basal, title: "Basal rate change", detail: u(m.commandBasalRate) + "/hr")
        case let m as TempRateActivatedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .tempRate, title: "Temp rate started", detail: String(format: "%.0f%%", m.percent))
        case is TempRateCompletedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .tempRate, title: "Temp rate ended")
        case is AaAutoBolusRejectedHistoryLog, is CorrectionDeclinedHistoryLog:
            // Pump-communicated fact: both already decoded + registered in `HistoryLogParser`
            // but previously dropped here. Never speculates WHY. The latest instant is surfaced
            // into `PumpSnapshot.ciqLastCouldNotDeliverDate` above.
            return HistoryEvent(id: seq, date: date, category: .couldNotDeliver,
                                 title: "Control-IQ tried and couldn't deliver an automatic correction")
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
