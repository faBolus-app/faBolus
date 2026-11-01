import Foundation

/// Which pump the app is talking to.
///
/// The model comes from the advertised name prefix (pumpx2 reads it with the Device Information
/// Service), never from the API version: a t:slim X2 reports API 4.0, so a version table can't tell a
/// t:slim from a Mobi.
public enum PumpModel: String, Sendable, Hashable, Codable, CaseIterable {
    case tslimX2, mobi, unknown

    /// The model named by a pump's advertised Bluetooth name, using pumpx2's prefixes. Anything else is
    /// `.unknown`, and an unknown pump never delivers.
    public init(advertisedName: String) {
        if advertisedName.hasPrefix("tslim X2") {
            self = .tslimX2
        } else if advertisedName.hasPrefix("Tandem Mobi") {
            self = .mobi
        } else {
            self = .unknown
        }
    }

    /// User-facing model name. Empty for `.unknown`, so nothing is shown before the model is known.
    public var displayName: String {
        switch self {
        case .tslimX2: return "t:slim X2"
        case .mobi: return "Mobi"
        case .unknown: return ""
        }
    }

    /// Manufacturer legal name, kept here so a future non-Tandem model overrides it in one place.
    public var manufacturer: String { "Tandem Diabetes Care" }

    /// What the app does with this model.
    public var capabilities: PumpCapabilities {
        switch self {
        case .tslimX2: return .tslimX2
        case .mobi: return .mobi
        case .unknown: return .unknown
        }
    }
}

/// What the app does with one pump model. Each model is a capability set rather than a special case,
/// so adding Mobi support later means changing its set, not finding every `isMobi` check.
///
/// These describe what this release of the app offers for the model, not everything the pump can do.
/// Whether a particular command works on a particular pump and firmware is a separate question,
/// answered by TandemKit's support matrix.
public struct PumpCapabilities: Sendable, Hashable {
    /// The app may deliver a bolus to this model. Only a t:slim X2 can: an unknown pump or a Mobi never
    /// receives a dose.
    public var canDeliverBolus: Bool
    /// The bolus calculator's carbs entry is offered.
    public var supportsCarbEntry: Bool
    /// An extended (combo) bolus is offered. No model offers it in this release; the dose request has
    /// room for it.
    public var supportsExtendedBolus: Bool
    /// The pump has its own screen. A pump without one relies on the app to show every state and
    /// setting, so screens follow this rather than assuming the pump shows things itself.
    public var hasOwnScreen: Bool
    /// The pump's pairing code is fixed and worth offering to save; a t:slim shows a new code each time.
    public var hasReusablePairingCode: Bool
    /// The highest alert escalation the app may use for this model. A pump without a screen or speaker
    /// worth relying on needs alarms that repeat until acknowledged; this release uses none.
    public var maxAlertEscalation: AlertEscalation

    public init(
        canDeliverBolus: Bool, supportsCarbEntry: Bool, supportsExtendedBolus: Bool,
        hasOwnScreen: Bool, hasReusablePairingCode: Bool, maxAlertEscalation: AlertEscalation
    ) {
        self.canDeliverBolus = canDeliverBolus
        self.supportsCarbEntry = supportsCarbEntry
        self.supportsExtendedBolus = supportsExtendedBolus
        self.hasOwnScreen = hasOwnScreen
        self.hasReusablePairingCode = hasReusablePairingCode
        self.maxAlertEscalation = maxAlertEscalation
    }

    public static let tslimX2 = PumpCapabilities(
        canDeliverBolus: true, supportsCarbEntry: true, supportsExtendedBolus: false,
        hasOwnScreen: true, hasReusablePairingCode: false, maxAlertEscalation: .none)

    /// The release pairs only with a t:slim X2. Mobi support starts by changing this set.
    public static let mobi = PumpCapabilities(
        canDeliverBolus: false, supportsCarbEntry: false, supportsExtendedBolus: false,
        hasOwnScreen: false, hasReusablePairingCode: true, maxAlertEscalation: .none)

    /// Nothing is offered until the model is known.
    public static let unknown = PumpCapabilities(
        canDeliverBolus: false, supportsCarbEntry: false, supportsExtendedBolus: false,
        hasOwnScreen: false, hasReusablePairingCode: false, maxAlertEscalation: .none)
}
