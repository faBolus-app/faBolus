import Testing
import Foundation
import faBolusCore
import HistoryStore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Phase 09.7-01 (D-02/D-03/D-04 + Pitfall 3 fix). Replaces the one-shot, backward-only,
/// once-ever-gated history backfill with a gap-aware delta sync: on every connect, `TandemBackend`
/// reconciles the pump's reported `[firstSequenceNum, lastSequenceNum]` range against the persisted
/// `AppSettings.historyCoverage` map and fetches ONLY the missing sequence windows — both the
/// trailing/forward gap (records logged during a disconnect) and any interior/non-sequential holes.
///
/// No existing test touched this path at all before this phase (RESEARCH Pitfall 5) — every scenario
/// here is new coverage, not a regression guard on prior behavior.
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

    // MARK: - Task 1 (TRACER): forward-gap delta sync end-to-end + persistNewHistory fix

    /// D-02 (forward gap): a reconnect after a disconnect fetches ONLY the sequences the pump logged
    /// during the gap — never a full re-walk of the whole available range. Must fail against the old
    /// once-ever backward walk (which re-fetches unconditionally on the flag's one-shot trigger and does
    /// not persist any coverage state to diff against).
    @Test func forwardGapAfterDisconnect() {
        withCleanCoverage {
            let (backend, fake) = makeBackend()

            // First connect: the pump reports 1...100; the sync fetches the whole thing (nothing held yet).
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 100, firstSequenceNum: 1, lastSequenceNum: 100))
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(cgmReadings: [(seq: 100, pumpTimeSec: 100_000, mgdl: 110)]))
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

    /// Pitfall 3 fix: a gap-filled record whose date is OLDER than everything the app had already
    /// ingested must still reach `GlucoseHistoryStore` — the old `$0.date > lastGlucoseIngest`
    /// date-watermark filter silently dropped exactly this case.
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
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(cgmReadings: [(seq: 100, pumpTimeSec: 500_000, mgdl: 111)]))
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

    // MARK: - Task 2: interior-gap fill + retention bounding + coverage-survives-disconnect + safety cap

    /// D-02 (interior gap): held coverage 1...50 and 80...130 over a 1...130 pump range must produce
    /// exactly the interior hole 51...79 — not just a trailing/forward gap.
    @Test func interiorGapDetected() {
        let held: [ClosedRange<UInt32>] = [1...50, 80...130]
        let missing = TandemBackend.missingRanges(pumpFirst: 1, pumpLast: 130, retentionFloor: 1, held: held)
        #expect(missing == [51...79])
    }

    /// D-03/Pitfall 1: `historyRetentionDays == 0` must resolve the retention floor to `pumpFirst` (the
    /// full available range), never an empty/"now" sentinel.
    @Test func retentionZeroMeansFullRange() {
        let floor = TandemBackend.retentionFloorSequence(pumpFirst: 10, pumpLast: 500, retentionDays: 0)
        #expect(floor == 10)
        let missing = TandemBackend.missingRanges(pumpFirst: 10, pumpLast: 500, retentionFloor: floor, held: [])
        #expect(missing == [10...500])
    }

    /// D-03: with `historyRetentionDays > 0`, the fetch floor must be a SUPERSET of the retention window
    /// (at or below its boundary — never under-fetching within it). Exact date-boundary pruning is left
    /// to `AppModel.applyRetention`'s existing store-side deletion (the two-place retention design
    /// recorded in the plan SUMMARY).
    @Test func retentionDaysBoundsFetch() {
        let floor = TandemBackend.retentionFloorSequence(pumpFirst: 10, pumpLast: 500, retentionDays: 30)
        #expect(floor <= 10, "the fetch floor must never sit ABOVE pumpFirst — that would under-fetch the retention window")
    }

    /// D-04: the persisted coverage map survives `linkDroppedCleanup` (via `applyClientState(.disconnected)`)
    /// AND a fresh `AppSettings` load (proving real UserDefaults persistence, not just an in-memory
    /// struct), and the next connect resumes from it instead of re-walking from scratch.
    @Test func coverageSurvivesDisconnect() {
        withCleanCoverage {
            let (backend, fake) = makeBackend()
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 100, firstSequenceNum: 1, lastSequenceNum: 100))
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(cgmReadings: [(seq: 100, pumpTimeSec: 100_000, mgdl: 100)]))
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

    /// T-09.7-02 (DoS/battery): a pathological coverage map — many isolated single-sequence holes —
    /// must never drive the sync past the existing `backfillMaxPages`-style hard cap, no matter how many
    /// gap windows `missingRanges` computes.
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

    // MARK: - Plan 02 (D-01/D-05): auto-sync toggle gate + manual "Sync now" trigger

    /// Save + restore `AppSettings.shared.historySyncEnabled` around a test, mirroring
    /// `withCleanCoverage`'s save/defer-restore idiom for the shared settings singleton.
    private func withHistorySyncEnabled(_ enabled: Bool, _ body: () throws -> Void) rethrows {
        let saved = AppSettings.shared.historySyncEnabled
        defer { AppSettings.shared.historySyncEnabled = saved }
        AppSettings.shared.historySyncEnabled = enabled
        try body()
    }

    /// D-01: the AUTOMATIC on-connect gap-sync check (`HistoryLogStatusRequest`) must be suppressed
    /// entirely while `historySyncEnabled == false`, and must still run once it's `true` (a regression
    /// guard on Plan 01's on-connect behavior now that it's gated).
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

    /// UI-SPEC assumption 2: "Sync now" (`AppModel.syncHistoryNow()`) stays available and functional
    /// even when the auto-sync toggle is OFF — the toggle only gates the AUTOMATIC on-connect trigger,
    /// never the user's explicit manual request. Drives the response through to confirm the manual path
    /// reaches the same gap-sync entry point as the on-connect flow (a real `HistoryLogRequest` fetch),
    /// not just an inert status read.
    @Test func syncNowTriggersGapSyncRegardlessOfToggle() {
        withCleanCoverage {
            withHistorySyncEnabled(false) {
                let (backend, fake) = makeBackend()
                let model = AppModel(source: backend)
                backend.applyClientState(.ready)   // "Sync now" requires an already-connected pump

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
}
