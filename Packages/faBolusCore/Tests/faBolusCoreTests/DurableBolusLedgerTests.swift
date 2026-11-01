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

    // MARK: - Remote refusals

    /// A remote request refused before it became an entry is kept across a restart, so its resend gets the
    /// same refusal, and it never blocks a new bolus.
    @Test func aRemoteRefusalSurvivesARestartAndNeverBlocks() async throws {
        let url = temporaryURL()
        let first = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url), now: Self.t0)
        #expect(
            try await first.recordRemoteRefusal(Self.key("garmin", "r1"), reason: "Pump not connected.", now: Self.t0))
        #expect(await first.block == nil)
        let restarted = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url), now: Self.t0.addingTimeInterval(30))
        let refusal = try #require(await restarted.ledger.remoteRefusal(Self.key("garmin", "r1")))
        #expect(refusal.reason == "Pump not connected.")
        #expect(await restarted.block == nil)
        // The next request starts as usual.
        #expect(
            try await restarted.begin(Self.request("garmin", "r2"), now: Self.t0.addingTimeInterval(31)) == .proceed)
    }

    /// A refusal that couldn't be saved doesn't block either: it's kept, and goes with the next save.
    @Test func aRefusalThatCouldntBeSavedDoesntBlock() async throws {
        let url = temporaryURL()
        let ledger = DurableBolusLedger(store: FaultyStore(url: url, failingSaves: [1]), now: Self.t0)
        await #expect(throws: LedgerNotSaved.self) {
            try await ledger.recordRemoteRefusal(Self.key("garmin", "r1"), reason: "x", now: Self.t0)
        }
        #expect(await ledger.block == nil)
        #expect(await ledger.ledger.remoteRefusal(Self.key("garmin", "r1")) != nil)
        #expect(try await ledger.begin(Self.request("garmin", "r2"), now: Self.t0) == .proceed)
        #expect(Self.saved(at: url).remoteRefusal(Self.key("garmin", "r1")) != nil)
    }

    /// The first refusal stands, and a request with an entry is answered from it, not a refusal.
    @Test func aRefusalDoesntReplaceAnAnswer() {
        var ledger = RemoteBolusLedger()
        let first = ledger.recordRemoteRefusal(Self.key("garmin", "r1"), reason: "first", now: Self.t0)
        let second = ledger.recordRemoteRefusal(Self.key("garmin", "r1"), reason: "second", now: Self.t0)
        #expect(first && !second)
        #expect(ledger.remoteRefusal(Self.key("garmin", "r1"))?.reason == "first")
        _ = ledger.begin(Self.request("garmin", "r2"), now: Self.t0)
        let late = ledger.recordRemoteRefusal(Self.key("garmin", "r2"), reason: "late", now: Self.t0)
        #expect(!late)
        #expect(ledger.remoteRefusal(Self.key("garmin", "r2")) == nil)
    }

    /// Past the cap only refusals older than the keep window go: one a remote may still resend never does.
    @Test func theRefusalCapNeverDropsOneThatMayBeResent() {
        var ledger = RemoteBolusLedger()
        let cap = RemoteBolusLedger.remoteRefusalCap
        for i in 0..<(cap + 20) {
            ledger.recordRemoteRefusal(
                Self.key("garmin", "r\(i)"), reason: "x", now: Self.t0.addingTimeInterval(Double(i)))
        }
        #expect(ledger.remoteRefusal(Self.key("garmin", "r0")) != nil)
        let later = Self.t0.addingTimeInterval(RemoteBolusLedger.remoteRefusalKeepSec + 100)
        ledger.recordRemoteRefusal(Self.key("garmin", "new"), reason: "x", now: later)
        #expect(ledger.remoteRefusal(Self.key("garmin", "r0")) == nil)
        #expect(ledger.remoteRefusal(Self.key("garmin", "new")) != nil)
    }

    /// A ledger saved before refusals were kept reads with none.
    @Test func anOlderLedgerFileReadsWithNoRefusals() throws {
        var ledger = RemoteBolusLedger()
        _ = ledger.begin(Self.request("garmin", "r1"), now: Self.t0)
        ledger.recordRemoteRefusal(Self.key("garmin", "r2"), reason: "x", now: Self.t0)
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        #expect(object["remoteRefusals"] != nil)
        object["remoteRefusals"] = nil
        let old = try JSONDecoder().decode(
            RemoteBolusLedger.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.remoteRefusal(Self.key("garmin", "r2")) == nil)
        #expect(old.entry(Self.key("garmin", "r1")) != nil)
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
        #expect(try await second.markDelivered(Self.key("phone", "p1"), units: 1.2) == false, "only history settles it")
        #expect(
            try await second.markDeliveredFromHistory(Self.key("phone", "p1"), units: 1.2, historyPumpKey: "real|P"))
        #expect(await second.block == nil)
        let third = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        #expect(await third.block == nil)
        #expect(await third.ledger.outcome(Self.key("phone", "p1")) == .stopped(delivered: 1.2, requested: 2))
    }

    @Test func historyShowingNoSuchBolusFailsItAndLiftsTheBlock() async throws {
        let url = temporaryURL()
        let first = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        _ = try await first.begin(Self.request("garmin", "r1"))
        try await first.markAccepted(Self.key("garmin", "r1"), bolusId: 8, pumpKey: "real|P")
        let second = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        #expect(await second.block != nil)
        #expect(try await second.markFailed(Self.key("garmin", "r1"), reason: "timed out") == false)
        #expect(try await second.markAbsentFromHistory(Self.key("garmin", "r1"), historyPumpKey: "real|P"))
        #expect(await second.block == nil)
        let third = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        #expect(
            await third.ledger.outcome(Self.key("garmin", "r1"))
                == .failed(reason: RemoteBolusLedger.absentFromHistoryReason))
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

    /// A file that couldn't be read at launch but can be now (a launch before the first unlock) is read
    /// again before confirming, so its records aren't replaced by an empty ledger.
    @Test func confirmingAllReadsAFileThatHasBecomeReadable() async throws {
        let url = temporaryURL()
        let first = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        _ = try await first.begin(Self.request("garmin", "done"))
        try await first.markAccepted(Self.key("garmin", "done"), bolusId: 1)
        try await first.markDelivered(Self.key("garmin", "done"), units: 2)
        _ = try await first.begin(Self.request("garmin", "lost"))
        try await first.markAccepted(Self.key("garmin", "lost"), bolusId: 2, now: Self.t0)
        let saved = try Data(contentsOf: url)
        try Data("unreadable for now".utf8).write(to: url)
        let relaunched = DurableBolusLedger(store: RemoteBolusLedgerStore(url: url))
        #expect(await relaunched.block == .ledgerUnreadable)
        try saved.write(to: url)  // readable again

        try await relaunched.confirmAllOnPump()
        #expect(await relaunched.block == nil)
        // The finished request still replays instead of delivering again.
        #expect(try await relaunched.begin(Self.request("garmin", "done")) == .replay(.delivered(units: 2)))
        let lost = await relaunched.ledger.entry(Self.key("garmin", "lost"))
        #expect(lost?.outcome == .unknown(since: Self.t0))
        #expect(lost?.confirmedOnPumpAt != nil)
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
