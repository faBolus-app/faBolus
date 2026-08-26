import Foundation
import faBolusCore

/// Phase 3 (03-02, REMOTE-02, D-02/D-02a/D-09) — minimal, deny-by-default stub replacing the real
/// per-peer authorization store. The iPhone-to-iPhone peer remote (and the Mac remote, `dev/mac`) that
/// produced/consumed a real grant are both removed from narrow `main`; the byte-frozen
/// `AppModel.swift:342` still hard-references `RemotePeerPolicyStore.effectivePolicy(for:)` on its
/// `surface.isAuthenticatedPeer` branch (`AccessPolicy.swift:34-35` — true ONLY for `.macPeer` /
/// `.caregiverPhonePeer`, both removed-producer surfaces, D-02a), so this stub exists solely to keep
/// that one call site compiling without editing the dose-frozen file.
///
/// **Fail-closed, unconditionally:** there is no possible producer of a real grant anymore, so
/// `effectivePolicy` always returns `.viewOnly` — never `.fullControl`. D-09 explicitly prefers this
/// minimal shape over widening it with `setPolicy`/`setPairedViaQR`/`canGrantControl`/`remove`/
/// `ensureDefault`/`authorize`/token APIs (D-09 prohibition) — any test that needed those to construct
/// an "authenticated peer with full control" scenario is deleted, not accommodated here (03-02 Task 4,
/// F-3).
///
/// Reintegration: see `dev/phone-remote`'s `REINTEGRATION.md` for what a future re-add must restore
/// (the real UserDefaults-backed store this replaced is preserved there byte-identical).
enum RemotePeerPolicyStore {
    /// Deny-by-default, unconditionally — there is no possible producer of a real grant anymore.
    static func effectivePolicy(for clientId: String) -> RemotePeerPolicy { .viewOnly }
}
