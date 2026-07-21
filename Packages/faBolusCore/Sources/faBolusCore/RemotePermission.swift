import Foundation

/// What a paired remote **peer** (a Mac or another iPhone) is allowed to do to the host's pump.
/// Viewing status is always allowed; everything here is off by default (a new peer is view-only) and
/// granted per-peer by the host. Mirrors the `ChildFeature` allow-set model.
public enum RemotePermission: String, Codable, CaseIterable, Sendable, Identifiable {
    case bolus            // standard bolus
    case extendedBolus    // extended / combo bolus
    case cancelBolus      // stop a running bolus
    case dismissAlerts    // clear/snooze pump alerts
    case suspendResume    // suspend / resume insulin

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .bolus:         return "Deliver boluses"
        case .extendedBolus: return "Extended (combo) bolus"
        case .cancelBolus:   return "Cancel a running bolus"
        case .dismissAlerts: return "Clear / snooze alerts"
        case .suspendResume: return "Suspend / resume insulin"
        }
    }
}

/// How a peer's bolus is confirmed.
public enum RemoteApprovalMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The remote confirms on its own screen; the host executes directly (like the watch/Garmin).
    case auto
    /// The host must approve each bolus on-device (the pending-bolus prompt) before it delivers.
    case hostApproval

    public var id: String { rawValue }
    public var label: String { self == .auto ? "Remote confirms" : "I approve on this phone" }
}

/// The host's policy for one paired peer: what it may do + how its boluses are confirmed. Persisted
/// per peer (keyed by the peer's client id). A brand-new peer is created **view-only**; a peer with no
/// stored policy at all (i.e. paired before this feature existed — the original Mac) is treated as a
/// full grant so its behavior is unchanged.
public struct RemotePeerPolicy: Codable, Equatable, Sendable {
    public var permissions: Set<RemotePermission>
    public var approvalMode: RemoteApprovalMode
    public init(permissions: Set<RemotePermission> = [], approvalMode: RemoteApprovalMode = .auto) {
        self.permissions = permissions; self.approvalMode = approvalMode
    }
    public func allows(_ p: RemotePermission) -> Bool { permissions.contains(p) }

    /// New peers start here (see status only until the host grants more).
    public static let viewOnly = RemotePeerPolicy(permissions: [], approvalMode: .auto)
    /// Migration default for a peer paired before per-peer policies existed (unchanged behavior).
    public static let legacyFull = RemotePeerPolicy(permissions: Set(RemotePermission.allCases), approvalMode: .auto)
}
