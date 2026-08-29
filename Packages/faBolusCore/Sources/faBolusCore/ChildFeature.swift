import Foundation

/// The actions a parent can individually allow/deny in child (locked) mode. Everything else the app
/// does — viewing status, glucose, history — is always available. The default posture when child mode
/// is enabled: **block anything that dispenses insulin, allow benign actions** (the parent can then
/// re-enable specific items).
///
/// Lives in faBolusCore (moved from the app in P8) so the single `AccessPolicy` evaluator can map a
/// `GatedPumpWrite` to the child-feature it requires. `rawValue`s are unchanged, so the persisted
/// `childAllowed` set and backups keep decoding. The Keychain-backed PIN store (`ChildModeStore`) stays
/// in the app target.
public enum ChildFeature: String, Codable, CaseIterable, Identifiable, Sendable {
    case bolus  // deliver a bolus (phone / watch / Mac / Garmin / widget)
    case cancelBolus  // stop a running bolus — benign (stops insulin), allowed by default
    case dismissAlerts  // clear/snooze pump alerts — benign, allowed by default
    case advancedControl  // suspend/resume, temp basal, modes, profiles, cartridge/fill, CGM session, limits…
    case changeSettings  // open Settings / change sources, credentials, pairing, and child mode itself

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .bolus: return "Deliver boluses"
        case .cancelBolus: return "Cancel a running bolus"
        case .dismissAlerts: return "Clear / snooze alerts"
        case .advancedControl: return "Advanced pump control"
        case .changeSettings: return "Change settings"
        }
    }

    public var detail: String {
        switch self {
        case .bolus: return "Give insulin from any device (phone, watch, Garmin, widget)."
        case .cancelBolus: return "Stop a bolus that's in progress. Safe — it only stops insulin."
        case .dismissAlerts: return "Acknowledge or clear pump alerts."
        case .advancedControl: return "Suspend/resume, temp basal, modes, profiles, cartridge, CGM session."
        case .changeSettings: return "Open Settings and change the app, CGM sources, pairing, or this mode."
        }
    }

    /// Whether this is allowed by default when child mode is first enabled (benign = allowed).
    public var allowedByDefault: Bool { self == .cancelBolus || self == .dismissAlerts }

    public static var defaultAllowed: Set<ChildFeature> { Set(allCases.filter { $0.allowedByDefault }) }
}
