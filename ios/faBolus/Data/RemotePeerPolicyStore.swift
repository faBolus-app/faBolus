import Foundation
import faBolusCore

/// Per-peer authorization policy (permissions + approval mode), keyed by the peer's client id. These
/// aren't secret (the pairing **token** lives in the Keychain via `MacRemoteAuthStore`), so they live
/// in UserDefaults. A peer with **no** stored entry is treated as a full grant — migration for a Mac
/// paired before per-peer policies existed; brand-new peers get a **view-only** entry at pairing time.
enum RemotePeerPolicyStore {
    private static let key = "remotePeerPolicies"   // JSON [clientId: RemotePeerPolicy]

    private static func load() -> [String: RemotePeerPolicy] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: RemotePeerPolicy].self, from: data) else { return [:] }
        return map
    }
    private static func save(_ map: [String: RemotePeerPolicy]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(map), forKey: key)
    }

    /// Stored policy for a peer, or nil if it has none yet.
    static func policy(for clientId: String) -> RemotePeerPolicy? { load()[clientId] }
    /// Effective policy used for gating: stored, else legacy-full (pre-existing peer).
    static func effectivePolicy(for clientId: String) -> RemotePeerPolicy { load()[clientId] ?? .legacyFull }
    static func setPolicy(_ p: RemotePeerPolicy, for clientId: String) {
        var m = load(); m[clientId] = p; save(m)
    }
    static func remove(_ clientId: String) { var m = load(); m[clientId] = nil; save(m) }
    /// Create a view-only entry for a brand-new peer if it has none (called at first pairing).
    static func ensureDefault(for clientId: String) {
        if load()[clientId] == nil { setPolicy(.viewOnly, for: clientId) }
    }
}
