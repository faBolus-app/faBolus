import Foundation
import Testing
@testable import faBolusCore

/// The durable owner of the ledger: restarts, concurrent requests, corrupt storage and failed saves.
/// Each test persists to a real file in its own temporary directory, so a "restart" is a new
/// `DurableBolusLedger` reading the same file.
final class DurableBolusLedgerTests {
    /// Every file a test writes lives here, and goes when the test does.
    private let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("durable-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A file store whose numbered saves (1-based) throw, to fail a chosen transition.
    private final class FaultyStore: RemoteBolusLedgerPersisting {
        struct Injected: Error {}
        private let file: RemoteBolusLedgerStore
        private let failingSaves: Set<Int>
        private var saves = 0
        init(url: URL, failingSaves: Set<Int>) {
            file = RemoteBolusLedgerStore(url: url)
            self.failingSaves = failingSaves
        }
        func loadOutcome() -> RemoteBolusLedgerStore.LoadOutcome { file.loadOutcome() }
        func save(_ ledger: RemoteBolusLedger) throws {
            saves += 1
            if failingSaves.contains(saves) { throw Injected() }
            try file.save(ledger)
        }
    }

    private func temporaryURL() -> URL { directory.appendingPathComponent("\(UUID().uuidString).json") }

    private static func request(_ peer: String, _ id: String, _ units: Double = 2) -> DoseRequest {
        let origin: DoseRequest.Origin =
            peer == DoseRequest.Origin.phonePeerId ? .phone : .remote(peerId: peer, sentAt: t0)
        return DoseRequest(id: id, origin: origin, shape: .now(units: units))
    }

    private static func key(_ peer: String, _ id: String) -> RemoteBolusLedger.Key {
        .init(peerId: peer, requestId: id)
    }

    private static func saved(at url: URL) -> RemoteBolusLedger {
        RemoteBolusLedgerStore(url: url).loadOutcome().ledger
    }

    // MARK: - Restart

    @Test func anInFlightBolusIsUnknownAndBlocksAfterARestart() async throws {
        let url = temporaryURL()
        let first = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url), now: Self.t0)
        #expect(try await first.begin(Self.request("garmin", "r1"), now: Self.t0) == .proceed)
        try await first.markAccepted(Self.key("garmin", "r1"), bolusId: 42, now: Self.t0 + 1)

        // The app is killed between InitiateBolus and its reply.
        let second = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url), now: Self.t0 + 600)
        #expect(await second.block == .unknownOutcome(since: Self.t0 + 1))
        #expect(try await second.begin(Self.request("phone", "p1")) == .blocked(.unknownOutcome(since: Self.t0 + 1)))
        // The retry of the same request is still recognized, not redelivered.
        #expect(try await second.begin(Self.request("garmin", "r1")) == .duplicateInFlight)
        // The recovered outcome was saved before anything else, so a second restart agrees.
        #expect(Self.saved(at: url).outcome(Self.key("garmin", "r1")) == .unknown(since: Self.t0 + 1))
        let third = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url), now: Self.t0 + 1200)
        #expect(await third.block == .unknownOutcome(since: Self.t0 + 1))
    }

    @Test func historySettlingTheUnknownLiftsTheBlockForGood() async throws {
        let url = temporaryURL()
        let first = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        _ = try await first.begin(Self.request("phone", "p1"))
        try await first.markAccepted(Self.key("phone", "p1"), bolusId: 7)
        let second = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        #expect(await second.block != nil)
        #expect(try await second.markDelivered(Self.key("phone", "p1"), units: 1.2))
        #expect(await second.block == nil)
        let third = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        #expect(await third.block == nil)
        #expect(await third.ledger.outcome(Self.key("phone", "p1")) == .stopped(delivered: 1.2, requested: 2))
    }

    @Test func aConfirmationOnThePumpSurvivesARestart() async throws {
        let url = temporaryURL()
        let first = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        _ = try await first.begin(Self.request("garmin", "r1"))
        try await first.markAccepted(Self.key("garmin", "r1"), bolusId: 3)
        try await first.markUnknown(Self.key("garmin", "r1"))
        #expect(try await first.confirmOnPump(Self.key("garmin", "r1")))
        let second = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        #expect(await second.block == nil)
        #expect(await second.ledger.outcome(Self.key("garmin", "r1"))?.isUnknown == true)
    }

    @Test func aRequestThatNeverReachedThePumpFailsOnRestartWithoutBlocking() async throws {
        let url = temporaryURL()
        let first = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        _ = try await first.begin(Self.request("phone", "p1"))
        let second = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        #expect(await second.block == nil)
        guard case .failed = await second.ledger.outcome(Self.key("phone", "p1")) else {
            Issue.record("expected failed")
            return
        }
    }

    // MARK: - Concurrent requests

    /// A phone request and a watch request arriving together: exactly one proceeds, every time.
    @Test func concurrentPhoneAndWatchRequestsLetExactlyOneThrough() async throws {
        for round in 0..<25 {
            let ledger = DurableBolusLedger(store: RemoteBolusLedgerStore(url: temporaryURL()))
            async let phone = ledger.begin(Self.request("phone", "p\(round)", 1))
            async let watch = ledger.begin(Self.request("garmin", "g\(round)", 2))
            let decisions = try await [phone, watch]
            #expect(decisions.filter { $0 == .proceed }.count == 1, "round \(round): \(decisions)")
            #expect(decisions.filter { $0 == .blocked(.bolusInProgress) }.count == 1, "round \(round): \(decisions)")
        }
    }

    @Test func manyConcurrentRequestsLetExactlyOneThrough() async throws {
        let ledger = DurableBolusLedger(store: RemoteBolusLedgerStore(url: temporaryURL()))
        let decisions = try await withThrowingTaskGroup(of: RemoteBolusLedger.Decision.self) { group in
            for i in 0..<20 {
                let peer = i.isMultiple(of: 2) ? "phone" : "garmin"
                group.addTask { try await ledger.begin(Self.request(peer, "r\(i)", Double(i % 5 + 1))) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(decisions.filter { $0 == .proceed }.count == 1)
        #expect(decisions.filter { $0 == .blocked(.bolusInProgress) }.count == 19)
    }

    /// The same remote message delivered twice at once (a transport retry racing the original) is one
    /// request: one proceeds and the other is recognized as a duplicate.
    @Test func aDuplicatedRemoteMessageRacingItselfDeliversOnce() async throws {
        let ledger = DurableBolusLedger(store: RemoteBolusLedgerStore(url: temporaryURL()))
        async let first = ledger.begin(Self.request("garmin", "same"))
        async let second = ledger.begin(Self.request("garmin", "same"))
        let decisions = try await [first, second]
        #expect(decisions.filter { $0 == .proceed }.count == 1)
        #expect(decisions.filter { $0 == .duplicateInFlight }.count == 1)
    }

    // MARK: - Corrupt and missing storage

    @Test func aCorruptLedgerFileBlocksUntilTheUserConfirmsOnThePump() async throws {
        let url = temporaryURL()
        try Data("{ not a ledger".utf8).write(to: url)
        let ledger = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        #expect(await ledger.block == .ledgerUnreadable)
        #expect(try await ledger.begin(Self.request("phone", "p1")) == .blocked(.ledgerUnreadable))
        // The corrupt file is left alone until the user acts.
        #expect(try Data(contentsOf: url) == Data("{ not a ledger".utf8))

        try await ledger.confirmAllOnPump()
        #expect(await ledger.block == nil)
        #expect(!RemoteBolusLedgerStore(url: url).loadOutcome().failedClosed, "the file was rewritten")
        #expect(try await ledger.begin(Self.request("phone", "p1")) == .proceed)
    }

    @Test func anEmptyLedgerFileIsUnreadableNotEmpty() async throws {
        let url = temporaryURL()
        try Data().write(to: url)
        let ledger = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        #expect(await ledger.block == .ledgerUnreadable)
    }

    @Test func confirmingAllWhenTheRewriteFailsKeepsTheBlock() async throws {
        let url = temporaryURL()
        try Data("garbage".utf8).write(to: url)
        let ledger = DurableBolusLedger(store: FaultyStore(url: url, failingSaves: [1]))
        await #expect(throws: LedgerNotSaved.self) { try await ledger.confirmAllOnPump() }
        #expect(await ledger.block == .ledgerUnreadable)
    }

    @Test func noDurableStoreBlocksEveryBolus() async throws {
        let ledger = DurableBolusLedger(store: nil)
        #expect(await ledger.block == .noDurableStore)
        #expect(try await ledger.begin(Self.request("phone", "p1")) == .blocked(.noDurableStore))
    }

    // MARK: - Save failures

    @Test func aRequestThatCantBeSavedIsNotRecorded() async throws {
        let url = temporaryURL()
        let ledger = DurableBolusLedger(store: FaultyStore(url: url, failingSaves: [1]))
        await #expect(throws: LedgerNotSaved.self) { try await ledger.begin(Self.request("phone", "p1")) }
        #expect(await !ledger.ledger.hasExistingEntry(Self.key("phone", "p1")))
        #expect(await ledger.block == nil, "nothing unsaved remains, so nothing blocks")
        // The next attempt saves and proceeds.
        #expect(try await ledger.begin(Self.request("phone", "p1")) == .proceed)
    }

    /// The durable point before InitiateBolus: if the acceptance can't be saved, it is undone, so the
    /// caller doesn't send and a restart can't mistake the request for one that never reached the pump.
    @Test func anAcceptanceThatCantBeSavedIsUndone() async throws {
        let url = temporaryURL()
        let ledger = DurableBolusLedger(store: FaultyStore(url: url, failingSaves: [2]))
        _ = try await ledger.begin(Self.request("phone", "p1"))
        await #expect(throws: LedgerNotSaved.self) {
            try await ledger.markAccepted(Self.key("phone", "p1"), bolusId: 9)
        }
        #expect(await ledger.ledger.outcome(Self.key("phone", "p1")) == .requested)
        #expect(await ledger.ledger.entry(Self.key("phone", "p1"))?.bolusId == nil)
        #expect(try await ledger.markFailed(Self.key("phone", "p1"), reason: "Couldn't record the bolus"))
        #expect(await ledger.block == nil)
    }

    /// An outcome that happened at the pump is kept even if it can't be saved, and new boluses wait
    /// until it is, because a restart would otherwise forget it.
    @Test func anOutcomeThatCantBeSavedBlocksUntilASaveSucceeds() async throws {
        let url = temporaryURL()
        let ledger = DurableBolusLedger(store: FaultyStore(url: url, failingSaves: [4]))
        _ = try await ledger.begin(Self.request("garmin", "r1"), now: Self.t0)  // save 1
        try await ledger.markAccepted(Self.key("garmin", "r1"), bolusId: 5, now: Self.t0 + 1)  // save 2
        try await ledger.markDelivering(Self.key("garmin", "r1"), now: Self.t0 + 2)  // save 3
        await #expect(throws: LedgerNotSaved.self) {
            try await ledger.markDelivered(Self.key("garmin", "r1"), units: 2, now: Self.t0 + 30)  // save 4 fails
        }
        #expect(await ledger.ledger.outcome(Self.key("garmin", "r1")) == .delivered(units: 2))
        #expect(await ledger.block == .outcomeNotSaved)
        #expect(try await ledger.begin(Self.request("phone", "p1")) == .blocked(.outcomeNotSaved))
        // A remote asking again still gets its outcome.
        #expect(try await ledger.begin(Self.request("garmin", "r1")) == .replay(.delivered(units: 2)))

        // A restart now would find the last saved state, delivering, and fail closed to unknown.
        let restarted = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url), now: Self.t0 + 60)
        #expect(await restarted.block == .unknownOutcome(since: Self.t0 + 2))

        try await ledger.retrySave()  // save 5
        #expect(await ledger.block == nil)
        #expect(Self.saved(at: url).outcome(Self.key("garmin", "r1")) == .delivered(units: 2))
    }

    @Test func aRecoveryThatCantBeSavedBlocks() async throws {
        let url = temporaryURL()
        let first = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        _ = try await first.begin(Self.request("phone", "p1"))
        let second = DurableBolusLedger(store: FaultyStore(url: url, failingSaves: [1]))
        #expect(await second.block == .outcomeNotSaved)
    }

    @Test func anIllegalTransitionIsNotSavedAndDoesNotThrow() async throws {
        let ledger = DurableBolusLedger(store: FaultyStore(url: temporaryURL(), failingSaves: [2]))
        _ = try await ledger.begin(Self.request("phone", "p1"))
        // Delivering before acceptance isn't a legal move, so nothing is saved and save 2 isn't used.
        #expect(try await ledger.markDelivering(Self.key("phone", "p1")) == false)
        #expect(await ledger.block == .bolusInProgress)
    }
}
