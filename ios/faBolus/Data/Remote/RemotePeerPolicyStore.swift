import Foundation
import faBolusCore

/// Minimal, deny-by-default stub replacing the real per-peer authorization store. The iPhone-to-
/// iPhone peer remote (and the Mac remote) that produced/consumed a real grant are both removed from
/// narrow `main`; this stub exists solely to keep the `effectivePolicy(for:)` call site compiling.
///
/// **Fail-closed, unconditionally:** there is no possible producer of a real grant anymore, so
/// `effectivePolicy` always returns `.viewOnly` — never `.fullControl`.
enum RemotePeerPolicyStore {
    /// Deny-by-default, unconditionally — there is no possible producer of a real grant anymore.
    static func effectivePolicy(for clientId: String) -> RemotePeerPolicy { .viewOnly }
}
