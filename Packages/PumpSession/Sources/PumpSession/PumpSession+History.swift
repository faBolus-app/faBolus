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
    var startedAt: Date
    var lastFrameAt: Date
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

    /// Sync and searches share the history stream, so they take turns.
    func acquireHistory() async {
        guard historyBusy else {
            historyBusy = true
            return
        }
        await withCheckedContinuation { historyWaiters.append($0) }
    }

    func releaseHistory() {
        if historyWaiters.isEmpty {
            historyBusy = false
        } else {
            historyWaiters.removeFirst().resume()
        }
    }

    // MARK: - Pages

    /// Asks for `count` records from `start` and collects the stream frames that answer it. Returns the
    /// records in sequence order when every one arrived, or what arrived once frames stopped for
    /// `historyPageQuiet`; nil when the request wasn't answered or the link dropped.
    func fetchPage(start: UInt32, count: Int, priority: Priority) async -> [[UInt8]]? {
        precondition((1...255).contains(count))
        let id = nextJobID
        nextJobID += 1
        return await withCheckedContinuation { continuation in
            let now = clock()
            page = PageCollector(
                id: id, range: start...(start &+ UInt32(count) &- 1), startedAt: now, lastFrameAt: now,
                continuation: continuation)
            Task {
                let result = await self.exchange(
                    HistoryLogRequest(startLog: start, numberOfLogs: count), priority: priority)
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
        collector.lastFrameAt = clock()
        page = collector
        if collector.isComplete { finishPage(collector.records.keys.sorted().compactMap { collector.records[$0] }) }
    }

    func pageRequestSent() {
        guard var collector = page, !collector.sent else { return }
        let now = clock()
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

    func historyTick(now: Date) {
        guard let collector = page, collector.sent else { return }
        let quiet = now.timeIntervalSince(collector.lastFrameAt)
        let open = now.timeIntervalSince(collector.startedAt)
        // A clock stepped backwards ends the page too, rather than holding the history lock until it
        // catches up.
        if quiet >= config.historyPageQuiet || open >= config.historyPageLimit || quiet < 0 || open < 0 {
            finishPage(collector.records.keys.sorted().compactMap { collector.records[$0] })
        }
    }

    func historyLinkDropped() {
        finishPage(nil)
        if case .syncing = historySync { setHistorySync(.paused) }
    }

    func setHistorySync(_ next: HistorySyncState) {
        guard next != historySync else { return }
        historySync = next
        emit(.historySync(next))
    }

    // MARK: - Sync

    /// Fetches the history records the phone doesn't hold yet, newest window first, each window from its
    /// newest record down, at most `historyMaxPages` pages a sync. A page is written to the history store
    /// before it is credited as held, so records the store didn't keep are fetched again next time; a drop
    /// leaves the sync paused, and the next one picks up where the coverage ends.
    public func syncHistory() async {
        // Only from the pump the pairing trusts. A new pairing is trusted at the end of `ready()`, after it
        // has emptied the logbook under the history lock, so a sync asked for meanwhile ("Sync history
        // now") can't hold that lock while `ready()` waits on it with the link's events stalled behind it.
        // One that can't run doesn't move the next one back.
        guard state.link.isConnected, identity != nil, identityTrusted else { return }
        due[.history] = clock().addingTimeInterval(config.historySyncInterval)
        await acquireHistory()
        await runHistorySync()
        releaseHistory()
    }

    private func runHistorySync() async {
        // The pump may have gone, or changed, while the sync waited for its turn.
        guard state.link.isConnected, identity != nil, identityTrusted else { return }
        setHistorySync(.syncing)
        guard case .reply(let reply) = await exchange(HistoryLogStatusRequest(), priority: .history),
            let status = reply.message as? HistoryLogStatusResponse
        else {
            setHistorySync(state.link.isConnected ? .error("The pump's history couldn't be read.") : .paused)
            return
        }
        if anchor == nil { _ = await exchange(TimeSinceResetRequest(), priority: .history) }
        guard status.numEntries > 0, status.lastSequenceNum >= status.firstSequenceNum else {
            finishSync()
            return
        }
        var pages = 0
        windows: for window in record.coverage.missing(first: status.firstSequenceNum, last: status.lastSequenceNum)
            .reversed()
        {
            var top = window.upperBound
            while pages < config.historyMaxPages {
                let count = Int(min(UInt64(255), UInt64(top - window.lowerBound) + 1))
                let start = top - UInt32(count - 1)
                guard let records = await fetchPage(start: start, count: count, priority: .history) else {
                    setHistorySync(state.link.isConnected ? .error("The pump's history couldn't be read.") : .paused)
                    return
                }
                pages += 1
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
                // Held from the page's top down to the first missing record.
                guard batch.sequences.contains(top) else { continue windows }
                var lowest = top
                while lowest > start, batch.sequences.contains(lowest - 1) { lowest -= 1 }
                record.coverage = record.coverage.inserting(lowest...top)
                saveRecord()
                guard lowest == start, start > window.lowerBound else { continue windows }
                top = start - 1
            }
            // The page limit cut this sync short: the rest follows soon rather than at the next routine sync.
            due[.history] = clock().addingTimeInterval(config.historyContinueAfter)
            break
        }
        finishSync()
    }

    private func finishSync() {
        let now = clock()
        record.lastHistorySync = now
        saveRecord()
        setHistorySync(.idle(lastSynced: now))
        // New history may settle an unknown outcome.
        nextReconcileAt = now
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
    func reconcileUnknownOutcomes() async {
        guard !reconciling, state.link.isConnected, identityTrusted, let pumpKey = record.pairing?.pumpKey else {
            return
        }
        reconciling = true
        defer { reconciling = false }
        let entries = await ledger.ledger.unknownOutcomes
        var stillDelivering = false
        for entry in entries {
            guard let bolusId = entry.bolusId,
                RemoteBolusLedger.comparePumpKey(entry.pumpKey, to: pumpKey) != .mismatch
            else { continue }
            switch await searchHistory(for: bolusId, acceptedAt: entry.pumpClockAtAcceptance) {
            case .completed(let record):
                // A record whose own requested amount isn't this request's is a different bolus.
                if record.requestedUnits > 0, abs(record.requestedUnits - entry.request.totalUnits) > 0.01 { continue }
                await settle(entry.key, .deliveredFromHistory(record.deliveredUnits, pumpKey: pumpKey))
            case .absent:
                await settle(entry.key, .absentFromHistory(pumpKey: pumpKey))
            case .delivering:
                stillDelivering = true
            case .present, .inconclusive:
                break
            }
        }
        guard await !ledger.ledger.unknownOutcomes.isEmpty else { return }
        // A bolus the pump is still delivering is looked at again soon, and doesn't use up a try.
        if stillDelivering {
            nextReconcileAt = clock().addingTimeInterval(config.reconcileWhileDelivering)
            return
        }
        reconcileAttempts += 1
        if reconcileAttempts < config.reconcileAttemptsPerConnection {
            nextReconcileAt = clock().addingTimeInterval(config.reconcileInterval)
        }
    }

    /// Looks for `bolusId` in history, newest first, at most `reconcileMaxPages` pages back.
    ///
    /// - Parameter acceptedAt: the pump's clock when it granted the bolus's permission. Only with it can
    ///   the search show the bolus absent: by reaching records older than it (less a margin) with no record
    ///   naming the bolus.
    func searchHistory(for bolusId: Int, acceptedAt: UInt32?) async -> HistorySearchResult {
        await acquireHistory()
        let result = await runSearch(for: bolusId, acceptedAt: acceptedAt)
        releaseHistory()
        return result
    }

    private func runSearch(for bolusId: Int, acceptedAt: UInt32?) async -> HistorySearchResult {
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
        var mentioned = false
        var clockChanged = false
        var top = status.lastSequenceNum
        for _ in 0..<config.reconcileMaxPages {
            let count = Int(min(UInt64(255), UInt64(top - status.firstSequenceNum) + 1))
            let start = top - UInt32(count - 1)
            guard let records = await fetchPage(start: start, count: count, priority: .reconcile) else {
                return mentioned ? .present : .inconclusive
            }
            if let completed = HistoryProjection.completedBoluses(records).last(where: { $0.bolusId == bolusId }) {
                return .completed(completed)
            }
            let events = HistoryProjection.events(records)
            if events.contains(where: { HistoryProjection.bolusId(of: $0) == bolusId }) { mentioned = true }
            if events.contains(where: HistoryProjection.isClockChange) { clockChanged = true }
            guard records.count == count else { return mentioned ? .present : .inconclusive }
            if let acceptedAt, let oldest = events.map(\.pumpTimeSec).min(),
                UInt64(oldest) + UInt64(config.reconcileMargin) < UInt64(acceptedAt)
            {
                if mentioned { return .present }
                return clockChanged ? .inconclusive : .absent
            }
            guard start > status.firstSequenceNum else { break }
            top = start - 1
        }
        return mentioned ? .present : .inconclusive
    }
}
