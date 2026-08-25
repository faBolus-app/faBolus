import Testing
import Foundation
@testable import faBolus
import faBolusCore
import ShareClient

/// D-07 (HIGH, B3): `DexcomShareSource` used to build a fresh unauthenticated `ShareClient` inside
/// `poll()` every cycle (token nil), forcing a full 2-request re-auth handshake as often as every 60s
/// during failover — the `SSO_Authenticate MaxAttemptsExceeed` lockout risk. These pin the fix: the
/// client/token is cached across polls, rebuilt only on a credential change, backs off on repeated
/// failure and resets on success, and `"apac"` maps to the APAC server (D-13). Driven via the injected
/// client factory + the testable `fetch(user:pass:server:)` core — no Keychain, no network.
@MainActor
struct DexcomShareSourceTests {

    /// A counting reference so an `@escaping` factory can tally client constructions across polls.
    private final class Counter { var n = 0 }

    /// Fake Share client — never touches the network. Each construction stands in for one login
    /// handshake (a real fresh `ShareClient` starts with a nil token, forcing a re-auth). Returns an
    /// empty reading set on success; the tests assert construction counts / backoff / error handling,
    /// not sample content (`ShareGlucose`'s memberwise init is not public, so it can't be built here).
    private final class FakeShareClient: ShareGlucoseFetching {
        let failure: ShareError?
        init(failure: ShareError? = nil) { self.failure = failure }
        func fetchLast(_ n: Int, callback: @escaping (ShareError?, [ShareGlucose]?) -> Void) {
            callback(failure, failure == nil ? [] : nil)
        }
    }

    // MARK: - Caching (1 login for 2 polls)

    /// Across two successive polls with unchanged credentials the client is reused — the second poll
    /// does NOT rebuild a fresh unauthenticated client (no new login handshake).
    @Test func clientIsCachedAcrossPollsWithUnchangedCredentials() async throws {
        let counter = Counter()
        let source = DexcomShareSource { _, _, _ in
            counter.n += 1
            return FakeShareClient()
        }
        _ = try await source.fetch(user: "u", pass: "p", server: .US)
        _ = try await source.fetch(user: "u", pass: "p", server: .US)
        #expect(counter.n == 1, "the client/token must be reused across polls — 1 login for 2 polls")
    }

    // MARK: - Credential-change invalidation

    /// Changing the username/password/region between polls rebuilds the client — a stale token is not
    /// reused against new credentials.
    @Test func credentialChangeRebuildsTheClient() async throws {
        let counter = Counter()
        let source = DexcomShareSource { _, _, _ in
            counter.n += 1
            return FakeShareClient()
        }
        _ = try await source.fetch(user: "u", pass: "p", server: .US)
        _ = try await source.fetch(user: "u2", pass: "p", server: .US)     // username changed
        #expect(counter.n == 2, "a username change must rebuild the client (fresh login)")
        _ = try await source.fetch(user: "u2", pass: "p2", server: .US)    // password changed
        #expect(counter.n == 3, "a password change must rebuild the client")
        _ = try await source.fetch(user: "u2", pass: "p2", server: .APAC)  // region changed
        #expect(counter.n == 4, "a region change must rebuild the client")
        _ = try await source.fetch(user: "u2", pass: "p2", server: .APAC)  // unchanged → reuse
        #expect(counter.n == 4, "unchanged credentials must reuse the cached client")
    }

    /// A fetch error invalidates the cache so the next poll re-logs in (401-equivalent).
    @Test func fetchErrorInvalidatesCacheSoNextPollReLogsIn() async {
        let counter = Counter()
        let source = DexcomShareSource { _, _, _ in
            counter.n += 1
            return FakeShareClient(failure: .fetchError)
        }
        await #expect(throws: ShareError.self) { _ = try await source.fetch(user: "u", pass: "p", server: .US) }
        await #expect(throws: ShareError.self) { _ = try await source.fetch(user: "u", pass: "p", server: .US) }
        #expect(counter.n == 2, "a fetch error must nil the cached client so the next poll builds a fresh one")
    }

    // MARK: - Backoff (widen on repeated failure, reset on success)

    /// After consecutive failures the effective retry interval widens beyond the fixed `activeInterval`
    /// (capped), and a subsequent success resets it — so a sustained outage does not hammer the login
    /// endpoint at a fixed 60s cadence.
    @Test func backoffWidensOnRepeatedFailureAndResetsOnSuccess() {
        let source = DexcomShareSource()
        #expect(source.effectiveInterval(base: 60, failures: 0) == 60, "no failures → base cadence unchanged")
        #expect(source.effectiveInterval(base: 60, failures: 1) == 120)
        #expect(source.effectiveInterval(base: 60, failures: 3) == 480)
        #expect(source.effectiveInterval(base: 60, failures: 10) == 480,
                "backoff must cap at maxBackoffMultiplier (8×), not grow unbounded")

        source.recordPollOutcome(success: false)
        source.recordPollOutcome(success: false)
        #expect(source.consecutiveFailures == 2, "consecutive failures must accumulate")
        source.recordPollOutcome(success: true)
        #expect(source.consecutiveFailures == 0, "a success must reset the backoff")
    }

    // MARK: - APAC region mapping (D-13)

    /// `"apac"` maps to the APAC server (`share.dexcom.jp`); `"ous"` still maps to Worldwide; anything
    /// else (including nil) maps to US.
    @Test func regionStringMapsToTheCorrectShareServer() {
        #expect(DexcomShareSource.server(for: "apac") == .APAC)
        #expect(KnownShareServers.APAC.rawValue == "https://share.dexcom.jp")
        #expect(DexcomShareSource.server(for: "ous") == .Worldwide)
        #expect(DexcomShareSource.server(for: "us") == .US)
        #expect(DexcomShareSource.server(for: nil) == .US)
        #expect(DexcomShareSource.server(for: "garbage") == .US)
    }

    // MARK: - C2-01 depth (13-03 wiring completion): `partition`'s pure gate over plain tuples —
    // `ShareGlucose`'s memberwise init is internal to the vendored module (see the class doc comment
    // above), so this is what actually exercises the gating decision `fetch()` makes per reading.

    @Test func partitionRoutesInRangeReadingsToSamplesAndBelowRangeSeparately() {
        let now = Date()
        let readings: [(mgdl: Int, date: Date, trend: Int)] = [
            (mgdl: 120, date: now, trend: 4),
            (mgdl: 35, date: now.addingTimeInterval(60), trend: 4),    // below GlucosePlausibility.minimum (40)
            (mgdl: 0, date: now.addingTimeInterval(120), trend: 4),    // glucose<=0 — unchanged silent drop
            (mgdl: 500, date: now.addingTimeInterval(180), trend: 4),  // above .maximum (400) — decode garbage, unchanged silent drop
        ]
        let (samples, belowRange) = DexcomShareSource.partition(readings: readings, sourceID: "dexcom-share")
        #expect(samples.count == 1)
        #expect(samples.first?.mgdl == 120)
        #expect(belowRange.count == 1)
        #expect(belowRange.first?.mgdl == 35)
    }

    @Test func partitionNeverProducesASampleForABelowRangeReading() {
        // D-05 invariant, re-confirmed at THIS boundary: a below-range raw reading must never become a
        // `GlucoseSample` (a potential dose input) — only the separate `belowRange` bucket.
        let (samples, belowRange) = DexcomShareSource.partition(
            readings: [(mgdl: 10, date: Date(), trend: 0)], sourceID: "dexcom-share")
        #expect(samples.isEmpty)
        #expect(belowRange.count == 1)
    }

    /// The other half of the chain `fetch()` now runs: `partition`'s `belowRange` output, fed through
    /// `ingestRawReading` exactly as `fetch()` does, surfaces the sentinel and never becomes `latest`.
    @Test func belowRangeEntriesFromPartitionFeedIngestRawReadingAndSurfaceTheSentinel() {
        let source = DexcomShareSource()
        let date = Date()
        let (_, belowRange) = DexcomShareSource.partition(
            readings: [(mgdl: 30, date: date, trend: 0)], sourceID: source.id)
        for r in belowRange { source.ingestRawReading(mgdl: r.mgdl, date: r.date) }
        #expect(source.urgentLowSentinel?.date == date)
        #expect(source.latest == nil, "a below-range raw reading must never become `latest` / a dose input")
    }
}
