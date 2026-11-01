import Foundation

/// Every consequential pump write a surface can ask for, each tagged with the gate it goes through, so
/// `AccessPolicy` decides every (surface × action) pair and no write exists without a decided gate.
public enum GatedPumpWrite: String, CaseIterable, Sendable {
    // Delivery: the durable ledger, the one-at-a-time and unknown-outcome blocks, then the dose checks.
    case deliverBolus, deliverExtendedBolus

    // Never blocked by a gate: cancelling is a safety stop, and clearing an alert is low-risk.
    case cancelBolus, dismissNotification

    /// The gate an action goes through.
    public enum Gate: String, Sendable, CaseIterable {
        case ledgeredDelivery
        case alwaysAllowed
    }

    /// Exhaustive, so a new case can't be added without classifying it.
    public var gate: Gate {
        switch self {
        case .deliverBolus, .deliverExtendedBolus: return .ledgeredDelivery
        case .cancelBolus, .dismissNotification: return .alwaysAllowed
        }
    }

    /// Whether the connected model's capabilities permit this action. Delivery needs a model that can
    /// take a dose, and an extended bolus also needs the model to offer one, which none does in
    /// this release. Cancel and dismiss need nothing.
    public func hasRequiredCapability(in caps: PumpCapabilities) -> Bool {
        switch self {
        case .deliverBolus: return caps.canDeliverBolus
        case .deliverExtendedBolus: return caps.canDeliverBolus && caps.supportsExtendedBolus
        case .cancelBolus, .dismissNotification: return true
        }
    }
}
