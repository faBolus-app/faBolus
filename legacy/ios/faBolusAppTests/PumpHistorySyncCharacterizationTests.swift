import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Pins gap-aware history-log sync's request sequence, retry/pause, and zero delivery opcodes so a
/// coordinator extract cannot change the wire or sneak a delivery command onto the sync path.
@Suite(.serialized) @MainActor
struct PumpHistorySyncCharacterizationTests {

    private func makeBackend() -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        return (backend, fake)
    }

    private func withCleanCoverage(_ body: () throws -> Void) rethrows {
        let saved = AppSettings.shared.historyCoverage
        defer { AppSettings.shared.historyCoverage = saved }
        AppSettings.shared.historyCoverage = HistoryCoverageMap()
        try body()
    }

    /// Mirrors `HistoryLogSyncTests.decodeHistoryLogRequest` — decodes a recorded `HistoryLogRequest`
    /// send's cargo (`[startLog(4, LE), numberOfLogs(1)]`) back into its two fields.
    private func decodeHistoryLogRequest(_ sent: (opCode: UInt8, cargo: [UInt8], signed: Bool, allowDelivery: Bool))
        -> (startLog: UInt32, numberOfLogs: Int)
    {
        (Bytes.readUint32(sent.cargo, 0), Int(sent.cargo[4]))
    }

    /// Asserts zero delivery-seam opcodes/flags anywhere in `fake.sent` — the same belt-and-suspenders
    /// runtime proof `HistoryLogSyncDeliveryBoundaryTests.historySyncNeverReachesDeliverySeam` makes,
    /// re-asserted here per-scenario since this suite drives several distinct sync shapes.
    private func assertNoDeliverySeam(_ fake: FakePumpTransport) {
        let deliverySeamOpcodes: Set<UInt8> = [BolusPermissionRequest.props.opCode, InitiateBolusRequest.props.opCode]
        #expect(
            !fake.sent.contains { deliverySeamOpcodes.contains($0.opCode) },
            "history sync must never send a bolus-permission or initiate-bolus request")
        #expect(
            !fake.sent.contains { $0.allowDelivery },
            "no message the history-sync path sends may carry the delivery-elevation flag")
    }

    // MARK: - 1. Identical HistoryLogRequest sequence for a fixed range + held coverage

    @Test func exactRequestSequenceForFixedRangeAndCoverage() {
        withCleanCoverage {
            let (backend, fake) = makeBackend()
            AppSettings.shared.historyCoverage = HistoryCoverageMap(ranges: [1...100])

            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 130, firstSequenceNum: 1, lastSequenceNum: 130))

            let req = fake.sent.last { $0.opCode == HistoryLogRequest.props.opCode }
            #expect(req != nil, "a held-coverage-relative forward gap must issue exactly one page request")
            if let req {
                let decoded = decodeHistoryLogRequest(req)
                #expect(decoded.startLog == 101, "must start immediately above the held coverage")
                #expect(decoded.numberOfLogs == 30, "must request exactly the 30 missing records (101...130)")
            }
            assertNoDeliverySeam(fake)
        }
    }

    // MARK: - 2. neutralEvent normalization (representative mapped kind)

    @Test func neutralEventMapsBolusCompletedAndCarbEntered() {
        withCleanCoverage {
            let (backend, _) = makeBackend()
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 2, firstSequenceNum: 1, lastSequenceNum: 2))
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(
                    bolusRecords: [(seq: 1, pumpTimeSec: 5_000, delivered: 2.5, iob: 1.2)],
                    events: [FakePumpTransport.carbEnteredHistoryRecord(sequenceNum: 2, pumpTimeSec: 5_100, carbs: 30)])
            )
            backend.fireHistorySyncTickForTesting()

            let bolus = backend.historyEvents.first { $0.category == .bolus }
            #expect(bolus?.title == "Bolus delivered")
            #expect(bolus?.detail == "2.50 U")

            let carbs = backend.historyEvents.first { $0.category == .carbs }
            #expect(carbs?.title == "Carbs entered")
            #expect(carbs?.detail == "30 g")
        }
    }

    // MARK: - 3. receivedSeqsThisWindow top-anchored crediting for a mid-window drop

    @Test func topAnchoredCreditingOnMidWindowDrop() {
        withCleanCoverage {
            let (backend, _) = makeBackend()
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 100, firstSequenceNum: 1, lastSequenceNum: 100))

            // Only the top sub-range seq 100...60 arrives before the stream goes quiet.
            var idx = 0
            let received: [(seq: UInt32, pumpTimeSec: UInt32, mgdl: Int)] =
                stride(from: UInt32(100), through: UInt32(60), by: -1).map {
                    (seq: $0, pumpTimeSec: 1_000 + $0, mgdl: 110)
                }
            while idx < received.count {
                let chunk = Array(received[idx..<min(idx + 9, received.count)])
                backend.injectHistoryLogFrameForTesting(FakePumpTransport.historyLogStream(cgmReadings: chunk))
                idx += 9
            }
            backend.fireHistorySyncTickForTesting()

            #expect(
                AppSettings.shared.historyCoverage.ranges == [60...100],
                "only the received top sub-range may be credited")
            #expect(
                TandemBackend.missingRanges(
                    pumpFirst: 1, pumpLast: 100, retentionFloor: 1,
                    held: AppSettings.shared.historyCoverage.ranges) == [1...59],
                "the un-received 1...59 must remain a resumable gap")
        }
    }

    // MARK: - 4. Retry/paging order across two gap windows under the tick seam

    @Test func retryPagingOrderAcrossTwoWindows() {
        withCleanCoverage {
            let (backend, fake) = makeBackend()
            // Interior hole 300...400 and a forward gap 601...900 — the second wide enough (300 records)
            // to need two pages (255 + 45).
            AppSettings.shared.historyCoverage = HistoryCoverageMap(ranges: [1...299, 401...600])

            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 900, firstSequenceNum: 1, lastSequenceNum: 900))
            for _ in 0..<20 {
                backend.injectHistoryLogFrameForTesting(
                    FakePumpTransport.historyLogStream(cgmReadings: [(seq: 1, pumpTimeSec: 1, mgdl: 100)]))
                backend.fireHistorySyncTickForTesting()
            }

            let pages = fake.sent.filter { $0.opCode == HistoryLogRequest.props.opCode }.map(decodeHistoryLogRequest)
            #expect(
                pages.count == 3, "interior window (1 page) + forward window (2 pages, 255+45) == 3 total page requests"
            )
            if pages.count == 3 {
                // Interior window (401...600 is HELD, so the interior gap window is 300...400) is queued
                // FIRST (missingRanges returns windows in ascending order), and pages walk backward from
                // each window's own upper bound.
                #expect(
                    pages[0].startLog == 400 - (101 - 1),
                    "first page of the FIRST queued window (300...400) walks back from its own top")
                #expect(pages[0].numberOfLogs == 101)
                #expect(
                    pages[1].startLog == 900 - (255 - 1),
                    "first page of the forward window (601...900) walks back from 900")
                #expect(pages[1].numberOfLogs == 255)
                #expect(pages[2].startLog == 601, "second page of the forward window finishes at its lower bound")
                #expect(pages[2].numberOfLogs == 45)
            }
            assertNoDeliverySeam(fake)
        }
    }

    // MARK: - 5a. .syncing -> .paused on link drop

    @Test func syncingTransitionsToPausedOnLinkDrop() {
        withCleanCoverage {
            let (backend, _) = makeBackend()
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 100, firstSequenceNum: 1, lastSequenceNum: 100))
            #expect(backend.historySyncState == .syncing, "a nonempty gap must start the sync as .syncing")

            backend.applyClientState(.disconnected)
            #expect(
                backend.historySyncState == .paused,
                "a link drop mid-sync must resolve to the benign, resumable .paused state, never an error")
        }
    }

    // MARK: - 5b. .idle(lastSynced:) on an already-fully-covered diff

    @Test func fullyCoveredDiffResolvesToIdle() {
        withCleanCoverage {
            let (backend, fake) = makeBackend()
            AppSettings.shared.historyCoverage = HistoryCoverageMap(ranges: [1...100])

            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 100, firstSequenceNum: 1, lastSequenceNum: 100))

            guard case .idle(let lastSynced) = backend.historySyncState else {
                Issue.record("expected .idle after a fully-covered diff, got \(backend.historySyncState)")
                return
            }
            #expect(lastSynced != nil, "a confirmed-up-to-date check is still a completed sync")
            #expect(
                !fake.sent.contains { $0.opCode == HistoryLogRequest.props.opCode },
                "a fully-covered diff must never issue a page request")
            assertNoDeliverySeam(fake)
        }
    }

    // MARK: - 5c. The unparseable-historyLog .error branch

    @Test func unparseableHistoryLogFrameSetsErrorState() {
        withCleanCoverage {
            let (backend, fake) = makeBackend()
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 100, firstSequenceNum: 1, lastSequenceNum: 100))
            #expect(backend.historySyncState == .syncing)

            // A malformed/unregistered frame on the HISTORY_LOG characteristic while a backfill is active
            // fails ResponseParser.parse — the genuine-sync-failure branch, distinct from a benign drop.
            backend.injectHistoryLogFrameForTesting([0xFF, 0xFF, 0xFF])

            #expect(backend.historySyncState == .error("Sync error — try again, or check the pump connection."))
            assertNoDeliverySeam(fake)
        }
    }

    // MARK: - 6. Zero delivery opcodes, exhaustively, across a full multi-window sync

    @Test func zeroDeliveryOpcodesAcrossFullMultiWindowSync() {
        withCleanCoverage {
            let (backend, fake) = makeBackend()
            AppSettings.shared.historyCoverage = HistoryCoverageMap(ranges: [1...299, 401...600])
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 900, firstSequenceNum: 1, lastSequenceNum: 900))
            for _ in 0..<20 {
                backend.injectHistoryLogFrameForTesting(
                    FakePumpTransport.historyLogStream(cgmReadings: [(seq: 1, pumpTimeSec: 1, mgdl: 100)]))
                backend.fireHistorySyncTickForTesting()
            }
            #expect(!fake.sent.isEmpty, "sanity: the sync must have actually sent history-log requests")
            assertNoDeliverySeam(fake)
        }
    }
}
