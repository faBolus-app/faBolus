import Foundation
import ShareClient
import Testing
import faBolusCore
import os

@testable import GlucoseSources

/// Answers ShareClient's requests from a recorded exchange, by path.
final class ShareReplayProtocol: URLProtocol {
    static let responses = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    static let requests = OSAllocatedUnfairLock<[String]>(initialState: [])

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasPrefix("/ShareWebServices/") == true
    }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requests.withLock { $0.append(url.path) }
        let body = Self.responses.withLock { $0[url.path] } ?? "null"
        if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Dexcom Share replay of a recorded exchange")
struct DexcomShareReplayTests {
    struct Fixture: Decodable {
        let responses: [String: String]
    }

    @Test("the real ShareClient signs in once and the source reads the readings, LOW kept apart")
    func replay() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "share-session", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        ShareReplayProtocol.responses.withLock { $0 = fixture.responses }
        ShareReplayProtocol.requests.withLock { $0 = [] }
        URLProtocol.registerClass(ShareReplayProtocol.self)
        defer { URLProtocol.unregisterClass(ShareReplayProtocol.self) }

        let account = ShareAccount(settings: isolatedSettings(), secrets: InMemorySecretStore())
        try account.save(username: "alice", password: "hunter2", region: .us)
        let clock = TestClock(t0.addingTimeInterval(30))
        let source = PollingGlucoseSource(
            id: DexcomShareSource.id, priority: DexcomShareSource.priority, poller: DexcomSharePoller(account: account),
            clock: clock.function, sleep: RecordingSleep().function)
        await source.start()
        #expect(await eventually { await source.state.latest != nil })

        let state = await source.state
        #expect(state.latest?.mgdl == 112)
        #expect(state.latest?.date == t0)
        #expect(state.latest?.trend == .flat)
        #expect(state.latest?.sourceID == "dexcom-share")
        #expect(state.status == .connected)
        #expect(state.belowRangeAt == t0.addingTimeInterval(-900))
        #expect(state.history.map(\.mgdl) == [58, 47, 101, 108, 112])
        #expect(
            ShareReplayProtocol.requests.withLock { $0 } == [
                "/ShareWebServices/Services/General/AuthenticatePublisherAccount",
                "/ShareWebServices/Services/General/LoginPublisherAccountById",
                "/ShareWebServices/Services/Publisher/ReadPublisherLatestGlucoseValues"
            ])
        await source.stop()
    }
}

/// A poller that returns whatever the test queued.
actor ScriptedPoller: GlucosePoller {
    private var results: [Result<GlucosePoll, Error>]
    init(_ results: [Result<GlucosePoll, Error>]) { self.results = results }
    func poll() async throws -> GlucosePoll {
        guard !results.isEmpty else { return GlucosePoll(samples: []) }
        return try results.removeFirst().get()
    }
}

@Suite("Polling source")
struct PollingGlucoseSourceTests {
    func sample(_ mgdl: Int, _ date: Date) -> GlucoseSample {
        GlucoseSample(mgdl: mgdl, date: date, sourceID: "test")!
    }

    func source(_ results: [Result<GlucosePoll, Error>] = [], clock: TestClock = TestClock(t0), sleep: RecordingSleep)
        -> PollingGlucoseSource
    {
        PollingGlucoseSource(
            id: "test", priority: 0, poller: ScriptedPoller(results), clock: clock.function, sleep: sleep.function)
    }

    @Test("an older reading after a newer one leaves latest at the newer")
    func latestNeverStepsBack() async {
        let source = source(sleep: RecordingSleep())
        await source.ingest(GlucosePoll(samples: [sample(110, t0)]))
        await source.ingest(GlucosePoll(samples: [sample(90, t0.addingTimeInterval(-600))]))
        #expect(await source.state.latest?.mgdl == 110)
    }

    @Test("a strictly newer reading advances latest; an equal time doesn't replace it")
    func newerAdvancesEqualDoesNot() async {
        let source = source(sleep: RecordingSleep())
        await source.ingest(GlucosePoll(samples: [sample(100, t0.addingTimeInterval(-300))]))
        await source.ingest(GlucosePoll(samples: [sample(130, t0)]))
        #expect(await source.state.latest?.mgdl == 130)
        await source.ingest(GlucosePoll(samples: [sample(150, t0)]))
        #expect(await source.state.latest?.mgdl == 130)
    }

    @Test("a LOW reading is reported apart and never becomes latest, so the arbiter keeps the pump's value")
    func lowNeverLatest() async {
        let source = source(sleep: RecordingSleep())
        await source.ingest(GlucosePoll(samples: [], belowRange: [t0]))
        let state = await source.state
        #expect(state.latest == nil)
        #expect(state.belowRangeAt == t0)
        var pump = PumpState()
        pump.glucose = Observed(PumpGlucose(mgdl: 150, trend: nil), measuredAt: t0, receivedAt: t0)
        let (merged, _, provenance) = GlucoseArbiter.merge(pumpState: pump, pumpHistory: [], source: state, now: t0)
        #expect(merged.glucose?.value.mgdl == 150)
        #expect(provenance == .pump)
    }

    // Cadence and status.

    @Test("starting polls at once, then waits the active interval while the pump's feed isn't healthy")
    func startPollsNow() async {
        let sleep = RecordingSleep()
        let source = source([.success(GlucosePoll(samples: [sample(120, t0)]))], sleep: sleep)
        await source.start()
        #expect(await eventually { sleep.recorded == [60] })
        #expect(await source.state.status == .connected)
        await source.stop()
    }

    @Test("reporting a healthy pump feed right after starting keeps the first poll's readings")
    func healthyRightAfterStart() async {
        let sleep = RecordingSleep()
        let source = source([.success(GlucosePoll(samples: [sample(120, t0)]))], sleep: sleep)
        await source.start()
        await source.setPrimaryHealthy(true)
        #expect(await eventually { await source.state.latest?.mgdl == 120 })
        await source.stop()
    }

    @Test("a fresh LOW counts as a reading for the status, though it is never the latest value")
    func lowKeepsStatusConnected() async {
        let source = source(sleep: RecordingSleep())
        await source.ingest(GlucosePoll(samples: [sample(60, t0.addingTimeInterval(-3600))], belowRange: [t0]))
        let state = await source.state
        #expect(state.status == .connected)
        #expect(state.latest?.mgdl == 60)
    }

    @Test("a poll asked for while one is in flight doesn't start a second sign-in")
    func noConcurrentPolls() async {
        let poller = GatedPoller()
        let source = PollingGlucoseSource(
            id: "test", priority: 0, poller: poller, clock: { t0 }, sleep: RecordingSleep().function)
        await source.start()
        #expect(await eventually { await poller.calls == 1 })
        await source.pollNow()
        await source.setPrimaryHealthy(true)
        await source.setPrimaryHealthy(false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await poller.calls == 1)
        await poller.open()
        await source.stop()
    }

    @Test("a healthy pump feed slows polling to the idle interval")
    func idleWhilePumpHealthy() async {
        let sleep = RecordingSleep()
        let source = source(sleep: sleep)
        await source.start()
        #expect(await eventually { sleep.recorded == [60] })
        await source.setPrimaryHealthy(true)
        #expect(await eventually { sleep.recorded == [60, 600] })
        await source.stop()
    }

    @Test("a failed poll widens the next wait and says why")
    func failureBacksOff() async {
        let sleep = RecordingSleep()
        let source = source(
            [.failure(GlucosePollError.unavailable(.signInFailed("wrong username or password")))], sleep: sleep)
        await source.start()
        #expect(await eventually { sleep.recorded == [120] })
        #expect(await source.state.status == .unavailable(.signInFailed("wrong username or password")))
        await source.stop()
    }

    @Test("needs-setup doesn't widen the wait")
    func needsSetupNoBackoff() async {
        let sleep = RecordingSleep()
        let source = source([.failure(GlucosePollError.needsSetup)], sleep: sleep)
        await source.start()
        #expect(await eventually { sleep.recorded == [60] })
        #expect(await source.state.status == .needsSetup)
        await source.stop()
    }

    @Test("status goes stale when the latest reading ages past the stale limit, from its measurement time")
    func staleByMeasurementTime() async {
        let clock = TestClock(t0)
        let source = source(clock: clock, sleep: RecordingSleep())
        await source.ingest(GlucosePoll(samples: [sample(120, t0.addingTimeInterval(-60))]))
        #expect(await source.state.status == .connected)
        clock.advance(60 * 60)
        #expect(await source.state.status == .stale)
    }

    @Test("every updates() caller gets its own stream of later changes")
    func updatesStreams() async {
        let source = source(sleep: RecordingSleep())
        let first = await source.updates()
        let second = await source.updates()
        await source.ingest(GlucosePoll(samples: [sample(120, t0)]))
        var a = first.makeAsyncIterator()
        var b = second.makeAsyncIterator()
        #expect(await a.next()?.latest?.mgdl == 120)
        #expect(await b.next()?.latest?.mgdl == 120)
    }
}

/// Holds every poll until `open()`, counting them.
actor GatedPoller: GlucosePoller {
    private(set) var calls = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func poll() async throws -> GlucosePoll {
        calls += 1
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        return GlucosePoll(samples: [])
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
