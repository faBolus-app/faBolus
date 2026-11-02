import Foundation

/// The single "can this surface start a bolus right now?" decision, shared by every bolus affordance
/// (phone, Garmin, Mac, remote-iPhone) so they agree instead of each hand-rolling a check. Pure and
/// stateless, like `AccessPolicy` — the caller supplies the inputs it can see and gets back
/// `(canBolus, reason)`; the `reason` is what the surface shows when disabled.
///
/// It composes with, and does not replace, `AccessPolicy` (permission: read-only/capability/remote settings)
/// — the caller passes the `AccessPolicy.AccessDecision` in as one input. What `BolusGate` adds on top is
/// the *therapy-availability* axis the access policy has no view of: the pump LINK health and whether a
/// dose is already in flight.
///
/// **Not gated here on purpose:** CGM staleness. A stale reading only nils the correction BG auto-fill; it
/// must never disable the bolus button. A test pins that `canBolus` ignores staleness.
public enum BolusBlockReason: Equatable, Sendable {
    case remoteUnreachable  // this remote can't reach the host phone
    case pumpNotLinked  // the pump link is down (disconnected/scanning/connecting/error)
    case bolusInFlight  // a dose is already being delivered — wait for it to finish
    case noCartridge  // cartridge is mid change/load/prime-tubing — dosing is physically impossible
    case belowMinimum(Double)  // entered amount is below the minimum deliverable
    case aboveMax(Double)  // entered amount exceeds the pump's configured max
    case accessDenied(AccessPolicy.DenialReason)  // read-only / capability / remote settings

    public var userMessage: String {
        switch self {
        case .remoteUnreachable: return "Can't reach the phone — move closer and try again."
        case .pumpNotLinked: return "Pump not connected."
        case .bolusInFlight: return "A bolus is already being delivered — wait for it to finish."
        case .noCartridge: return "Cartridge isn't loaded — finish the cartridge change first."
        case .belowMinimum(let m): return String(format: "Enter at least %.2f U.", m)
        case .aboveMax(let m): return String(format: "Over the pump's max bolus (%.2f U).", m)
        case .accessDenied(let r): return r.userMessage
        }
    }
}

public enum BolusGate {
    /// Decide whether a bolus of `amount` may be started from a surface with the given inputs. Fail-safe
    /// precedence (each disables with the first matching reason): unreachable → pump-not-linked →
    /// in-flight → no-cartridge → access-denied → below-minimum → above-max → allowed.
    ///
    /// - Parameters:
    ///   - reachable: can this surface reach the host? (host surfaces pass `true`; remotes pass their link state)
    ///   - linked: is the pump link healthy? (host: `PumpState.link.isConnected`; remote: the relayed
    ///     pump-connected flag)
    ///   - bolusInFlight: is a dose already running? (host: `BolusBlock.bolusInProgress`; remote: relayed)
    ///   - cartridgeReady: is the cartridge NOT mid change/load/prime-tubing? (host:
    ///     `PumpState.cartridgeReadiness != .notReady`; remote: relayed). Dosing is physically impossible
    ///     while `false`, so this is checked before access/bounds.
    ///   - maximum: the pump's max bolus, or `nil` when it hasn't been read. Unknown, the pump enforces
    ///     its own max and the app adds none.
    ///   - access: the `AccessPolicy` decision for `.deliverBolus` on this surface (host: the real evaluation;
    ///     a remote pre-wire passes `.allow`, or `.deny(.remotesReadOnly)` when it locally knows it's read-only)
    public static func evaluate(
        reachable: Bool, linked: Bool, bolusInFlight: Bool,
        cartridgeReady: Bool = true,
        amount: Double, minimum: Double = BolusVolume.minimumUnits, maximum: Double?,
        access: AccessPolicy.AccessDecision
    ) -> (canBolus: Bool, reason: BolusBlockReason?) {
        let reason =
            availability(
                reachable: reachable, linked: linked, bolusInFlight: bolusInFlight,
                cartridgeReady: cartridgeReady, access: access)
            ?? amountCheck(amount, minimum: minimum, maximum: maximum)
        return (reason == nil, reason)
    }

    /// The checks that don't depend on the amount, so a dose flow can refuse before it asks the user
    /// anything. `nil` when a bolus may be attempted.
    public static func availability(
        reachable: Bool, linked: Bool, bolusInFlight: Bool, cartridgeReady: Bool,
        access: AccessPolicy.AccessDecision
    ) -> BolusBlockReason? {
        if !reachable { return .remoteUnreachable }
        if !linked { return .pumpNotLinked }
        if bolusInFlight { return .bolusInFlight }
        if !cartridgeReady { return .noCartridge }
        // `access.reason` is nil ⇔ allowed by `AccessDecision`'s own contract, so `!access.allowed`
        // always carries a reason in practice; this fallback exists only because the struct's public
        // init can't enforce that pairing at compile time. `.capabilityUnavailable` is the least
        // situation-specific surviving reason, so a caller that somehow reaches this branch is never
        // told a false, more-specific story about WHY.
        if !access.allowed { return .accessDenied(access.reason ?? .capabilityUnavailable) }
        return nil
    }

    /// The pump's own bounds on the amount: its minimum, and its max when known. `nil` when the amount
    /// is within them.
    public static func amountCheck(_ amount: Double, minimum: Double, maximum: Double?) -> BolusBlockReason? {
        // A non-finite amount (NaN/±inf) satisfies neither `< minimum` nor `> maximum`, so without this
        // guard it would pass. Fail closed.
        if !amount.isFinite { return .belowMinimum(minimum) }
        if amount < minimum { return .belowMinimum(minimum) }
        if let maximum, maximum.isFinite, maximum > 0, amount > maximum { return .aboveMax(maximum) }
        return nil
    }
}
