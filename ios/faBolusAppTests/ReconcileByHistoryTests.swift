import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// `reconcile(bolusId:)` and `reconcileIndeterminateDelivery()` route through a shared bounded
/// exact-id `findBolusInHistory(bolusId:)` primitive instead of giving up when the pump's LAST bolus is
/// a NEWER id — closing the indefinite-lockout gap while staying fail-closed on genuine exhaustion.
/// Every scenario here drives the history seam through the REAL parse path
/// (`injectHistoryLogFrameForTesting` — a real `HistoryLogStreamResponse` frame), never
/// `MockBackend.reconcileResultsById`, which would only prove mocked behavior.
@Suite(.serialized) @MainActor
struct ReconcileByHistoryTests {

    private func makeBackend() -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        // Keep the negative/bounded-search tests fast and deterministic — no real multi-second waits.
        backend.historySearchPageTimeoutOverride = 0.08
        return (backend, fake)
    }

    /// `findBolusInHistory`'s status probe reaches the SAME passive dispatch the routine on-connect
    /// gap-sync check does (any `HistoryLogStatusResponse` can trigger `beginGapSync` when a real
    /// backfill isn't already active). Pre-covering the whole probed range neutralizes that side effect
    /// so it can't start a COMPETING backfill mid-test (which would pollute `fake.sent`'s page count and
    /// `AppSettings.shared.historyCoverage`) — mirrors `HistoryLogSyncTests`' `withCleanCoverage` idiom.
    private func withNoCompetingBackfill(_ body: () async throws -> Void) async rethrows {
        let saved = AppSettings.shared.historyCoverage
        defer { AppSettings.shared.historyCoverage = saved }
        AppSettings.shared.historyCoverage = HistoryCoverageMap(ranges: [1...1_000_000])
        try await body()
    }

    private func scriptLastBolus(_ fake: FakePumpTransport, bolusId: Int, deliveredMilliunits: UInt32 = 2000) {
        fake.script(
            LastBolusStatusV2Response.props.opCode,
            .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: deliveredMilliunits)))
    }
    private func scriptHistoryStatus(_ fake: FakePumpTransport, numEntries: UInt32, first: UInt32, last: UInt32) {
        fake.script(
            HistoryLogStatusResponse.props.opCode,
            .frame(
                FakePumpTransport.historyLogStatus(
                    numEntries: numEntries, firstSequenceNum: first, lastSequenceNum: last)))
    }

    // MARK: - reconcile(bolusId:) — newer-intervening-bolus resolved by exact-id history search

    /// Unresolved bolusId B; the pump's LAST bolus is a NEWER id C != B — the fast path misses. A
    /// `HistoryLogStreamResponse` frame carrying a type-20 `BolusCompletedHistoryLog`-shaped record for B
    /// (via TandemKit's `BolusHistoryRecord.bolusId`) is injected on the
    /// REAL parse path → `reconcile(B)` must resolve by finding B in history by EXACT id, clearing the
    /// hold — never `.unavailable`-forever just because a newer bolus intervened.
    @Test func newerInterveningBolusResolvesByExactIdHistorySearch() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let unresolvedId = 500, newerId = 900
            scriptLastBolus(fake, bolusId: newerId)
            scriptHistoryStatus(fake, numEntries: 1000, first: 1, last: 1000)

            let task = Task { await backend.reconcile(bolusId: unresolvedId) }
            try? await Task.sleep(nanoseconds: 150_000_000)
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(bolusRecordsById: [
                    (
                        seq: 995, pumpTimeSec: 900_000, bolusId: unresolvedId, delivered: 1.5, iob: 0.5,
                        completionStatusId: 3
                    )
                ]))
            let result = await task.value
            #expect(result == .resolved(deliveredUnits: 1.5, cancelled: false))
        }
    }

    /// A 0U/partial completed record for the target id must still resolve the hold (TandemKit's
    /// accept-0U decode) — a cancelled-before-any-insulin bolus is a real, known outcome, not an
    /// unresolvable one.
    @Test func zeroUnitHistoryRecordStillResolves() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let unresolvedId = 501, newerId = 901
            scriptLastBolus(fake, bolusId: newerId)
            scriptHistoryStatus(fake, numEntries: 1000, first: 1, last: 1000)

            let task = Task { await backend.reconcile(bolusId: unresolvedId) }
            try? await Task.sleep(nanoseconds: 150_000_000)
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(bolusRecordsById: [
                    (
                        seq: 994, pumpTimeSec: 900_100, bolusId: unresolvedId, delivered: 0, iob: 0.1,
                        completionStatusId: 5
                    )
                ]))
            let result = await task.value
            #expect(result == .resolved(deliveredUnits: 0, cancelled: false))
        }
    }

    /// NEGATIVE PATH: no history record for B ever lands (bounded search exhausted) → `reconcile(B)`
    /// must still return `.unavailable` — the block persists, fail-closed (no blind retry, no
    /// assume-not-delivered).
    @Test func exhaustedSearchWithNoMatchStaysUnavailable() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let unresolvedId = 502, newerId = 902
            scriptLastBolus(fake, bolusId: newerId)
            scriptHistoryStatus(fake, numEntries: 500, first: 1, last: 500)
            // No injectHistoryLogFrameForTesting call — the bounded search finds nothing.
            let result = await backend.reconcile(bolusId: unresolvedId)
            #expect(result == .unavailable)
        }
    }

    /// BOUNDED: the search must halt at the page cap, never walk the whole available range unbounded.
    /// A 500 000-entry range at 255 records/page would need ~1961 pages to walk in full; the search must
    /// stop at its own small page cap regardless.
    @Test func searchHaltsAtThePageCapNeverWalksUnbounded() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let unresolvedId = 503, newerId = 903
            scriptLastBolus(fake, bolusId: newerId)
            scriptHistoryStatus(fake, numEntries: 500_000, first: 1, last: 500_000)
            let result = await backend.reconcile(bolusId: unresolvedId)
            #expect(result == .unavailable)
            let pageCount = fake.sent.filter { $0.opCode == HistoryLogRequest.props.opCode }.count
            #expect(
                pageCount <= 4,
                "the exact-id search must stop at its own small page cap (got \(pageCount) page requests)")
            #expect(pageCount > 0, "the search must have actually tried at least one page before giving up")
        }
    }

    /// The existing `lastBolusStatus` fast path (the pump's LAST bolus record matches exactly) still
    /// resolves as before, with NO history request issued at all — the fast path must not regress now
    /// that the history fallback exists.
    @Test func matchingLastBolusStillResolvesViaFastPathNoHistoryRequest() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let bolusId = 504
            scriptLastBolus(fake, bolusId: bolusId, deliveredMilliunits: 3250)
            let result = await backend.reconcile(bolusId: bolusId)
            #expect(result == .resolved(deliveredUnits: 3.25, cancelled: false))
            #expect(
                !fake.sent.contains { $0.opCode == HistoryLogRequest.props.opCode },
                "the unchanged fast path must never fall through to a history request")
            #expect(
                !fake.sent.contains { $0.opCode == HistoryLogStatusRequest.props.opCode },
                "the unchanged fast path must never even probe the history range")
        }
    }

    /// A 16-bit `bolusId` wraps after 65536 boluses, so a single page CAN contain two records that
    /// share the same id (an old id-reused record and the current one). `bolusRecords` preserves ascending
    /// wire/sequence order within a page, so the intra-page match must be `last(where:)` — the NEWEST
    /// (highest-sequence) record — never `first(where:)` (the oldest). Reconciliation is always for the
    /// most-recently-sent bolus id. This injects one frame with two same-id records (older first, newer
    /// last) and asserts the NEWER record's delivered amount is the one returned.
    @Test func sameIdWithinPageResolvesToTheNewerLaterInPageRecord() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let reusedId = 505, newerId = 905
            scriptLastBolus(fake, bolusId: newerId)
            scriptHistoryStatus(fake, numEntries: 1000, first: 1, last: 1000)

            let task = Task { await backend.reconcile(bolusId: reusedId) }
            try? await Task.sleep(nanoseconds: 150_000_000)
            // Ascending wire order within the page: the OLDER id-reused record (seq 100, delivered 1.0)
            // comes first, the NEWER current record (seq 990, delivered 2.5) comes last. `last(where:)`
            // must pick the newer one — `first(where:)` — the pre-existing bug this pins — would have picked 1.0.
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(bolusRecordsById: [
                    (
                        seq: 100, pumpTimeSec: 100_000, bolusId: reusedId, delivered: 1.0, iob: 0.3,
                        completionStatusId: 3
                    ),
                    (seq: 990, pumpTimeSec: 900_000, bolusId: reusedId, delivered: 2.5, iob: 0.9, completionStatusId: 3)
                ]))
            let result = await task.value
            #expect(
                result == .resolved(deliveredUnits: 2.5, cancelled: false),
                "the NEWEST (later-in-page) same-id record must win — got \(result)")
        }
    }

    // MARK: - reconcileIndeterminateDelivery() — the SAME shared primitive, invoked on reconnect

    /// A dropped initiate response leaves the delivery INDETERMINATE (the real `perform` flow —
    /// mirrors `TandemDeliveryOutcomeTests.droppedInitiateResponseIsIndeterminate`), pinning
    /// the pump-assigned id as `unknownOutcomeBolusId`. A LATER `lastBolusStatus` reporting a NEWER id
    /// (some other client's bolus intervened) must no longer lock `reconcileIndeterminateDelivery()` out
    /// forever — it must resolve via the SAME shared exact-id history search `reconcile(bolusId:)` uses.
    @Test func reconcileIndeterminateDeliveryResolvesTheSameNewerInterveningCaseViaSharedPrimitive() async {
        await withNoCompetingBackfill {
            let fake = FakePumpTransport()
            let backend = TandemBackend(testTransport: fake)
            backend.historySearchPageTimeoutOverride = 0.08
            let assignedId = 1234
            fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
            fake.script(
                BolusPermissionResponse.props.opCode, .frame(FakePumpTransport.permissionGranted(bolusId: assignedId)))
            fake.script(
                InitiateBolusResponse.props.opCode,
                .tx(.timedOut(characteristic: .control, opCode: InitiateBolusResponse.props.opCode)))
            _ = try? await backend.deliverBolus(units: 2.0, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
            #expect(backend.deliveryOutcomeUnknown)  // precondition: genuinely indeterminate

            let newerId = 9999
            scriptLastBolus(fake, bolusId: newerId)
            scriptHistoryStatus(fake, numEntries: 2000, first: 1, last: 2000)

            let task = Task { await backend.reconcileIndeterminateDelivery() }
            try? await Task.sleep(nanoseconds: 150_000_000)
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(bolusRecordsById: [
                    (
                        seq: 1990, pumpTimeSec: 900_500, bolusId: assignedId, delivered: 2.0, iob: 1.0,
                        completionStatusId: 3
                    )
                ]))
            let delivered = await task.value
            #expect(delivered == 2.0)
            #expect(!backend.deliveryOutcomeUnknown, "the hold must clear once the history search resolves the id")
        }
    }

    /// NEGATIVE PATH mirror for `reconcileIndeterminateDelivery()`: an exhausted search with no match
    /// must leave the block HELD (return nil), never clearing `deliveryOutcomeUnknown` on a guess.
    @Test func reconcileIndeterminateDeliveryStaysBlockedWhenSearchExhausted() async {
        await withNoCompetingBackfill {
            let fake = FakePumpTransport()
            let backend = TandemBackend(testTransport: fake)
            backend.historySearchPageTimeoutOverride = 0.08
            let assignedId = 1235
            fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
            fake.script(
                BolusPermissionResponse.props.opCode, .frame(FakePumpTransport.permissionGranted(bolusId: assignedId)))
            fake.script(
                InitiateBolusResponse.props.opCode,
                .tx(.timedOut(characteristic: .control, opCode: InitiateBolusResponse.props.opCode)))
            _ = try? await backend.deliverBolus(units: 1.0, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
            #expect(backend.deliveryOutcomeUnknown)

            scriptLastBolus(fake, bolusId: 9998)
            scriptHistoryStatus(fake, numEntries: 500, first: 1, last: 500)
            // No matching frame injected.
            let delivered = await backend.reconcileIndeterminateDelivery()
            #expect(delivered == nil)
            #expect(backend.deliveryOutcomeUnknown, "an exhausted search must NEVER clear the hold on a guess")
        }
    }
}
