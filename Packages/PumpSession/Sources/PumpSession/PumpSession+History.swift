import Foundation
import TandemLink
import TandemMessages
import faBolusCore

/// One history page being received: the records arrive as stream frames after the request's ack.
struct PageCollector {
    let id: UInt64
    let range: ClosedRange<UInt32>
    var records: [UInt32: [UInt8]] = [:]
    /// The page's clocks start when its request goes out: one waiting in the queue (behind a delivery or a
    /// request the pump is slow to answer) hasn't been asked for yet, so it can't have gone quiet.
    var sent = false
    var startedAt: Uptime
    var lastFrameAt: Uptime
    let continuation: CheckedContinuation<[[UInt8]]?, Never>

    var isComplete: Bool { records.count == range.count }
}

/// What a bounded history search found about one bolus.
enum HistorySearchResult: Equatable {
    /// History records its completion, with the amount.
    case completed(HistoryBolus)
    /// The pump reports the bolus active.
    case delivering
    /// A record names the bolus, but it hasn't completed.
    case present
    /// The search reached back past the bolus's acceptance with every record received, no record names
    /// it, the pump's clock wasn't changed in between, and the pump isn't delivering it: it never started.
    case absent
    /// None of the above could be shown.
    case inconclusive
}

extension PumpSession {
    // MARK: - One history operation at a time

    /// Sync and searches share the history stream, so they take turns. Other history jobs go before a
    /// waiting sync: a sync steps aside for them, and another sync would only start over what it did.
    func acquireHistory(sync: Bool = false) async {
        guard historyBusy else {
            historyBusy = true
            return
        }
        await withCheckedContinuation { historyWaiters.append((sync, $0)) }
    }

    /// Whether a history job other than a sync is waiting for the stream.
    var historyJobWaiting: Bool { historyWaiters.contains { !$0.sync } }

    func releaseHistory() {
        guard !historyWaiters.isEmpty else {
            historyBusy = false
            return
        }
        let next = historyWaiters.firstIndex { !$0.sync } ?? historyWaiters.startIndex
        historyWaiters.remove(at: next).continuation.resume()
    }

    // MARK: - Pages

    /// Asks for the `count` records up to `top` and collects the stream frames that answer it. Returns the
    /// records in sequence order when every one arrived, or what arrived once frames stopped for
    /// `historyPageQuiet`; nil when the request wasn't answered or the link dropped.
    ///
    /// The request names the page's newest record, and the pump streams from it down, newest first: what
    /// t:connect and Mobi send, and what the pump answered in t:connect's capture.
    func fetchPage(top: UInt32, count: Int, priority: Priority) async -> [[UInt8]]? {
        precondition((1...255).contains(count) && UInt64(count) <= UInt64(top) + 1)
        let id = nextJobID
        nextJobID += 1
        return await withCheckedContinuation { continuation in
            let now = uptime()
            page = PageCollector(
                id: id, range: (top - UInt32(count - 1))...top, startedAt: now, lastFrameAt: now,
                continuation: continuation)
            Task {
                let result = await self.exchange(
                    HistoryLogRequest(startLog: top, numberOfLogs: count), priority: priority)
                self.pageRequestAnswered(id, result)
            }
        }
    }

    private func pageRequestAnswered(_ id: UInt64, _ result: RequestResult) {
        guard let page, page.id == id else { return }
        if case .reply(let reply) = result, let ack = reply.message as? HistoryLogResponse, ack.status == 0 { return }
        finishPage(nil)
    }

    func historyFrame(_ frame: HistoryLogStreamResponse) {
        guard var collector = page, frame.isValid else { return }
        for record in frame.records {
            let seq = UInt32(record[6]) | UInt32(record[7]) << 8 | UInt32(record[8]) << 16 | UInt32(record[9]) << 24
            if collector.range.contains(seq) { collector.records[seq] = record }
        }
        collector.lastFrameAt = uptime()
        page = collector
        if collector.isComplete { finishPage(collector.records.keys.sorted().compactMap { collector.records[$0] }) }
    }

    func pageRequestSent() {
        guard var collector = page, !collector.sent else { return }
        let now = uptime()
        collector.sent = true
        collector.startedAt = now
        collector.lastFrameAt = now
        page = collector
    }

    private func finishPage(_ records: [[UInt8]]?) {
        guard let collector = page else { return }
        page = nil
        collector.continuation.resume(returning: records)
    }

    func historyTick(now: Uptime) {
        guard let collector = page, collector.sent else { return }
        let quiet = now.timeIntervalSince(collector.lastFrameAt)
        let open = now.timeIntervalSince(collector.startedAt)
        if quiet >= config.historyPageQuiet || open >= config.historyPageLimit {
            finishPage(collector.records.keys.sorted().compactMap { collector.records[$0] })
        }
    }

    func historyLinkDropped() {
        finishPage(nil)
        if case .syncing = historySync { setHistorySync(.paused) }
    }

    /// Whether background history syncs are paused for the pump's battery. The sync stays due, so it runs
    /// as soon as the app is in the foreground or the battery recovers.
    /// A reading too old to show (or none) pauses nothing: a sync costs battery, never safety.
    func historyPausedForBattery() -> Bool {
        guard let percent = state.batteryIfFresh(thresholds: freshness, now: clock())?.percent else {
            batteryLow = false
            return false
        }
        if percent <= config.lowBatteryPauseAt {
            batteryLow = true
        } else if percent > config.lowBatteryResumeAbove {
            batteryLow = false
        }
        return batteryLow && !appActive
    }

    func setHistorySync(_ next: HistorySyncState) {
        guard next != historySync else { return }
        historySync = next
        emit(.historySync(next))
    }

    // MARK: - Sync

    /// Fetches the history records the phone doesn't hold yet, as Mobi does: `historySyncBatch` records a
    /// request, each from the newest record still missing down, until every record of the pump's log has
    /// been asked for. A gap the pump didn't fill is asked for again by the next sync. A batch is written
    /// to the history store before it is credited as held, so records the store didn't keep are fetched
    /// again next time; a drop leaves the sync paused, and the next one picks up where the coverage ends.
    /// A sync asked for during another runs after it.
    public func syncHistory() async {
        // Only from the pump the pairing trusts. A new pairing is trusted at the end of `ready()`, after it
        // has emptied the logbook under the history lock, so a sync asked for meanwhile ("Sync history
        // now") can't hold that lock while `ready()` waits on it with the link's events stalled behind it.
        // One that can't run doesn't move the next one back.
        guard state.link.isConnected, identity != nil, identityTrusted else { return }
        await acquireHistory(sync: true)
        // Set once its turn comes: a sync that stepped aside for another history job asked for one now.
        due[.history] = uptime().addingTimeInterval(config.historySyncInterval)
        await runHistorySync()
        releaseHistory()
    }

    private func runHistorySync() async {
        // The pump may have gone, or changed, while the sync waited for its turn.
        guard state.link.isConnected, identity != nil, identityTrusted else { return }
        setHistorySync(.syncing)
        guard var status = await readHistoryStatus()?.status else { return }
        if anchor == nil { _ = await exchange(TimeSinceResetRequest(), priority: .history) }
        // What this sync has asked for, held or not: a record the pump didn't send, or one dated in the
        // future, is asked for again by the next sync, not over and over by this one.
        var asked = record.coverage
        // A request answered with no record at all: the sync doesn't count as done.
        var unanswered = false
        while status.numEntries > 0, status.lastSequenceNum >= status.firstSequenceNum,
            let window = asked.missing(first: status.firstSequenceNum, last: status.lastSequenceNum).last
        {
            // Mobi checks its pause between batches: a sync under way stops at the next request. So does one
            // with another history job waiting, such as a search settling a bolus: it continues after it.
            if historyPausedForBattery() || historyJobWaiting {
                setHistorySync(.paused)
                due[.history] = uptime()
                return
            }
            let top = window.upperBound
            let count = Int(min(pageCount(config.historySyncBatch), UInt64(top - window.lowerBound) + 1))
            let start = top - UInt32(count - 1)
            guard let records = await fetchPage(top: top, count: count, priority: .history) else {
                setHistorySync(state.link.isConnected ? .error("The pump's history couldn't be read.") : .paused)
                return
            }
            // A request answered with no record at all: the rest of its window is left to a later sync, so a
            // pump that isn't sending this part of its log costs one quiet wait, not one a batch. It stays
            // missing, and this sync doesn't end as synced.
            asked = asked.inserting(records.isEmpty ? window : start...top)
            if records.isEmpty {
                unanswered = true
                continue
            }
            guard let anchor else {
                setHistorySync(.error("The pump's clock couldn't be read."))
                return
            }
            let batch = HistoryProjection.batch(records, anchor: anchor, now: clock())
            if let historySink, !batch.isEmpty {
                do { try await historySink.record(batch) } catch {
                    setHistorySync(.error("History couldn't be saved on this phone."))
                    return
                }
            }
            addEvents(batch.events)
            await settleUnknownOutcomes(from: records)
            record.coverage = runs(of: batch.sequences, in: start...top).reduce(record.coverage) { $0.inserting($1) }
            saveRecord()
            // A notice asked for a sync: the pump's log is read again, so records it added come next, newest
            // first, as Mobi reads its latest status before every batch.
            if let at = due[.history], at <= uptime() {
                due[.history] = uptime().addingTimeInterval(config.historySyncInterval)
                guard let next = await readHistoryStatus() else { return }
                if next.restarted { asked = record.coverage }
                status = next.status
            }
        }
        // A window the pump answered with no record is asked again soon, a few times; the sync doesn't
        // count as done meanwhile, so the last one's time stands. After that the sync finishes with the
        // window still missing (it was never credited as held, so the next routine sync asks for it again),
        // and the search for unknown outcomes that follows a sync still runs. An empty answer never shows a
        // bolus absent: only a search that received every record can.
        if unanswered, emptySyncRetries < config.historyEmptyRetries {
            emptySyncRetries += 1
            lastSyncShort = true
            setHistorySync(.idle(lastSynced: record.lastHistorySync))
            due[.history] = uptime().addingTimeInterval(config.historyEmptyRetryAfter)
            return
        }
        emptySyncRetries = 0
        lastSyncShort = unanswered
        finishSync()
    }

    /// Reads the pump's log bounds. When the log restarted, what the phone holds names records the pump no
    /// longer has, so it goes, and the log is fetched again, as Mobi does.
    private func readHistoryStatus() async -> (status: HistoryLogStatusResponse, restarted: Bool)? {
        guard case .reply(let reply) = await exchange(HistoryLogStatusRequest(), priority: .history),
            let status = reply.message as? HistoryLogStatusResponse
        else {
            setHistorySync(state.link.isConnected ? .error("The pump's history couldn't be read.") : .paused)
            return nil
        }
        guard status.numEntries > 0, status.lastSequenceNum >= status.firstSequenceNum,
            await historyRestarted(status)
        else { return (status, false) }
        record.coverage = HistoryCoverage()
        saveRecord()
        await dropLogbook()
        return (status, true)
    }

    /// Whether the pump's log restarted: its newest record is older than one the phone holds. The unknown
    /// boluses then are from before the restart, and the new log can't show they never started, so they
    /// are marked to stay unknown until the pump confirms them.
    func historyRestarted(_ status: HistoryLogStatusResponse) async -> Bool {
        guard let heldTop = record.coverage.ranges.last?.upperBound, status.lastSequenceNum < heldTop else {
            return false
        }
        let newest = status.lastSequenceNum
        sessionLog.notice("history restarted at \(newest, privacy: .public), held \(heldTop, privacy: .public)")
        // Every unknown bolus now is from before the restart, those from an earlier one included.
        record.beforeHistoryRestart = Set(await ledger.ledger.unknownOutcomes.map(\.key))
        saveRecord()
        return true
    }

    /// The runs of consecutive sequence numbers in `range` that `sequences` holds.
    private func runs(of sequences: Set<UInt32>, in range: ClosedRange<UInt32>) -> [ClosedRange<UInt32>] {
        var runs: [ClosedRange<UInt32>] = []
        var runStart: UInt32?
        for seq in range {
            if sequences.contains(seq) {
                if runStart == nil { runStart = seq }
            } else if let first = runStart {
                runs.append(first...(seq - 1))
                runStart = nil
            }
        }
        if let first = runStart { runs.append(first...range.upperBound) }
        return runs
    }

    /// Records a history request asks for, within its one-byte count.
    func pageCount(_ configured: Int) -> UInt64 { UInt64(min(max(configured, 1), 255)) }

    private func finishSync() {
        let now = clock()
        record.lastHistorySync = now
        saveRecord()
        setHistorySync(.idle(lastSynced: now))
        // New history may settle an unknown outcome.
        scheduleReconcile(at: uptime())
    }

    // MARK: - Logbook

    /// How many logbook events the session keeps, newest first.
    static let logbookLimit = 500

    /// The logbook saved by earlier launches, under anything this launch has already added. With no pump
    /// paired there is none: anything saved is left from a pump whose forget couldn't delete it.
    func loadSavedEvents() async {
        guard let historySink else { return }
        guard record.pairing != nil else {
            await historySink.clearEvents()
            return
        }
        addEvents(await historySink.loadEvents(limit: Self.logbookLimit))
    }

    /// Empties the logbook, in memory and saved, as when the user erases the phone's history. A new
    /// pairing does this too: its history is fetched again from the start, and another pump's events
    /// would otherwise stay in its logbook and hide its own records that share their sequence numbers.
    public func clearLogbook() async {
        await acquireHistory()
        await dropLogbook()
        releaseHistory()
    }

    /// The caller holds the history lock, so a page being saved now can't add its events afterwards.
    func dropLogbook() async {
        historyEvents = []
        await historySink?.clearEvents()
    }

    private func addEvents(_ events: [HistoryEvent]) {
        guard !events.isEmpty else { return }
        let held = Set(historyEvents.map(\.id))
        historyEvents = (historyEvents + events.filter { !held.contains($0.id) }).sorted(by: HistoryEvent.newestFirst)
        if historyEvents.count > Self.logbookLimit {
            historyEvents.removeLast(historyEvents.count - Self.logbookLimit)
        }
    }

    // MARK: - Settling unknown outcomes

    /// Settles each unknown outcome the paired pump's history can speak for: delivered with the amount
    /// history records, or failed when history shows the bolus never started. Anything less leaves it
    /// unknown, and it is tried again a few times a connection.
    ///
    /// Only the outcomes that still block are searched for, a few times a connection. One the user
    /// confirmed on the pump is searched for once ever (`PumpSessionRecord.searchedAfterConfirm`): its
    /// record may have been read by a sync while it was still delivering, and no sync reads it again. After
    /// that only a sync page that holds its record fills in the amount (`settleUnknownOutcomes(from:)`). The tick sets `reconciling` before any suspension, so a trigger
    /// raised while this runs stays set and runs once this ends.
    func reconcileUnknownOutcomes() async {
        defer { reconciling = false }
        guard state.link.isConnected, identityTrusted, let pumpKey = record.pairing?.pumpKey else { return }
        let unknown = await ledger.ledger.unknownOutcomes
        // A bolus no longer unknown needs no mark.
        let keys = Set(unknown.map(\.key))
        let marked = record.beforeHistoryRestart.intersection(keys)
        let searched = record.searchedAfterConfirm.intersection(keys)
        if marked != record.beforeHistoryRestart || searched != record.searchedAfterConfirm {
            record.beforeHistoryRestart = marked
            record.searchedAfterConfirm = searched
            saveRecord()
        }
        let entries = unknown.filter {
            $0.confirmedOnPumpAt == nil || !record.searchedAfterConfirm.contains($0.key)
        }
        guard !entries.isEmpty else { return }
        var stillDelivering = false
        for entry in entries {
            guard let bolusId = entry.bolusId,
                RemoteBolusLedger.comparePumpKey(entry.pumpKey, to: pumpKey) != .mismatch
            else { continue }
            let result = await searchHistory(
                for: bolusId, acceptedAt: entry.pumpClockAtAcceptance, notBefore: earliestRecordTime(for: entry))
            // A confirmed outcome's one search is spent once it ran on a link that held to its end.
            if entry.confirmedOnPumpAt != nil, state.link.isConnected {
                record.searchedAfterConfirm.insert(entry.key)
                saveRecord()
            }
            switch result {
            case .completed(let found):
                guard names(found, entry) else { continue }
                await settle(entry.key, .deliveredFromHistory(found.deliveredUnits, pumpKey: pumpKey))
            case .absent:
                // The pump's log restarted after this bolus: the new log can't show it never started.
                guard !record.beforeHistoryRestart.contains(entry.key) else { break }
                await settle(entry.key, .absentFromHistory(pumpKey: pumpKey))
            case .delivering:
                stillDelivering = true
            case .present, .inconclusive:
                break
            }
        }
        guard await !ledger.ledger.unresolved.isEmpty else { return }
        // A bolus the pump is still delivering is looked at again soon, and doesn't use up a try.
        if stillDelivering {
            scheduleReconcile(at: uptime().addingTimeInterval(config.reconcileWhileDelivering))
            return
        }
        reconcileAttempts += 1
        if reconcileAttempts < config.reconcileAttemptsPerConnection {
            scheduleReconcile(at: uptime().addingTimeInterval(config.reconcileInterval))
        }
    }

    /// Asks for a try at `at`, unless one is already asked for sooner.
    func scheduleReconcile(at time: Uptime) {
        nextReconcileAt = nextReconcileAt.map { min($0, time) } ?? time
    }

    /// Settles, as delivered, each unknown outcome a completed-bolus record in `records` names, with a
    /// search's checks (`names`), confirmed on the pump or not: pages the sync reads anyway cost the pump
    /// nothing more.
    func settleUnknownOutcomes(from records: [[UInt8]]) async {
        let completed = HistoryProjection.completedBoluses(records)
        guard !completed.isEmpty, let pumpKey = record.pairing?.pumpKey else { return }
        for entry in await ledger.ledger.unknownOutcomes {
            guard let bolusId = entry.bolusId,
                RemoteBolusLedger.comparePumpKey(entry.pumpKey, to: pumpKey) != .mismatch,
                let found = completed.last(where: { $0.bolusId == bolusId && names($0, entry) })
            else { continue }
            await settle(entry.key, .deliveredFromHistory(found.deliveredUnits, pumpKey: pumpKey))
        }
    }

    /// Whether `found` is `entry`'s bolus: written after the bolus could have been accepted
    /// (`earliestRecordTime`), in the log the bolus was recorded in (not one restarted since), and with the
    /// request's amount when the record states one. A bolus ID and amount alone may be an older bolus's.
    func names(_ found: HistoryBolus, _ entry: RemoteBolusLedger.Entry) -> Bool {
        guard !record.beforeHistoryRestart.contains(entry.key), let earliest = earliestRecordTime(for: entry),
            found.pumpTime >= earliest
        else { return false }
        return !(found.requestedUnits > 0 && abs(found.requestedUnits - entry.request.totalUnits) > 0.01)
    }

    /// The earliest pump time a record of `entry`'s bolus can carry: its acceptance on the pump's clock, less
    /// `reconcileMargin`. With no pump clock at acceptance, by the clock anchor: from when its outcome became
    /// unknown less the longest a bolus is followed, or from its last move, each less the margin. `nil` when
    /// neither can be worked out: then no record settles it, and only the user can (UNVERIFIED-GUESSES #42).
    func earliestRecordTime(for entry: RemoteBolusLedger.Entry) -> UInt32? {
        if let accepted = entry.pumpClockAtAcceptance {
            return accepted > config.reconcileMargin ? accepted - config.reconcileMargin : 0
        }
        guard let anchor else { return nil }
        let margin = TimeInterval(config.reconcileMargin)
        let from: Date =
            if case .unknown(let since) = entry.outcome {
                since.addingTimeInterval(-(config.deliveryTrackingLimit + margin))
            } else {
                entry.updatedAt.addingTimeInterval(-margin)
            }
        return anchor.pumpTime(at: from)
    }

    /// Looks for `bolusId` in history, newest first, at most `reconcileMaxPages` pages back.
    ///
    /// - Parameter acceptedAt: the pump's clock when it granted the bolus's permission. Only with it can
    ///   the search show the bolus absent: by reaching records older than it (less a margin) with no record
    ///   naming the bolus.
    /// - Parameter notBefore: the earliest pump time a record of this bolus can carry. A completed record
    ///   older than it is another bolus that had the same ID, and isn't taken for this one.
    func searchHistory(for bolusId: Int, acceptedAt: UInt32?, notBefore: UInt32? = nil) async -> HistorySearchResult {
        await acquireHistory()
        let result = await runSearch(for: bolusId, acceptedAt: acceptedAt, notBefore: notBefore)
        releaseHistory()
        return result
    }

    private func runSearch(for bolusId: Int, acceptedAt: UInt32?, notBefore: UInt32?) async -> HistorySearchResult {
        guard state.link.isConnected else { return .inconclusive }
        if case .reply(let reply) = await exchange(CurrentBolusStatusRequest(), priority: .reconcile),
            let status = reply.message as? CurrentBolusStatusResponse, status.isActive, status.bolusId == bolusId
        {
            return .delivering
        }
        guard case .reply(let reply) = await exchange(HistoryLogStatusRequest(), priority: .reconcile),
            let status = reply.message as? HistoryLogStatusResponse, status.numEntries > 0,
            status.lastSequenceNum >= status.firstSequenceNum
        else { return .inconclusive }
        // A restart found here, before a sync sees it, still marks the boluses from before it.
        _ = await historyRestarted(status)
        var mentioned = false
        var clockChanged = false
        // Records the search went past without receiving: with any, it can never show the bolus absent.
        var gap = false
        var top = status.lastSequenceNum
        for _ in 0..<config.reconcileMaxPages {
            let count = Int(min(pageCount(config.historyPageSize), UInt64(top - status.firstSequenceNum) + 1))
            let start = top - UInt32(count - 1)
            guard let records = await fetchPage(top: top, count: count, priority: .reconcile) else {
                return mentioned ? .present : .inconclusive
            }
            if let completed = HistoryProjection.completedBoluses(records).last(where: {
                $0.bolusId == bolusId && $0.pumpTime >= (notBefore ?? 0)
            }) {
                return .completed(completed)
            }
            let events = HistoryProjection.events(records)
            if events.contains(where: { HistoryProjection.bolusId(of: $0) == bolusId }) { mentioned = true }
            if events.contains(where: HistoryProjection.isClockChange) { clockChanged = true }
            if records.count < count {
                // A page cut short. The pump walks backward from `top`, so what it ended without is usually
                // its oldest records: the next page asks from just below the run that arrived from the top.
                // A page without its top record leaves a gap the search goes on past.
                let held = Set(records.map(Self.sequence))
                var lowest = top
                if held.contains(top) {
                    while lowest > start, held.contains(lowest - 1) { lowest -= 1 }
                } else {
                    gap = true
                    lowest = start
                }
                guard lowest > status.firstSequenceNum else { break }
                top = lowest - 1
                continue
            }
            if let acceptedAt, let oldest = events.map(\.pumpTimeSec).min(),
                UInt64(oldest) + UInt64(config.reconcileMargin) < UInt64(acceptedAt)
            {
                if mentioned { return .present }
                return clockChanged || gap ? .inconclusive : .absent
            }
            guard start > status.firstSequenceNum else { break }
            top = start - 1
        }
        return mentioned ? .present : .inconclusive
    }

    /// A history record's sequence number.
    static func sequence(_ record: [UInt8]) -> UInt32 {
        UInt32(record[6]) | UInt32(record[7]) << 8 | UInt32(record[8]) << 16 | UInt32(record[9]) << 24
    }
}
