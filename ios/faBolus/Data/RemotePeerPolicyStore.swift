import Foundation
import faBolusCore

/// Per-peer authorization policy (permissions + approval mode), keyed by the peer's client id. These
/// aren't secret (the pairing **token** lives in the Keychain via `MacRemoteAuthStore`), so they live
/// in UserDefaults. A peer with **no** stored entry (or an empty client id) is **deny-by-default**
/// (view-only) — audit A-01: an unknown/unbound peer must never inherit a silent full grant. Brand-new
/// peers get a **view-only** entry at pairing time (`ensureDefault`); the host grants more explicitly.
enum RemotePeerPolicyStore {
    private static let key = "remotePeerPolicies"   // JSON [clientId: RemotePeerPolicy]
    private static let qrKey = "remotePeerHighEntropy"   // JSON [clientId] paired via the 128-bit QR

    private static func load() -> [String: RemotePeerPolicy] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: RemotePeerPolicy].self, from: data) else { return [:] }
        return map
    }
    private static func save(_ map: [String: RemotePeerPolicy]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(map), forKey: key)
    }

    // MARK: Pairing entropy (audit A-11)
    // Only a peer paired via the high-entropy QR (128-bit) may be granted insulin control; a 6-digit
    // manual code is offline-brute-forceable, so such a peer is clamped to view-only no matter what the
    // host UI requests. Enforced here so it can't be bypassed by a UI path.
    private static func highEntropyPeers() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: qrKey),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }
    private static func saveHighEntropy(_ s: Set<String>) {
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(s)), forKey: qrKey)
    }
    /// Record how a peer was paired. Call at first pairing with `viaQR` from the pairing coordinator.
    static func setPairedViaQR(_ clientId: String, _ viaQR: Bool) {
        guard !clientId.isEmpty else { return }
        var s = highEntropyPeers()
        if viaQR { s.insert(clientId) } else { s.remove(clientId) }
        saveHighEntropy(s)
    }
    /// True only for a high-entropy (QR) peer — the sole peers eligible for insulin-control grants.
    static func canGrantControl(_ clientId: String) -> Bool {
        !clientId.isEmpty && highEntropyPeers().contains(clientId)
    }

    /// Stored policy for a peer, or nil if it has none yet.
    static func policy(for clientId: String) -> RemotePeerPolicy? { load()[clientId] }
    /// Effective policy used for gating. **Deny-by-default** (audit A-01): an empty client id, or one
    /// with no stored entry, resolves to `.viewOnly` — never a silent full grant. Real peers are granted
    /// explicitly (via `ensureDefault` at pairing, or the host's per-peer editor).
    static func effectivePolicy(for clientId: String) -> RemotePeerPolicy {
        guard !clientId.isEmpty else { return .viewOnly }
        return load()[clientId] ?? .viewOnly
    }
    static func setPolicy(_ p: RemotePeerPolicy, for clientId: String) {
        // Audit A-11: a low-entropy (manually-code-paired) peer can never hold control permissions —
        // clamp to view-only regardless of what the caller requested. Re-pairing via QR lifts this.
        let policy = canGrantControl(clientId) ? p : .viewOnly
        var m = load(); m[clientId] = policy; save(m)
    }
    static func remove(_ clientId: String) {
        var m = load(); m[clientId] = nil; save(m)
        var s = highEntropyPeers(); s.remove(clientId); saveHighEntropy(s)
    }
    /// Create a view-only entry for a brand-new peer if it has none (called at first pairing).
    static func ensureDefault(for clientId: String) {
        if load()[clientId] == nil { setPolicy(.viewOnly, for: clientId) }
    }
}
