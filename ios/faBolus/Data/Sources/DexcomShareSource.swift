import Foundation
import faBolusCore
import ShareClient

/// Dexcom Share follower — **last resort** for Dexcom (G6 has no free BLE slot; Share is the only
/// independent feed, and it is notoriously flaky). The official Dexcom app must have Share enabled
/// and uploading. Config: `dexcomshare.username` + `dexcomshare.region` (UserDefaults),
/// `dexcomshare.password` (Keychain). Read-only.
///
/// Uses the **vendored `ShareClient`** (LoopKit/dexcom-share-client-swift, MIT) — the validated
/// implementation Loop uses (login + re-auth + `fetchLast`) — instead of hand-rolled endpoint calls.
/// See Phase 6 in MIGRATION.md.
@MainActor
final class DexcomShareSource: PollingGlucoseSource {
    init() { super.init(id: "dexcom-share", priority: 20) }

    override func poll() async throws -> [GlucoseSample] {
        guard let user = GlucoseSourceConfig.string("dexcomshare.username"),
              let pass = CredentialStore.get(account: "dexcomshare.password") else {
            throw SourceError.needsSetup("Dexcom Share")
        }
        let server: KnownShareServers = GlucoseSourceConfig.string("dexcomshare.region") == "ous"
            ? .Worldwide : .US
        let client = ShareClient(username: user, password: pass, shareServer: server)
        let sid = id   // capture the Sendable id, not self, into the callback
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
    }
}
