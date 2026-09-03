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
                        completionStatusId: 3, insulinRequested: nil
                    )
                ]))
            let result = await task.value
            #expect(result == .resolved(deliveredUnits: 1.5, cancelled: false))
        }
    }

    /// A 0U completed record for the target id must still resolve the hold (TandemKit's accept-0U
    /// decode) — a cancelled-before-any-insulin bolus is a real, known outcome, not an unresolvable one.
    /// `insulinRequested: 0` alongside `delivered: 0` means the requested amount is unpopulated as much
    /// as it means "0 of 0" — either reading settles the same honest way, with no completeness claim
    /// asserted either way.
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
                        completionStatusId: 5, insulinRequested: 0
                    )
                ]))
            let result = await task.value
            #expect(result == .resolved(deliveredUnits: 0, cancelled: false))
        }
    }

    // MARK: - Terminal-evidence rule — classify from requested-vs-delivered amounts, never the status enum

    /// A proven-terminal record whose delivered amount matches the requested amount (within the pump's
    /// own 0.05 U increment tolerance) resolves complete — `cancelled: false`.
    @Test func completeDeliveryWithinToleranceResolvesNotCancelled() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let unresolvedId = 510, newerId = 910
            scriptLastBolus(fake, bolusId: newerId)
            scriptHistoryStatus(fake, numEntries: 1000, first: 1, last: 1000)

            let task = Task { await backend.reconcile(bolusId: unresolvedId) }
            try? await Task.sleep(nanoseconds: 150_000_000)
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(bolusRecordsById: [
                    (
                        seq: 995, pumpTimeSec: 900_000, bolusId: unresolvedId, delivered: 2.0, iob: 0.5,
                        completionStatusId: 3, insulinRequested: 2.0
                    )
                ]))
            let result = await task.value
            #expect(result == .resolved(deliveredUnits: 2.0, cancelled: false))
        }
    }

    /// A genuinely complete bolus differing from its requested amount only in the last float bit
    /// (well inside the 0.05 U tolerance) must classify complete, not partial.
    @Test func completeDeliveryDifferingInLastFloatBitStillResolvesComplete() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let unresolvedId = 511, newerId = 911
            scriptLastBolus(fake, bolusId: newerId)
            scriptHistoryStatus(fake, numEntries: 1000, first: 1, last: 1000)

            let task = Task { await backend.reconcile(bolusId: unresolvedId) }
            try? await Task.sleep(nanoseconds: 150_000_000)
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(bolusRecordsById: [
                    (
                        seq: 995, pumpTimeSec: 900_000, bolusId: unresolvedId, delivered: 2.0, iob: 0.5,
                        completionStatusId: 3, insulinRequested: 2.0 + 1e-6
                    )
                ]))
            let result = await task.value
            #expect(result == .resolved(deliveredUnits: 2.0, cancelled: false))
        }
    }

    /// A record proving a partial delivery beyond tolerance, whose `completionStatusId` marks a
    /// user-terminated stop (0), settles TERMINAL — released from the block — with the cancelled
    /// wording, never staying blocked.
    @Test func partialDeliveryWithUserTerminatedStatusResolvesCancelled() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let unresolvedId = 512, newerId = 912
            scriptLastBolus(fake, bolusId: newerId)
            scriptHistoryStatus(fake, numEntries: 1000, first: 1, last: 1000)

            let task = Task { await backend.reconcile(bolusId: unresolvedId) }
            try? await Task.sleep(nanoseconds: 150_000_000)
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(bolusRecordsById: [
                    (
                        seq: 995, pumpTimeSec: 900_000, bolusId: unresolvedId, delivered: 1.0, iob: 0.5,
                        completionStatusId: 0, insulinRequested: 2.0
                    )
                ]))
            let result = await task.value
            #expect(result == .resolved(deliveredUnits: 1.0, cancelled: true))
        }
    }

    /// A record proving the SAME partial delivery, but whose `completionStatusId` is a stop reason other
    /// than user-terminated (here: `STOPPED_WIRELESS`), still settles TERMINAL — released, never staying
    /// blocked — but without the cancelled label: the defect this rule closes was releasing over a
    /// RUNNING bolus, not over a genuinely-finished partial one, and the delivered amount is reported
    /// either way with no completeness claim attached.
    @Test func partialDeliveryWithNonUserTerminatedStatusResolvesWithoutCancelledLabel() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let unresolvedId = 513, newerId = 913
            scriptLastBolus(fake, bolusId: newerId)
            scriptHistoryStatus(fake, numEntries: 1000, first: 1, last: 1000)

            let task = Task { await backend.reconcile(bolusId: unresolvedId) }
            try? await Task.sleep(nanoseconds: 150_000_000)
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(bolusRecordsById: [
                    (
                        seq: 995, pumpTimeSec: 900_000, bolusId: unresolvedId, delivered: 1.0, iob: 0.5,
                        completionStatusId: 4, insulinRequested: 2.0
                    )
                ]))
            let result = await task.value
            #expect(result == .resolved(deliveredUnits: 1.0, cancelled: false))
        }
    }

    /// A requested amount reported as 0 alongside a non-zero delivered amount means the field isn't
    /// populated on this pump, not that zero units were genuinely requested. Settle as today
    /// (`cancelled: false`) — completeness is unverifiable and must never be asserted either way.
    @Test func requestedAmountUnknownSettlesWithoutCancelledLabel() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let unresolvedId = 514, newerId = 914
            scriptLastBolus(fake, bolusId: newerId)
            scriptHistoryStatus(fake, numEntries: 1000, first: 1, last: 1000)

            let task = Task { await backend.reconcile(bolusId: unresolvedId) }
            try? await Task.sleep(nanoseconds: 150_000_000)
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(bolusRecordsById: [
                    (
                        seq: 995, pumpTimeSec: 900_000, bolusId: unresolvedId, delivered: 1.5, iob: 0.5,
                        completionStatusId: 0, insulinRequested: 0
                    )
                ]))
            let result = await task.value
            #expect(result == .resolved(deliveredUnits: 1.5, cancelled: false))
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
            // op-45 must show this exact id NOT active for the fast path to be eligible at all.
            fake.script(
                CurrentBolusStatusResponse.props.opCode, .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
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

    // MARK: - Fast-path op-45 liveness gate

    /// When op-45 reports the queried id STILL active, the fast path must never settle from op-165 —
    /// it falls through to the bounded history page walk instead, never returning a partial over a
    /// running bolus.
    @Test func fastPathDoesNotSettleWhileOp45ShowsTheExactIdStillActive() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let bolusId = 520
            fake.script(
                CurrentBolusStatusResponse.props.opCode, .frame(FakePumpTransport.currentBolusStatus(statusId: 1, bolusId: bolusId)))
            scriptLastBolus(fake, bolusId: bolusId, deliveredMilliunits: 1000)  // would be a partial if trusted
            scriptHistoryStatus(fake, numEntries: 1000, first: 1, last: 1000)

            let task = Task { await backend.reconcile(bolusId: bolusId) }
            try? await Task.sleep(nanoseconds: 150_000_000)
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(bolusRecordsById: [
                    (
                        seq: 995, pumpTimeSec: 900_000, bolusId: bolusId, delivered: 2.0, iob: 0.5,
                        completionStatusId: 3, insulinRequested: 2.0
                    )
                ]))
            let result = await task.value
            #expect(
                result == .resolved(deliveredUnits: 2.0, cancelled: false),
                "an active id at op-45 must fall through to history, never settle the still-running bolus from op-165")
            #expect(fake.sent.contains { $0.opCode == HistoryLogRequest.props.opCode })
        }
    }

    /// A refused/unavailable op-45 makes the fast path unusable — it falls through to the bounded
    /// history page walk unconditionally, never treating a refusal as "not active."
    @Test func fastPathFallsThroughToHistoryWhenOp45IsRefused() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let bolusId = 521
            // No CurrentBolusStatusResponse script → defaults to a dropped/timed-out response (refused).
            scriptLastBolus(fake, bolusId: bolusId, deliveredMilliunits: 2000)
            scriptHistoryStatus(fake, numEntries: 1000, first: 1, last: 1000)

            let task = Task { await backend.reconcile(bolusId: bolusId) }
            try? await Task.sleep(nanoseconds: 150_000_000)
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(bolusRecordsById: [
                    (
                        seq: 995, pumpTimeSec: 900_000, bolusId: bolusId, delivered: 2.0, iob: 0.5,
                        completionStatusId: 3, insulinRequested: 2.0
                    )
                ]))
            let result = await task.value
            #expect(result == .resolved(deliveredUnits: 2.0, cancelled: false))
            #expect(fake.sent.contains { $0.opCode == HistoryLogRequest.props.opCode })
        }
    }

    /// When op-45 reports the queried id is NOT active, the fast path settles from the matching op-165
    /// record exactly as before — no history request issued.
    @Test func fastPathSettlesFromOp165WhenOp45ShowsTheExactIdNotActive() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let bolusId = 522
            fake.script(
                CurrentBolusStatusResponse.props.opCode, .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
            scriptLastBolus(fake, bolusId: bolusId, deliveredMilliunits: 2000)
            let result = await backend.reconcile(bolusId: bolusId)
            #expect(result == .resolved(deliveredUnits: 2.0, cancelled: false))
            #expect(!fake.sent.contains { $0.opCode == HistoryLogRequest.props.opCode })
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
                        completionStatusId: 3, insulinRequested: nil
                    ),
                    (
                        seq: 990, pumpTimeSec: 900_000, bolusId: reusedId, delivered: 2.5, iob: 0.9,
                        completionStatusId: 3, insulinRequested: nil
                    ),
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
                        completionStatusId: 3, insulinRequested: nil
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

    // MARK: - findBolusInHistory reentrancy guard
    //
    // Two reconcile triggers (`onPaired`, the `.connected` edge, launch) can land inside
    // `findBolusInHistory` on the same fresh-connect edge. The entry guard must fail an overlapping
    // call closed instead of sharing/corrupting the in-flight search's bookkeeping.

    /// A second call for a DIFFERENT id arrives while the first call's history search is already in
    /// flight — it must fail closed to `.unavailable` immediately, and the first call's own search must
    /// resolve correctly against ITS OWN id, unaffected.
    @Test func overlappingReconcileCallWhileASearchIsInFlightFailsClosedAndNeverCorruptsTheInFlightSearch() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let firstId = 600, secondId = 700, newerId = 906
            scriptLastBolus(fake, bolusId: newerId)
            scriptHistoryStatus(fake, numEntries: 1000, first: 1, last: 1000)

            let firstTask = Task { await backend.reconcile(bolusId: firstId) }
            try? await Task.sleep(nanoseconds: 150_000_000)  // let the first call reach the in-flight search

            let overlappingResult = await backend.reconcile(bolusId: secondId)
            #expect(
                overlappingResult == .unavailable,
                "an overlapping call must fail closed, never queue behind or share the in-flight search")

            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(bolusRecordsById: [
                    (
                        seq: 995, pumpTimeSec: 900_000, bolusId: firstId, delivered: 1.25, iob: 0.5,
                        completionStatusId: 3, insulinRequested: nil
                    )
                ]))
            let firstResult = await firstTask.value
            #expect(
                firstResult == .resolved(deliveredUnits: 1.25, cancelled: false),
                "the overlapping call must never corrupt the first call's own in-flight search")
        }
    }

    /// The guard must leave no residue: once the first call's search settles (its `defer` clears
    /// `historySearchTarget`), a fresh call for the id that failed closed during the overlap must reach
    /// the pump normally — the guard only fails the OVERLAPPING window closed, not the id forever.
    @Test func idThatFailedClosedDuringAnOverlapCanStillResolveOnANonOverlappingRetry() async {
        await withNoCompetingBackfill {
            let (backend, fake) = makeBackend()
            let firstId = 601, secondId = 701, newerId = 907
            // op-45 must show each queried id NOT active for its fast path to even be attempted —
            // otherwise the fast path is skipped closed and `lastBolusStatus()` (below) is never called,
            // leaving this queued reply stuck for a LATER call to consume out of order.
            fake.script(
                CurrentBolusStatusResponse.props.opCode, .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: firstId)))
            scriptLastBolus(fake, bolusId: newerId)
            scriptHistoryStatus(fake, numEntries: 1000, first: 1, last: 1000)

            let firstTask = Task { await backend.reconcile(bolusId: firstId) }
            try? await Task.sleep(nanoseconds: 150_000_000)
            let overlappingResult = await backend.reconcile(bolusId: secondId)
            #expect(overlappingResult == .unavailable)

            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(bolusRecordsById: [
                    (
                        seq: 995, pumpTimeSec: 900_000, bolusId: firstId, delivered: 1.0, iob: 0.5,
                        completionStatusId: 3, insulinRequested: nil
                    )
                ]))
            _ = await firstTask.value  // the first search settles, clearing historySearchTarget via its defer

            fake.script(
                CurrentBolusStatusResponse.props.opCode,
                .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: secondId)))
            scriptLastBolus(fake, bolusId: secondId, deliveredMilliunits: 4000)
            let retried = await backend.reconcile(bolusId: secondId)
            #expect(
                retried == .resolved(deliveredUnits: 4.0, cancelled: false),
                "the guard must never leave a stale always-busy state behind")
        }
    }

    // MARK: - perform()'s own settle reaching the history fallback

    /// Scripts the REAL end-to-end `deliverBolus` flow (time sync, permission, initiate, the op-45
    /// completion poll), then makes the fast op-164 `lastBolusStatus` read unavailable — exactly the
    /// owner's device (op-164 rejected on every bolus). Before this fix that always threw indeterminate
    /// even though op-45 had just proven the exact id was no longer active. `perform()`'s settle must
    /// now reach the SAME bounded exact-id history search `reconcile(bolusId:)` uses — while the
    /// connection is still `.bolusing` (the demotion to `.connected` happens only after settle) — and
    /// resolve from a matching op-60 history record instead of no-oping.
    @Test func performsSettleReachesTheHistoryFallbackWhenOp164IsUnavailable() async throws {
        try await withNoCompetingBackfill {
            let fake = FakePumpTransport()
            let backend = TandemBackend(testTransport: fake)
            backend.historySearchPageTimeoutOverride = 0.08
            let bolusId = 8001
            fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
            fake.script(
                BolusPermissionResponse.props.opCode,
                .frame(FakePumpTransport.permissionGranted(bolusId: bolusId)))
            fake.script(
                InitiateBolusResponse.props.opCode, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
            // op-45: the completion poll's own authoritative liveness proof (this exact id no longer
            // active) — scripted twice, once for the settle-loop poll and once for the fallback's own
            // internal op-45 re-check.
            fake.script(
                CurrentBolusStatusResponse.props.opCode,
                .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)),
                .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
            // op-164 (`lastBolusStatus`) is left UNSCRIPTED — a dropped/refused response, exactly the
            // owner's device behavior — so `perform()`'s settle must fall through to history.
            scriptHistoryStatus(fake, numEntries: 1000, first: 1, last: 1000)

            let task = Task { try await backend.deliverBolus(units: 2.0, carbsGrams: nil, bgMgdl: nil, iobUnits: nil) }
            // The completion poll's own hardcoded 500 ms first tick (never overridable) must elapse
            // before the settle even attempts op-164, so this wait must clear that plus the fallback's
            // own op-45 re-check and range read before the injected frame can be observed.
            try? await Task.sleep(nanoseconds: 650_000_000)
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(bolusRecordsById: [
                    (
                        seq: 995, pumpTimeSec: 900_000, bolusId: bolusId, delivered: 2.0, iob: 0.5,
                        completionStatusId: 3, insulinRequested: 2.0
                    )
                ]))
            let delivered = try await task.value
            #expect(
                delivered == 2.0,
                "perform()'s settle must reach the history fallback and resolve from the matching op-60 record instead of throwing indeterminate over an unavailable op-164"
            )
            #expect(fake.sent.contains { $0.opCode == HistoryLogRequest.props.opCode })
        }
    }

    /// Genuine exhaustion of the fallback (no exact-id match anywhere in the bounded search) must still
    /// fail closed to indeterminate — the fallback is a real search, never an unconditional settle.
    @Test func performsSettleStillFailsClosedToIndeterminateWhenHistoryHasNoMatch() async {
        await withNoCompetingBackfill {
            let fake = FakePumpTransport()
            let backend = TandemBackend(testTransport: fake)
            backend.historySearchPageTimeoutOverride = 0.08
            let bolusId = 8002
            fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
            fake.script(
                BolusPermissionResponse.props.opCode,
                .frame(FakePumpTransport.permissionGranted(bolusId: bolusId)))
            fake.script(
                InitiateBolusResponse.props.opCode, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
            fake.script(
                CurrentBolusStatusResponse.props.opCode,
                .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)),
                .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
            // op-164 unscripted, and the history range is scripted but NO matching record is ever
            // injected — the bounded page walk must exhaust and fail closed.
            scriptHistoryStatus(fake, numEntries: 1000, first: 1, last: 1000)

            var thrown: Error?
            do {
                _ = try await backend.deliverBolus(units: 2.0, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
            } catch {
                thrown = error
            }
            #expect(
                (thrown as? BolusError)?.isIndeterminate == true,
                "genuine exhaustion of the history fallback must still fail closed to indeterminate, never assume delivered or not-delivered"
            )
        }
    }
}
