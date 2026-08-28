import Foundation
import faBolusCore
import ShareClient

/// Minimal fetch seam over the vendored `ShareClient` so `DexcomShareSource` can be exercised with an
/// injected fake (caching/backoff tests) without a live network — `ShareClient` conforms
/// as-is, adding no behavior. Counting client constructions == counting login handshakes (a fresh
/// client starts with a nil token and must re-authenticate).
protocol ShareGlucoseFetching {
    func fetchLast(_ n: Int, callback: @escaping (ShareError?, [ShareGlucose]?) -> Void)
}
extension ShareClient: ShareGlucoseFetching {}

/// Dexcom Share follower — **cloud fallback** for Dexcom (G6 has no free BLE slot; Share is the only
/// independent feed, and it can be delayed/flaky). The official Dexcom app must have Share enabled
/// and uploading. Config: `dexcomshare.username` + `dexcomshare.region` (UserDefaults),
/// `dexcomshare.password` (Keychain). Read-only.
///
/// Uses the **vendored `ShareClient`** (LoopKit/dexcom-share-client-swift, MIT) — the validated
/// implementation Loop uses (login + re-auth + `fetchLast`) — instead of hand-rolled endpoint calls.
///
/// The `ShareClient` is **cached on the instance across polls** instead of being rebuilt inside
/// `poll()` every cycle — a rebuild forces a full 2-request re-auth handshake as often as every 60s
/// during failover, risking Dexcom's `SSO_Authenticate MaxAttemptsExceeed` lockout at the exact
/// moment the fallback is needed. It is re-constructed only when the configured credentials change
/// or a fetch error nils it (a 401-equivalent), and `PollingGlucoseSource`'s backoff widens the retry
/// cadence on repeated failure.
@MainActor
final class DexcomShareSource: PollingGlucoseSource {
    /// Builds the underlying Share client for a given credential/region set. Injectable so tests can
    /// count constructions (each new client == a fresh login handshake) without hitting Dexcom.
    typealias ClientFactory = @MainActor (_ user: String, _ pass: String, _ server: KnownShareServers) -> ShareGlucoseFetching
    private let makeClient: ClientFactory

    /// The cached client + the credentials it was built from. Reused across `poll()` so the
    /// vendored `ShareClient` keeps its own session token warm instead of re-authenticating every
    /// cycle. Rebuilt ONLY on a credential change (below) or when a fetch error nils it.
    private var client: ShareGlucoseFetching?
    private var cachedCreds: (user: String, pass: String, server: KnownShareServers)?

    init(clientFactory: @escaping ClientFactory = { user, pass, server in
        ShareClient(username: user, password: pass, shareServer: server)
    }) {
        self.makeClient = clientFactory
        super.init(id: "dexcom-share", priority: 20)
    }

    /// Maps the `dexcomshare.region` config string to a Dexcom Share server. `"apac"` →
    /// `KnownShareServers.APAC` (`share.dexcom.jp`), `"ous"` → the worldwide server, anything else → US.
    static func server(for region: String?) -> KnownShareServers {
        switch region {
        case "apac": return .APAC
        case "ous": return .Worldwide
        default: return .US
        }
    }

    override func poll() async throws -> [GlucoseSample] {
        guard let user = GlucoseSourceConfig.string("dexcomshare.username"),
              let pass = CredentialStore.get(account: "dexcomshare.password") else {
            throw SourceError.needsSetup("Dexcom Share")
        }
        let server = Self.server(for: GlucoseSourceConfig.string("dexcomshare.region"))
        return try await fetch(user: user, pass: pass, server: server)
    }

    /// Testable fetch core: reuse the cached client unless the credentials changed. The vendored
    /// `ShareClient` caches its own session token across `fetchLast` calls, so a second poll with the
    /// same credentials does NOT trigger a fresh login handshake. A thrown fetch error invalidates the
    /// cached client so the next poll re-logs in (a 401-equivalent), while `PollingGlucoseSource`'s
    /// backoff widens the retry cadence to avoid a fixed-cadence re-auth storm.
    ///
    /// The network-callback closure extracts only PLAIN `(mgdl, date, trend)` tuples from each
    /// `ShareGlucose` — `ShareGlucose`'s memberwise init is `internal` to the vendored `ShareClient`
    /// module, so no test in THIS target can construct one directly. Keeping the closure to trivial
    /// field extraction means the actual gating decision (`Self.partition`, below) is a pure function
    /// over plain tuples, fully unit-testable without a real `ShareGlucose`. The closure itself still
    /// touches no `self` (it may run off the `@MainActor` — ShareClient's completion isn't guaranteed
    /// to land on it).
    func fetch(user: String, pass: String, server: KnownShareServers) async throws -> [GlucoseSample] {
        if client == nil
            || cachedCreds?.user != user
            || cachedCreds?.pass != pass
            || cachedCreds?.server != server {
            client = makeClient(user, pass, server)
            cachedCreds = (user, pass, server)
        }
        guard let client else { return [] }
        let sid = id   // capture the Sendable id, not self, into the callback
        do {
            let raw: [(mgdl: Int, date: Date, trend: Int)] = try await withCheckedThrowingContinuation { cont in
                // ShareClient handles session re-auth internally (maxReauthAttempts).
                client.fetchLast(48) { error, values in
                    if let error { cont.resume(throwing: error); return }
                    cont.resume(returning: (values ?? []).map {
                        (mgdl: Int($0.glucose), date: $0.timestamp, trend: Int($0.trend))
                    })
                }
            }
            // Back on the MainActor now (the continuation resumes into this @MainActor-isolated
            // function) — safe to touch `self` again from here on.
            let (samples, belowRange) = Self.partition(readings: raw, sourceID: sid)
            // Surface each below-`GlucosePlausibility.minimum` raw reading through the ingest-boundary
            // sentinel (`ingestRawReading` re-applies the SAME [40, 400] gate — this call is a no-op
            // for any in-range value, since `partition` already separated those into `samples`).
            // Oldest-first so the newest below-range reading is the one left standing in
            // `urgentLowSentinel` (mirrors `PollingGlucoseSource.ingest`'s max-by-date "latest" rule).
            for r in belowRange.sorted(by: { $0.date < $1.date }) { ingestRawReading(mgdl: r.mgdl, date: r.date) }
            return samples
        } catch {
            // 401-equivalent / fetch failure: drop the cached client so the NEXT poll builds a fresh one
            // (a new login). Backoff (PollingGlucoseSource) keeps this from becoming a fixed-cadence
            // re-auth storm against the login endpoint.
            self.client = nil
            self.cachedCreds = nil
            throw error
        }
    }

    /// Pure classification of the raw Dexcom Share readings one poll returned — extracted from the
    /// network-callback closure so it is independently unit-testable with plain tuples (see `fetch`'s
    /// doc comment on why `ShareGlucose` itself can't be constructed in this target). Applies the SAME
    /// [40, 400] plausibility gate (`GlucoseSample.init?`) for the in-range half; additionally
    /// buckets a below-`GlucosePlausibility.minimum` raw reading separately instead of silently
    /// discarding it. An above-`.maximum` reading (decode garbage) — or `glucose <= 0` — is still
    /// silently dropped either way.
    static func partition(readings: [(mgdl: Int, date: Date, trend: Int)], sourceID: String)
        -> (samples: [GlucoseSample], belowRange: [(mgdl: Int, date: Date)]) {
        var samples: [GlucoseSample] = []
        var belowRange: [(mgdl: Int, date: Date)] = []
        for r in readings {
            guard r.mgdl > 0 else { continue }
            if let sample = GlucoseSample(mgdl: r.mgdl, date: r.date, trend: CgmTrend.dexcom(r.trend), sourceID: sourceID) {
                samples.append(sample)
            } else if r.mgdl < GlucosePlausibility.minimum {
                belowRange.append((mgdl: r.mgdl, date: r.date))
            }
        }
        return (samples, belowRange)
    }
}
