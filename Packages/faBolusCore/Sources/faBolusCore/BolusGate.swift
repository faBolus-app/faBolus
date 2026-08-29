import Foundation

/// The single "can this surface start a bolus right now?" decision, shared by every bolus affordance
/// (phone, Garmin, Mac, remote-iPhone) so they agree instead of each hand-rolling a check. Pure and
/// stateless, like `AccessPolicy` — the caller supplies the inputs it can see and gets back
/// `(canBolus, reason)`; the `reason` is what the surface shows when disabled.
///
/// It composes with, and does not replace, `AccessPolicy` (permission: child/read-only/capability/ack/peer)
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
    case accessDenied(AccessPolicy.DenialReason)  // child / read-only / capability / ack / per-peer

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

    /// A stable, locale-independent token for the wire (`RemoteCommand.bolusBlockReason`), so a remote
    /// can key on WHY its bolus affordance is disabled without parsing the localized `userMessage`. Only
    /// the host-authoritative, broadcast-safe reasons ever travel over the wire (see
    /// `AppModel.statusCommand`); reachability and amount bounds are judged locally by each remote.
    public var wireToken: String {
        switch self {
        case .remoteUnreachable: return "remoteUnreachable"
        case .pumpNotLinked: return "pumpNotLinked"
        case .bolusInFlight: return "bolusInFlight"
        case .noCartridge: return "noCartridge"
        case .belowMinimum: return "belowMinimum"
        case .aboveMax: return "aboveMax"
        case .accessDenied: return "accessDenied"
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
    ///   - linked: is the pump link healthy? (host: `PumpSnapshot.isLinked`; remote: the relayed pump-connected flag)
    ///   - bolusInFlight: is a dose already running? (host: `PumpSnapshot.bolusInFlight`; remote: relayed)
    ///   - cartridgeReady: is the cartridge NOT mid change/load/prime-tubing? (host:
    ///     `PumpSnapshot.cartridgeReadyForBolus`; remote: relayed). Dosing is physically impossible while
    ///     `false`, so this is checked before access/bounds.
    ///   - access: the `AccessPolicy` decision for `.deliverBolus` on this surface (host: the real evaluation;
    ///     a remote pre-wire passes `.allow`, or `.deny(.remotesReadOnly)` when it locally knows it's read-only)
    public static func evaluate(
        reachable: Bool, linked: Bool, bolusInFlight: Bool,
        cartridgeReady: Bool = true,
        amount: Double, minimum: Double, maximum: Double,
        access: AccessPolicy.AccessDecision
    ) -> (canBolus: Bool, reason: BolusBlockReason?) {
        if !reachable { return (false, .remoteUnreachable) }
        if !linked { return (false, .pumpNotLinked) }
        if bolusInFlight { return (false, .bolusInFlight) }
        if !cartridgeReady { return (false, .noCartridge) }
        if !access.allowed { return (false, .accessDenied(access.reason ?? .notPermittedForPeer)) }
        // A non-finite amount (NaN/±inf) satisfies neither `< minimum` nor `> maximum`, so without this
        // guard it would fall through to `(true, nil)` and arm the affordance. `validateDeliver`
        // fail-closes it before the pump write, but the gate itself must reject it too — fail-closed.
        if !amount.isFinite { return (false, .belowMinimum(minimum)) }
        if amount < minimum { return (false, .belowMinimum(minimum)) }
        if amount > maximum { return (false, .aboveMax(maximum)) }
        return (true, nil)
    }
}
