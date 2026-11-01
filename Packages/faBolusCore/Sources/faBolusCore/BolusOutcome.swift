import Foundation

/// Where one bolus request stands. Owned by `RemoteBolusLedger`; the pump layer reports what happened
/// as events and the ledger moves the outcome, so no flag elsewhere can disagree with it.
///
/// ```
/// requested ─▶ accepted ─▶ delivering ─▶ delivered / stopped
///     │            │            └──────▶ unknown ─▶ delivered / stopped / failed (from history)
///     │            ├─▶ refused / failed / unknown / delivered / stopped
///     └─▶ refused / failed / unknown
/// ```
///
/// An unknown outcome is never called failed on a guess: it may have delivered. Only pump history
/// showing there was no such bolus makes it `failed`. It blocks every new bolus, across restarts, until
/// pump history settles it or the user confirms on the pump.
public enum BolusOutcome: Sendable, Hashable, Codable {
    /// Recorded, nothing sent that could deliver insulin.
    case requested
    /// The pump granted permission and the bolus ID is durably recorded; InitiateBolus is next.
    case accepted
    /// The pump accepted InitiateBolus and is delivering.
    case delivering
    /// The pump delivered the whole request.
    case delivered(units: Double)
    /// The pump's authoritative delivered amount is below what was requested: cancelled, stopped by an
    /// alarm, or interrupted. Named for the fact, because pumpx2 doesn't name `BolusCompleted`'s
    /// completion status, so the cause can't be told apart yet.
    case stopped(delivered: Double, requested: Double)
    /// The pump refused, in an authenticated reply. Nothing was delivered.
    case refused(reason: String)
    /// Nothing was delivered, for a reason the app knows for certain (for example the request couldn't
    /// be recorded, the app stopped before sending anything that delivers, or pump history shows the
    /// bolus never happened).
    case failed(reason: String)
    /// The app lost track after something that could deliver was sent: a timeout, a drop, or an
    /// unverified reply. `since` is when that happened.
    case unknown(since: Date)

    /// A final outcome. Only `unknown` can still change once nothing is in flight, and only from pump
    /// history: to the amount it shows, or to failed when it shows no such bolus.
    public var isFinal: Bool {
        switch self {
        case .delivered, .stopped, .refused, .failed: return true
        case .requested, .accepted, .delivering, .unknown: return false
        }
    }

    /// The request is being worked on right now.
    public var isInFlight: Bool {
        switch self {
        case .requested, .accepted, .delivering: return true
        case .delivered, .stopped, .refused, .failed, .unknown: return false
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// Insulin may have gone in: anything from the moment InitiateBolus could have been sent. Used to
    /// keep a retry of the same dose content from going through as a new request.
    public var mayHaveDelivered: Bool {
        switch self {
        case .accepted, .delivering, .unknown: return true
        case .delivered(let units): return units > 0
        case .stopped(let delivered, _): return delivered > 0
        case .requested, .refused, .failed: return false
        }
    }

    /// The units the pump says went in, when it has said.
    public var deliveredUnits: Double? {
        switch self {
        case .delivered(let units): return units
        case .stopped(let delivered, _): return delivered
        case .requested, .accepted, .delivering, .refused, .failed, .unknown: return nil
        }
    }

    /// Whether the outcome may move from `self` to `next`. Moves not drawn above are refused, so a
    /// late or duplicated pump event can't rewrite a settled bolus.
    public func canMove(to next: BolusOutcome) -> Bool {
        switch (self, next) {
        case (.requested, .accepted), (.requested, .refused), (.requested, .failed), (.requested, .unknown):
            return true
        case (.accepted, .delivering), (.accepted, .delivered), (.accepted, .stopped),
            (.accepted, .refused), (.accepted, .failed), (.accepted, .unknown):
            return true
        case (.delivering, .delivered), (.delivering, .stopped), (.delivering, .unknown):
            return true
        case (.unknown, .delivered), (.unknown, .stopped), (.unknown, .failed):
            return true
        default:
            return false
        }
    }

    /// The final outcome for a delivered amount the pump reported: `delivered` when it covers the
    /// request, `stopped` when it falls short by at least half a milliunit (the pump counts in
    /// milliunits, so anything smaller is decoding noise).
    public static func settled(deliveredUnits: Double, requestedUnits: Double) -> BolusOutcome {
        if deliveredUnits < requestedUnits - 0.0005 {
            return .stopped(delivered: deliveredUnits, requested: requestedUnits)
        }
        return .delivered(units: deliveredUnits)
    }
}
