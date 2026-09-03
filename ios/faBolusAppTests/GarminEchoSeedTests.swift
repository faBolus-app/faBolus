import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins that launch re-seeds one bolusStatus echo per durable terminal outcome that was never watch-acked,
/// and never re-echoes an already-acked one. Dropping an unacked outcome on relaunch strands the watch at "delivering…".
struct GarminEchoSeedTests {

    private typealias Outcome = (requestId: String, status: String, message: String?, deliveredUnits: Double?)

    // MARK: field mapping — not-yet-echoed outcomes pass through 1:1

    /// An outcome NOT in `alreadyEchoed` is returned as a seed with every field mapped 1:1
    /// (requestId/status/deliveredUnits/message) — including the exact `deliveredUnits`/`message` values.
    @Test func notYetEchoedOutcomeMapsFieldsOneToOne() {
        let outcome: Outcome = (requestId: "req-1", status: "delivered", message: "done", deliveredUnits: 2.5)
        let seeds = garminEchoesToSeed(terminalOutcomes: [outcome], alreadyEchoed: [])
        #expect(
            seeds == [GarminEchoSeed(requestId: "req-1", status: "delivered", deliveredUnits: 2.5, message: "done")])
    }

    /// A `nil` `message`/`deliveredUnits` (e.g. a failed/cancelled outcome carrying no delivered amount)
    /// maps through as `nil` — the optionals are carried, not coerced.
    @Test func nilOptionalFieldsMapThrough() {
        let outcome: Outcome = (requestId: "req-x", status: "failed", message: nil, deliveredUnits: nil)
        let seeds = garminEchoesToSeed(terminalOutcomes: [outcome], alreadyEchoed: [])
        #expect(seeds == [GarminEchoSeed(requestId: "req-x", status: "failed", deliveredUnits: nil, message: nil)])
    }

    // MARK: the durable-outbox invariant — already-echoed are filtered, not-echoed survive

    /// An outcome whose requestId IS in `alreadyEchoed` is filtered out; a sibling that is NOT survives.
    @Test func alreadyEchoedRequestIdIsFilteredOut() {
        let outcomes: [Outcome] = [
            (requestId: "acked", status: "delivered", message: nil, deliveredUnits: 1.0),
            (requestId: "pending", status: "delivered", message: nil, deliveredUnits: 3.0)
        ]
        let seeds = garminEchoesToSeed(terminalOutcomes: outcomes, alreadyEchoed: ["acked"])
        #expect(
            seeds.map(\.requestId) == ["pending"],
            "an already-acked outcome must not be re-echoed; a never-acked one must survive")
    }

    /// An empty `alreadyEchoed` re-seeds ALL outcomes (fresh launch, nothing confirmed-sent yet).
    @Test func emptyAlreadyEchoedReturnsAllOutcomes() {
        let outcomes: [Outcome] = [
            (requestId: "a", status: "delivered", message: nil, deliveredUnits: 1.0),
            (requestId: "b", status: "cancelled", message: "partial", deliveredUnits: 0.5)
        ]
        let seeds = garminEchoesToSeed(terminalOutcomes: outcomes, alreadyEchoed: [])
        #expect(seeds.map(\.requestId) == ["a", "b"])
    }

    /// An `alreadyEchoed` covering EVERY outcome re-seeds nothing (the watch already has them all).
    @Test func alreadyEchoedCoveringAllReturnsEmpty() {
        let outcomes: [Outcome] = [
            (requestId: "a", status: "delivered", message: nil, deliveredUnits: 1.0),
            (requestId: "b", status: "delivered", message: nil, deliveredUnits: 2.0)
        ]
        let seeds = garminEchoesToSeed(terminalOutcomes: outcomes, alreadyEchoed: ["a", "b"])
        #expect(seeds.isEmpty)
    }

    // MARK: ordering is preserved (the ledger's order is the replay order)

    /// The ledger's order is preserved end-to-end, including after an interior outcome is filtered out.
    @Test func orderingIsPreserved() {
        let outcomes: [Outcome] = [
            (requestId: "1", status: "delivered", message: nil, deliveredUnits: 1.0),
            (requestId: "2", status: "delivered", message: nil, deliveredUnits: 2.0),
            (requestId: "3", status: "delivered", message: nil, deliveredUnits: 3.0)
        ]
        #expect(garminEchoesToSeed(terminalOutcomes: outcomes, alreadyEchoed: []).map(\.requestId) == ["1", "2", "3"])
        #expect(
            garminEchoesToSeed(terminalOutcomes: outcomes, alreadyEchoed: ["2"]).map(\.requestId) == ["1", "3"],
            "filtering an interior outcome must not reorder the survivors")
    }

    // MARK: - Launch-seed ordering (App.swift): seed AFTER reconciliation, not synchronously before it

    /// A durable store preloaded with a fixed ledger, mirroring `SafetyNotificationTests.SeedLedgerStore`
    /// — seeds the reconcile state directly, no delivery path, no gating dependency.
    private final class SeedLedgerStore: RemoteBolusLedgerPersisting, @unchecked Sendable {
        private var persisted: Data?
        init(seed: RemoteBolusLedger) { persisted = try? JSONEncoder().encode(seed) }
        func loadOutcome() -> RemoteBolusLedgerStore.LoadOutcome {
            if let persisted, let l = try? JSONDecoder().decode(RemoteBolusLedger.self, from: persisted) {
                return .init(ledger: l, failedClosed: false)
            }
            return .init(ledger: RemoteBolusLedger(), failedClosed: false)
        }
        func save(_ ledger: RemoteBolusLedger) throws { persisted = try JSONEncoder().encode(ledger) }
        func saveBestEffort(_ ledger: RemoteBolusLedger) { try? save(ledger) }
    }

    /// Reading `garminTerminalOutcomes()` with NO await at all, immediately after construction, mirrors
    /// exactly what the OLD (buggy) `App.init()` did: `AppModel`'s own launch reconciliation is fired as
    /// an unawaited `Task` inside its init, which cannot run even one line of its body until the current
    /// (synchronous) code yields. A read with no intervening suspension point therefore always races
    /// ahead of it — this is the hazard `App.swift`'s reorder exists to close, not a flaky assertion.
    @Test @MainActor func readingOutcomesWithNoAwaitMissesTheLaunchPromotableEntry() {
        var ledger = RemoteBolusLedger()
        _ = ledger.begin(peerId: "garmin", requestId: "seed-1", doseKey: "garmin:seed-1:2.0")
        ledger.markDelivering(peerId: "garmin", requestId: "seed-1")
        let model = AppModel(source: MockBackend(), ledgerStore: SeedLedgerStore(seed: ledger))

        // No `await` anywhere above or here — the internal launch-reconcile Task has not run yet.
        #expect(
            model.garminTerminalOutcomes().isEmpty,
            "a synchronous read must not observe a still-in-flight launch reconciliation")
    }

    /// The fix: awaiting the SAME idempotent entry point `App.swift` now awaits before seeding makes an
    /// entry promoted to `.terminal` during launch reconciliation visible to the seed — entries already
    /// terminal before launch are unaffected (no regression to the pre-existing seed behavior).
    @Test @MainActor func awaitingReconciliationFirstIncludesTheLaunchPromotedEntry() async {
        var ledger = RemoteBolusLedger()
        _ = ledger.begin(peerId: "garmin", requestId: "seed-2", doseKey: "garmin:seed-2:2.0")
        ledger.markDelivering(peerId: "garmin", requestId: "seed-2")
        let model = AppModel(source: MockBackend(), ledgerStore: SeedLedgerStore(seed: ledger))

        await model.reconcileUnresolvedDeliveries()

        #expect(model.garminTerminalOutcomes().map(\.requestId) == ["seed-2"])
        #expect(model.garminTerminalOutcomes().first?.status == "failed")
    }

    /// No regression: an entry already terminal BEFORE launch (settled by a previous session) is seeded
    /// exactly as before — reconciliation is a no-op on an already-empty `unreconciled()` set.
    @Test @MainActor func alreadyTerminalEntryStillIncludedAfterReconciling() async {
        var ledger = RemoteBolusLedger()
        _ = ledger.begin(peerId: "garmin", requestId: "seed-3", doseKey: "garmin:seed-3:1.0")
        ledger.settle(peerId: "garmin", requestId: "seed-3", status: "delivered", deliveredUnits: 1.0)
        let model = AppModel(source: MockBackend(), ledgerStore: SeedLedgerStore(seed: ledger))

        await model.reconcileUnresolvedDeliveries()

        #expect(model.garminTerminalOutcomes().map(\.requestId) == ["seed-3"])
    }
}
