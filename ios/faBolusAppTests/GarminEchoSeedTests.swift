import Testing
import Foundation
@testable import faBolus

/// **R2-12.** Pins `garminEchoesToSeed` — the pure, ConnectIQ-free launch-time re-seed selector that backs
/// the bridge's durable terminal-echo outbox across a restart. Like its sibling `garminSendDisposition`
/// (see `GarminSendOutboxTests`), it lives OUTSIDE `#if GARMIN` (next to `GarminEchoSeed` /
/// `GarminMessageReadiness`) precisely so it compiles and is unit-testable in the default (non-GARMIN)
/// test target, where the ConnectIQ-typed bridge is not.
///
/// LOAD-BEARING INVARIANT: on launch the bridge re-seeds one `bolusStatus` echo per durable terminal
/// outcome that was NOT already confirmed-sent to the watch (`alreadyEchoed`). An outcome already acked
/// must NEVER be re-echoed (the watch already received it); an outcome never acked MUST be re-seeded — the
/// app was killed/relaunched before its echo was transport-acked, and dropping it strands the watch at
/// "delivering…" forever (it makes the watch-side R2-02 stuck-terminal permanent). Fields map through 1:1
/// and the ledger's ordering is preserved.
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
}
