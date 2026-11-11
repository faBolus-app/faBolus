import Foundation

// The fixed vocabularies of the contract. Each raw value is a wire token, so renaming a case is a protocol
// change. A remote that meets a token it doesn't know shows it generically rather than failing the message.

/// The phone's link to the pump.
public enum PumpLinkToken: String, Sendable, Hashable, CaseIterable {
    case disconnected, scanning, connecting, authenticating, connected
}

/// The direction the CGM reported. Never inferred.
public enum TrendToken: String, Sendable, Hashable, CaseIterable {
    case flat, up, upUp = "upup", rising = "up45", down, downDown = "downdown", falling = "down45"
}

public enum SeverityToken: String, Sendable, Hashable, CaseIterable {
    case info, warning, critical
}

/// How the watch announces an alert. The phone decides; the watch follows, capped at vibration. An alert
/// the user turned off on the phone isn't sent at all.
public enum WatchIntentToken: String, Sendable, Hashable, CaseIterable {
    /// Shown, without vibration.
    case quiet
    /// Shown, with vibration.
    case alert
}

/// The pump's Control-IQ activity.
public enum ActivityToken: String, Sendable, Hashable, CaseIterable {
    case normal, sleep, exercise
}

/// Why a remote can't start a bolus right now.
public enum BolusBlockToken: String, Sendable, Hashable, CaseIterable {
    case pumpNotConnected
    case bolusInProgress
    case cartridgeNotReady
    /// Remotes are read-only.
    case readOnly
    /// Bolusing from this watch is turned off on the phone.
    case watchBolusOff
    /// The connected pump can't take a dose from this app.
    case pumpCannotBolus
    /// An earlier bolus's outcome is unknown; it's settled from pump history or by confirming on the pump.
    case outcomeUnknown
    /// The phone can't record a bolus safely (its ledger can't be read or written).
    case deliveryLocked
}

public enum BolusModeToken: String, Sendable, Hashable, CaseIterable {
    /// Carbs through the calculator.
    case carbs
    /// Units the user dials.
    case units
}

/// Something about the pump the user confirms before a remote dose goes. A refused `bolusOutcome` names the
/// ones to ask (`confirm`); the new request the user sends from them names the ones they went on from
/// (`confirmed`).
public enum ConfirmationToken: String, Sendable, Hashable, CaseIterable {
    /// The pump says too many boluses were asked for in a short time.
    case tooManyBoluses
    /// This dose and the last hour's boluses come to more than the max hourly bolus.
    case maxHourlyBolus
    /// The dose is more than the insulin left, or little is left.
    case lowInsulin
}

public enum GlucoseUnitToken: String, Sendable, Hashable, CaseIterable {
    case mgdl, mmol
}

public enum ScreenToken: String, Sendable, Hashable, CaseIterable {
    case glance, glucose, clock, bolusOnly = "bolusonly", alerts, history, details
}

public enum DetailToken: String, Sendable, Hashable, CaseIterable {
    case iob, reservoir, battery, cgm, lastBolus, carbRatio, isf, target, maxBolus, maxBasal
    /// When Control-IQ last auto-corrected; the row is left out while none is known.
    case autoCorrection
}

/// What the watch can put in its three assignable complications.
public enum ComplicationSlotToken: String, Sendable, Hashable, CaseIterable {
    case iob, reservoir, battery, basal
}

/// Where a bolus request stands, as the watch is told.
public enum OutcomeToken: String, Sendable, Hashable, CaseIterable {
    /// The phone has the request and is working on it; nothing that delivers has been sent.
    case received
    /// The pump granted permission; delivery is about to start.
    case accepted
    case delivering
    /// All of it went in.
    case delivered
    /// Less than requested went in: cancelled, stopped by an alarm, or interrupted.
    case stopped
    /// The pump refused. Nothing was delivered.
    case refused
    /// Nothing was delivered, for a reason the phone knows for certain (including the phone's own checks).
    case failed
    /// The phone lost track after something that could deliver was sent. It may have delivered; it's
    /// settled from pump history.
    case unknown

    /// No later message for this request can change it, except `unknown`, which pump history settles.
    public var isFinal: Bool {
        switch self {
        case .delivered, .stopped, .refused, .failed: return true
        case .received, .accepted, .delivering, .unknown: return false
        }
    }

    /// Whether a message saying `next` may replace one saying `self`. A late or duplicated message can't
    /// take a request back to an earlier state or rewrite a settled one. The watch applies the same table.
    public func canMove(to next: OutcomeToken) -> Bool {
        switch (self, next) {
        case (.received, .accepted), (.received, .delivering), (.received, .delivered), (.received, .stopped),
            (.received, .refused), (.received, .failed), (.received, .unknown):
            return true
        case (.accepted, .delivering), (.accepted, .delivered), (.accepted, .stopped), (.accepted, .refused),
            (.accepted, .failed), (.accepted, .unknown):
            return true
        case (.delivering, .delivered), (.delivering, .stopped), (.delivering, .unknown):
            return true
        case (.unknown, .delivered), (.unknown, .stopped), (.unknown, .failed):
            return true
        default:
            return false
        }
    }
}

/// The result of a dismiss from the watch.
public enum DismissResultToken: String, Sendable, Hashable, CaseIterable {
    /// The pump confirmed it. The only result that lets the watch stop showing the alert before the next
    /// status.
    case cleared
    /// The pump refused.
    case refused
    /// No confirmed answer; the alert stays.
    case unconfirmed
    /// This pump can't dismiss it remotely.
    case unsupported
    /// The phone no longer has that alert.
    case notFound
}
