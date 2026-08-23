import Foundation
import faBolusCore
import ShareClient

/// Minimal fetch seam over the vendored `ShareClient` so `DexcomShareSource` can be exercised with an
/// injected fake (the D-07 caching/backoff tests) without a live network — `ShareClient` conforms
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
/// See Phase 6 in MIGRATION.md.
///
/// D-07: the `ShareClient` is **cached on the instance across polls** (mirroring the now-removed
/// LibreLinkUp source's correct `token: String?` pattern) instead of being rebuilt inside `poll()`
/// every cycle — a rebuild
/// forces a full 2-request re-auth handshake as often as every 60s during failover, risking Dexcom's
/// `SSO_Authenticate MaxAttemptsExceeed` lockout at the exact moment the fallback is needed. It is
/// re-constructed only when the configured credentials change or a fetch error nils it (a
/// 401-equivalent), and `PollingGlucoseSource`'s backoff widens the retry cadence on repeated failure.
@MainActor
final class DexcomShareSource: PollingGlucoseSource {
    /// Builds the underlying Share client for a given credential/region set. Injectable so tests can
    /// count constructions (each new client == a fresh login handshake) without hitting Dexcom.
    typealias ClientFactory = @MainActor (_ user: String, _ pass: String, _ server: KnownShareServers) -> ShareGlucoseFetching
    private let makeClient: ClientFactory

    /// D-07: the cached client + the credentials it was built from. Reused across `poll()` so the
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
    /// `KnownShareServers.APAC` (`share.dexcom.jp`, D-13 — the source-side half of the APAC coverage
    /// gap; the picker UI option lands in Plan 04), `"ous"` → the worldwide server, anything else → US.
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

    /// Testable fetch core (D-07): reuse the cached client unless the credentials changed. The vendored
    /// `ShareClient` caches its own session token across `fetchLast` calls, so a second poll with the
    /// same credentials does NOT trigger a fresh login handshake. A thrown fetch error invalidates the
    /// cached client so the next poll re-logs in (a 401-equivalent), while `PollingGlucoseSource`'s
    /// backoff widens the retry cadence to avoid a fixed-cadence re-auth storm.
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
            return try await withCheckedThrowingContinuation { cont in
                // ShareClient handles session re-auth internally (maxReauthAttempts).
                client.fetchLast(48) { error, values in
                    if let error { cont.resume(throwing: error); return }
                    let out = (values ?? []).compactMap { r -> GlucoseSample? in
                        guard r.glucose > 0 else { return nil }
                        return GlucoseSample(mgdl: Int(r.glucose), date: r.timestamp,
                                             trend: CgmTrend.dexcom(Int(r.trend)), sourceID: sid)
                    }
                    cont.resume(returning: out)
                }
            }
        } catch {
            // 401-equivalent / fetch failure: drop the cached client so the NEXT poll builds a fresh one
            // (a new login). Backoff (PollingGlucoseSource) keeps this from becoming a fixed-cadence
            // re-auth storm against the login endpoint.
            self.client = nil
            self.cachedCreds = nil
            throw error
        }
    }
}
