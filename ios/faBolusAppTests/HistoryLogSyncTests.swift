import Testing
import Foundation
import faBolusCore
import HistoryStore
import TandemMessages
import TandemBLE
@testable import faBolus

/// On reconnect, history sync must fetch only missing sequence windows — trailing gaps and interior
/// holes — not re-walk the whole pump log.
@Suite(.serialized) @MainActor
struct HistoryLogSyncTests {

    /// Save + restore `AppSettings.shared.historyCoverage` around a test so gap-sync state never leaks
    /// across suites (mirrors the established `BadgePublisherTests` save/defer-restore idiom for the
    /// shared settings singleton).
    private func withCleanCoverage(_ body: () throws -> Void) rethrows {
        let saved = AppSettings.shared.historyCoverage
        defer { AppSettings.shared.historyCoverage = saved }
        AppSettings.shared.historyCoverage = HistoryCoverageMap()
        try body()
    }

    /// A fresh backend + fake transport, already past pairing (mirrors `TrendArrowGateTests`' shape).
    private func makeBackend() -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        return (backend, fake)
    }

    /// Decodes a recorded `HistoryLogRequest` send's cargo (`[startLog(4, LE), numberOfLogs(1)]`,
    /// `HistoryLogRequests.swift:22-35`) back into its two fields, so a test can assert exactly which
    /// window was requested without re-parsing bytes inline at every call site.
    private func decodeHistoryLogRequest(_ sent: (opCode: UInt8, cargo: [UInt8], signed: Bool, allowDelivery: Bool))
        -> (startLog: UInt32, numberOfLogs: Int) {
        (Bytes.readUint32(sent.cargo, 0), Int(sent.cargo[4]))
    }

    // MARK: - Forward-gap delta sync

    /// A reconnect after a disconnect fetches only the sequences the pump logged during the gap —
    /// never a full re-walk of the whole available range.
    @Test func forwardGapAfterDisconnect() {
        withCleanCoverage {
            let (backend, fake) = makeBackend()

            // First connect: the pump reports 1...100; the sync fetches the whole thing (nothing held yet).
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 100, firstSequenceNum: 1, lastSequenceNum: 100))
            // Coverage credits only RECEIVED sequences, so the first sync must genuinely receive
            // the whole 1...100 window to hold [1...100] (a single reading would credit only [100...100]).
            injectHistoryStreamChunked(backend, stride(from: UInt32(100), through: UInt32(1), by: -1).map {
                (seq: $0, pumpTimeSec: UInt32(1_000) * $0, mgdl: 110) })
            backend.fireHistorySyncTickForTesting()   // debounce: window 1...100 exhausted → finishBackfill

            // Simulate a disconnect + reconnect where the pump now reports 1...130 — 30 NEW records were
            // logged during the gap. `fake.sent` is append-only (private(set)) from outside the fake, so
            // take the LAST matching send rather than clearing the log — the reconnect's own request.
            backend.applyClientState(.disconnected)
            backend.applyClientState(.ready)
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 130, firstSequenceNum: 1, lastSequenceNum: 130))

            let historyReq = fake.sent.last { $0.opCode == HistoryLogRequest.props.opCode }
            #expect(historyReq != nil, "the reconnect must request the forward gap")
            if let historyReq {
                let decoded = decodeHistoryLogRequest(historyReq)
                #expect(decoded.startLog == 101, "must start exactly above the held coverage, not re-walk from the top")
                #expect(decoded.numberOfLogs == 30, "must request only the 30 missing records (101...130)")
            }

            // The fetched forward-gap record reaches the in-memory history once its stream settles.
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(cgmReadings: [(seq: 130, pumpTimeSec: 200_000, mgdl: 140)]))
            backend.fireHistorySyncTickForTesting()
            #expect(backend.glucoseHistory.contains { $0.mgdl == 140 })
        }
    }

    /// A gap-filled record whose date is older than everything the app had already ingested must still
    /// reach GlucoseHistoryStore — a date-watermark filter would silently drop exactly this case.
    @Test func oldGapRecordPersists() {
        withCleanCoverage {
            let (backend, fake) = makeBackend()
            let model = AppModel(source: backend)
            let store = try! GlucoseHistoryStore(inMemory: true)
            model.setHistoryStoreForTesting(store)

            // First sync: one NEWER reading (pumpTimeSec far in the "future" relative to the older one
            // fetched below) advances what the app has already ingested.
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 100, firstSequenceNum: 1, lastSequenceNum: 100))
            // Receive the whole 1...100 window so held coverage is [1...100] and the second sync's
            // gap is exactly the forward window 101...130 (seq 100 stays the newest ingested reading).
            injectHistoryStreamChunked(backend, stride(from: UInt32(100), through: UInt32(1), by: -1).map {
                (seq: $0, pumpTimeSec: UInt32(5_000) * $0, mgdl: 111) })
            backend.fireHistorySyncTickForTesting()

            // Second sync (same connection, no need to disconnect — injecting another status response
            // directly is exactly what an unsolicited/second gap-check would produce): the pump's range
            // grew to 1...130; the interior/forward window 101...130 holds a record dated EARLIER
            // (pumpTimeSec 50) than the one already ingested above — exactly the case the date-watermark
            // filter used to drop.
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 130, firstSequenceNum: 1, lastSequenceNum: 130))
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(cgmReadings: [(seq: 105, pumpTimeSec: 50, mgdl: 77)]))
            backend.fireHistorySyncTickForTesting()   // finishBackfill → onChange → AppModel.refresh() → persistNewHistory

            _ = fake   // keep the fake alive for the duration of the assertions
            let stored = model.storedGlucoseForTesting(in: Date(timeIntervalSince1970: 0)...Date())
            #expect(stored.contains { $0.mgdl == 77 },
                    "an interior-gap record older than the previously-ingested reading must still persist")
        }
    }

    // MARK: - Interior-gap fill + retention bounding + coverage-survives-disconnect + safety cap

    /// Held coverage 1...50 and 80...130 over a 1...130 pump range must produce exactly the interior
    /// hole 51...79 — not just a trailing/forward gap.
    @Test func interiorGapDetected() {
        let held: [ClosedRange<UInt32>] = [1...50, 80...130]
        let missing = TandemBackend.missingRanges(pumpFirst: 1, pumpLast: 130, retentionFloor: 1, held: held)
        #expect(missing == [51...79])
    }

    /// `historyRetentionDays == 0` must resolve the retention floor to `pumpFirst` (the full available
    /// range), never an empty/"now" sentinel.
    @Test func retentionZeroMeansFullRange() {
        let floor = TandemBackend.retentionFloorSequence(pumpFirst: 10, pumpLast: 500, retentionDays: 0)
        #expect(floor == 10)
        let missing = TandemBackend.missingRanges(pumpFirst: 10, pumpLast: 500, retentionFloor: floor, held: [])
        #expect(missing == [10...500])
    }

    /// With `historyRetentionDays > 0`, the fetch floor must be a superset of the retention window
    /// (at or below its boundary — never under-fetching within it).
    @Test func retentionDaysBoundsFetch() {
        let floor = TandemBackend.retentionFloorSequence(pumpFirst: 10, pumpLast: 500, retentionDays: 30)
        #expect(floor <= 10, "the fetch floor must never sit ABOVE pumpFirst — that would under-fetch the retention window")
    }

    /// The persisted coverage map survives `linkDroppedCleanup` and a fresh AppSettings load, and the
    /// next connect resumes from it instead of re-walking from scratch.
    @Test func coverageSurvivesDisconnect() {
        withCleanCoverage {
            let (backend, fake) = makeBackend()
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 100, firstSequenceNum: 1, lastSequenceNum: 100))
            // Receive the whole 1...100 window so the credited (and persisted) coverage is [1...100].
            injectHistoryStreamChunked(backend, stride(from: UInt32(100), through: UInt32(1), by: -1).map {
                (seq: $0, pumpTimeSec: UInt32(1_000) * $0, mgdl: 100) })
            backend.fireHistorySyncTickForTesting()   // window 1...100 credited to AppSettings.shared.historyCoverage

            backend.applyClientState(.disconnected)   // linkDroppedCleanup — must NOT clear historyCoverage

            let fresh = AppSettings(defaults: .standard)
            #expect(fresh.historyCoverage.ranges == [1...100],
                    "the coverage map must survive both the disconnect cleanup and a fresh AppSettings load")

            // The next connect resumes: pump range grew to 1...110 — only the 10 new records are requested.
            backend.applyClientState(.ready)
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 110, firstSequenceNum: 1, lastSequenceNum: 110))
            let req = fake.sent.last { $0.opCode == HistoryLogRequest.props.opCode }
            #expect(req != nil)
            if let req {
                let decoded = decodeHistoryLogRequest(req)
                #expect(decoded.startLog == 101)
                #expect(decoded.numberOfLogs == 10)
            }
        }
    }

    /// A pathological coverage map — many isolated single-sequence holes — must never drive the sync
    /// past the page hard cap, no matter how many gap windows missingRanges computes.
    @Test func gapQueueSafetyCap() {
        withCleanCoverage {
            let (backend, fake) = makeBackend()
            // Hold every ODD sequence 1...999 — the pump's 1...1000 range then has 500 isolated
            // single-record EVEN gaps (2, 4, 6, ..., 1000), far more than any reasonable page cap.
            var held: [ClosedRange<UInt32>] = []
            var seq: UInt32 = 1
            while seq <= 999 { held.append(seq...seq); seq += 2 }
            AppSettings.shared.historyCoverage = HistoryCoverageMap(ranges: held)

            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 1000, firstSequenceNum: 1, lastSequenceNum: 1000))
            // Drive the debounce well past what draining all 500 windows would need — extra ticks after
            // the sync settles are harmless no-ops (mirrors the original backfill's own idempotent
            // finishBackfill re-entry shape).
            for _ in 0..<40 { backend.fireHistorySyncTickForTesting() }

            let pageCount = fake.sent.filter { $0.opCode == HistoryLogRequest.props.opCode }.count
            #expect(pageCount <= 20, "a pathological coverage map must never exceed the safety cap (got \(pageCount) requests)")
        }
    }

    // MARK: - Auto-sync toggle gate + manual "Sync now" trigger

    /// Save + restore `AppSettings.shared.historySyncEnabled` around a test, mirroring
    /// `withCleanCoverage`'s save/defer-restore idiom for the shared settings singleton.
    private func withHistorySyncEnabled(_ enabled: Bool, _ body: () throws -> Void) rethrows {
        let saved = AppSettings.shared.historySyncEnabled
        defer { AppSettings.shared.historySyncEnabled = saved }
        AppSettings.shared.historySyncEnabled = enabled
        try body()
    }

    /// The automatic on-connect gap-sync check (`HistoryLogStatusRequest`) must be suppressed entirely
    /// while `historySyncEnabled == false`, and must still run once it's `true`.
    @Test func autoSyncGateSuppressesOnConnect() {
        withCleanCoverage {
            withHistorySyncEnabled(false) {
                let (backendOff, fakeOff) = makeBackend()
                backendOff.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
                #expect(!fakeOff.sent.contains { $0.opCode == HistoryLogStatusRequest.props.opCode },
                        "the on-connect auto-sync check must be suppressed while the toggle is off")
            }
            withHistorySyncEnabled(true) {
                let (backendOn, fakeOn) = makeBackend()
                backendOn.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
                #expect(fakeOn.sent.contains { $0.opCode == HistoryLogStatusRequest.props.opCode },
                        "the on-connect check must still run once the toggle is enabled (Plan 01 regression)")
            }
        }
    }

    /// "Sync now" (`AppModel.syncHistoryNow()`) stays available even when the auto-sync toggle is OFF —
    /// the toggle only gates the automatic on-connect trigger, never the user's explicit manual request.
    @Test func syncNowTriggersGapSyncRegardlessOfToggle() {
        withCleanCoverage {
            withHistorySyncEnabled(false) {
                let (backend, fake) = makeBackend()
                let model = AppModel(source: backend)
                backend.setConnectionForTesting(.connected)   // "Sync now" requires an already-connected pump (bare .ready is only .connecting)

                model.syncHistoryNow()
                #expect(fake.sent.contains { $0.opCode == HistoryLogStatusRequest.props.opCode },
                        "\"Sync now\" must issue the gap-sync status check even while auto-sync is disabled")

                backend.injectStatusFrameForTesting(
                    FakePumpTransport.historyLogStatus(numEntries: 50, firstSequenceNum: 1, lastSequenceNum: 50))
                #expect(fake.sent.contains { $0.opCode == HistoryLogRequest.props.opCode },
                        "the manual trigger's response must still drive the gap-window fetch, disabled toggle notwithstanding")
            }
        }
    }

    // MARK: - Coverage is credited from RECEIVED sequences, never the request cursor

    /// `HistoryLogStreamResponse` frames carry a one-byte cargo length (`[count, streamId, records…]`),
    /// so a single injected frame can hold at most 9 × 26-byte records — inject a received sub-range in
    /// ≤9-record frames. Each frame accumulates into the current window's `receivedSeqsThisWindow`
    /// (`appendHistoryStreamFrame`); one `fireHistorySyncTickForTesting()` then credits from what landed.
    private func injectHistoryStreamChunked(
        _ backend: TandemBackend, _ readings: [(seq: UInt32, pumpTimeSec: UInt32, mgdl: Int)]) {
        var idx = 0
        while idx < readings.count {
            let chunk = Array(readings[idx..<min(idx + 9, readings.count)])
            backend.injectHistoryLogFrameForTesting(FakePumpTransport.historyLogStream(cgmReadings: chunk))
            idx += 9
        }
    }

    /// Partial receipt: the pump reports 1...100, but only the top contiguous sub-range is actually
    /// received before the stream stops. Coverage must credit only the received range so the gap is re-requested.
    @Test func partialReceiptCreditsOnlyReceivedSubRange() {
        withCleanCoverage {
            let (backend, _) = makeBackend()
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 100, firstSequenceNum: 1, lastSequenceNum: 100))

            // Only the top sub-range seq 100…60 arrives (the pump paged backward from the top, then went
            // silent before reaching 59) — 41 records injected across ≤9-record frames.
            let received: [(seq: UInt32, pumpTimeSec: UInt32, mgdl: Int)] =
                stride(from: UInt32(100), through: UInt32(60), by: -1).map { (seq: $0, pumpTimeSec: 1_000 + $0, mgdl: 110) }
            injectHistoryStreamChunked(backend, received)
            backend.fireHistorySyncTickForTesting()   // window 1...100 exhausted → credit received sub-range

            #expect(AppSettings.shared.historyCoverage.ranges == [60...100],
                    "only the RECEIVED top sub-range may be credited, never the un-received request cursor")
            #expect(TandemBackend.missingRanges(pumpFirst: 1, pumpLast: 100, retentionFloor: 1,
                                                held: AppSettings.shared.historyCoverage.ranges) == [1...59],
                    "the swallowed 1...59 must remain a resumable gap the next sync re-requests")
        }
    }

    /// Nothing received: a page is requested but no stream frame ever arrives. Coverage must stay empty
    /// — an un-received window is credited nothing.
    @Test func zeroFramesCreditNothing() {
        withCleanCoverage {
            let (backend, _) = makeBackend()
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 100, firstSequenceNum: 1, lastSequenceNum: 100))
            // No injectHistoryLogFrameForTesting — the requested page yields nothing.
            backend.fireHistorySyncTickForTesting()

            #expect(AppSettings.shared.historyCoverage.ranges.isEmpty,
                    "a window with nothing received must credit nothing to the coverage map")
        }
    }

    /// A fully-received window still credits its whole range — receipt-based crediting must not regress
    /// the ordinary fully-synced case.
    @Test func fullReceiptCreditsWholeRange() {
        withCleanCoverage {
            let (backend, _) = makeBackend()
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 9, firstSequenceNum: 1, lastSequenceNum: 9))
            let full: [(seq: UInt32, pumpTimeSec: UInt32, mgdl: Int)] =
                stride(from: UInt32(9), through: UInt32(1), by: -1).map { (seq: $0, pumpTimeSec: 1_000 + $0, mgdl: 120) }
            backend.injectHistoryLogFrameForTesting(FakePumpTransport.historyLogStream(cgmReadings: full))
            backend.fireHistorySyncTickForTesting()

            #expect(AppSettings.shared.historyCoverage.ranges == [1...9],
                    "a fully-received window must still credit its whole range (success-path regression)")
        }
    }
}
