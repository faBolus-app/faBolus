import Foundation

/// Glucose history, sent only when the watch asks. Oldest first, at most `WireLimits.maxHistoryPoints`.
public struct HistoryPayload: Sendable, Hashable {
    public struct Point: Sendable, Hashable {
        public var at: Int
        public var mgdl: Int
        public init(at: Int, mgdl: Int) {
            self.at = at
            self.mgdl = mgdl
        }
    }
    public var sentAt: Int
    public var points: [Point]
    public init(sentAt: Int, points: [Point]) {
        self.sentAt = sentAt
        self.points = points
    }

    /// The newest `maxHistoryPoints`, oldest first, one per second (the last given wins): what fits the
    /// watch's chart and memory, and what the decoder accepts.
    public static func newest(_ points: [Point], sentAt: Int) -> HistoryPayload {
        var byTime: [Int: Point] = [:]
        for point in points where WireLimits.epochs.contains(point.at) && WireLimits.glucose.contains(point.mgdl) {
            byTime[point.at] = point
        }
        let sorted = byTime.values.sorted { $0.at < $1.at }
        return HistoryPayload(sentAt: sentAt, points: Array(sorted.suffix(WireLimits.maxHistoryPoints)))
    }

    var wire: WireValue {
        var w = FieldWriter()
        w.set("sentAt", sentAt)
        w.set("at", ints: points.map(\.at))
        w.set("mgdl", ints: points.map(\.mgdl))
        return w.value
    }

    init(wire: WireValue) throws(DecodeError) {
        let r = try FieldReader(wire, path: "payload")
        sentAt = try r.int("sentAt", in: epochRange)
        let at = try r.intArray("at", maxCount: WireLimits.maxHistoryPoints, in: epochRange)
        let mgdl = try r.intArray("mgdl", maxCount: WireLimits.maxHistoryPoints, in: glucoseRange)
        guard at.count == mgdl.count else { throw .outOfRange(field: "payload.mgdl") }
        guard zip(at, at.dropFirst()).allSatisfy({ $0 < $1 }) else { throw .outOfRange(field: "payload.at") }
        points = zip(at, mgdl).map { Point(at: $0, mgdl: $1) }
    }
}

/// The watch asks for a status. It names what it holds, so the phone can resend what it missed.
public struct PollPayload: Sendable, Hashable {
    /// The config revision the watch holds; `nil` when it has none (first launch, or its storage was wiped).
    public var configRevision: String?
    /// The bolus request the watch is waiting on, so its outcome is sent again if a message was lost.
    public var awaitingRequestId: String?
    /// The watch wants the glucose history.
    public var wantsHistory: Bool
    /// The watch's bolus screen is opening: read the CGM now rather than wait for the next reading.
    public var freshGlucose: Bool
    /// The watch app's version, for diagnostics.
    public var appVersion: String
    public init(
        configRevision: String?, awaitingRequestId: String?, wantsHistory: Bool, freshGlucose: Bool,
        appVersion: String
    ) {
        self.configRevision = configRevision
        self.awaitingRequestId = awaitingRequestId
        self.wantsHistory = wantsHistory
        self.freshGlucose = freshGlucose
        self.appVersion = appVersion
    }

    var wire: WireValue {
        var w = FieldWriter()
        w.set("configRevision", configRevision)
        w.set("awaiting", awaitingRequestId)
        w.set("history", wantsHistory)
        w.set("freshGlucose", freshGlucose)
        w.set("appVersion", appVersion)
        return w.value
    }

    init(wire: WireValue) throws(DecodeError) {
        let r = try FieldReader(wire, path: "payload")
        configRevision = try r.optionalId("configRevision")
        awaitingRequestId = try r.optionalId("awaiting")
        wantsHistory = try r.bool("history")
        freshGlucose = try r.bool("freshGlucose")
        appVersion = try r.string("appVersion", maxLength: WireLimits.maxIdLength)
    }
}

/// A bolus the user confirmed on the watch. The phone checks it, recomputes a calculator dose, and is the
/// authority.
public struct BolusRequestPayload: Sendable, Hashable {
    public enum Amount: Sendable, Hashable {
        /// Units the user dialed, delivered as sent.
        case units(milliunits: Int)
        /// Carbs (zero for a correction only) through the calculator, with the watch's own estimate, which
        /// the phone's recompute must match.
        case calculator(carbsGrams: Int, estimateMilliunits: Int)
        /// With carbs off on the pump: the food entry is insulin units, through the calculator as carbs are,
        /// and no carbs go with the bolus.
        case insulinCalculator(foodMilliunits: Int, estimateMilliunits: Int)
    }
    /// The watch's ID for this request. A resend uses the same ID and gets the same outcome.
    public var requestId: String
    /// When the user confirmed it, by the watch's clock. The phone refuses a request older than two
    /// minutes.
    public var sentAt: Int
    public var amount: Amount
    /// The glucose the estimate used, when it used one.
    public var glucoseMgdl: Int?
    /// The user chose, for this attempt, to correct from a stale reading.
    public var includeStaleGlucose: Bool
    /// The confirmations the user went on from, from an earlier request's refused outcome. Absent is none.
    public var confirmed: [ConfirmationToken]
    /// The user chose carbs only when asked whether to correct from the reading (70 mg/dL or more), which
    /// `glucoseMgdl` names. Absent is false.
    public var declineCorrection: Bool

    public init(
        requestId: String, sentAt: Int, amount: Amount, glucoseMgdl: Int?, includeStaleGlucose: Bool,
        confirmed: [ConfirmationToken] = [], declineCorrection: Bool = false
    ) {
        self.requestId = requestId
        self.sentAt = sentAt
        self.amount = amount
        self.glucoseMgdl = glucoseMgdl
        self.includeStaleGlucose = includeStaleGlucose
        self.confirmed = confirmed
        self.declineCorrection = declineCorrection
    }

    var wire: WireValue {
        var w = FieldWriter()
        w.set("requestId", requestId)
        w.set("sentAt", sentAt)
        switch amount {
        case .units(let mU):
            w.set("mode", BolusModeToken.units.rawValue)
            w.set("mU", mU)
        case .calculator(let carbs, let estimate):
            w.set("mode", BolusModeToken.carbs.rawValue)
            w.set("carbsG", carbs)
            w.set("estimateMU", estimate)
        case .insulinCalculator(let food, let estimate):
            w.set("mode", BolusModeToken.carbs.rawValue)
            w.set("foodMU", food)
            w.set("estimateMU", estimate)
        }
        w.set("glucoseMgdl", glucoseMgdl)
        w.set("includeStaleGlucose", includeStaleGlucose)
        if !confirmed.isEmpty { w.set("confirmed", strings: confirmed.map(\.rawValue)) }
        if declineCorrection { w.set("declineCorrection", true) }
        return w.value
    }

    init(wire: WireValue) throws(DecodeError) {
        let r = try FieldReader(wire, path: "payload")
        requestId = try r.id("requestId")
        sentAt = try r.int("sentAt", in: epochRange)
        switch try r.token("mode", as: BolusModeToken.self) {
        case .units:
            amount = .units(milliunits: try r.int("mU", in: milliunitRange))
        case .carbs:
            // The calculator's food entry is grams (`carbsG`) or, with carbs off, units (`foodMU`): one of
            // the two, never both.
            let estimate = try r.int("estimateMU", in: milliunitRange)
            if let food = try r.optionalInt("foodMU", in: milliunitRange) {
                guard try r.optionalInt("carbsG", in: 0...WireLimits.maxCarbsGrams) == nil else {
                    throw .outOfRange(field: "payload.carbsG")
                }
                amount = .insulinCalculator(foodMilliunits: food, estimateMilliunits: estimate)
            } else {
                amount = .calculator(
                    carbsGrams: try r.int("carbsG", in: 0...WireLimits.maxCarbsGrams), estimateMilliunits: estimate)
            }
        }
        glucoseMgdl = try r.optionalInt("glucoseMgdl", in: glucoseRange)
        includeStaleGlucose = try r.bool("includeStaleGlucose")
        confirmed = try r.optionalTokenArray("confirmed", as: ConfirmationToken.self)
        declineCorrection = try r.optionalBool("declineCorrection") ?? false
    }
}

/// Where a bolus request stands. Sent on every move, and again whenever the watch's poll names the request.
public struct BolusOutcomePayload: Sendable, Hashable {
    public var requestId: String
    public var outcome: OutcomeToken
    public var requestedMilliunits: Int?
    /// What the pump says went in, when it has said.
    public var deliveredMilliunits: Int?
    /// Why, for a refusal or failure; shown to the user.
    public var message: String?
    /// For a request not delivered (`failed` or `refused`): what the user may confirm, on the remote, to send
    /// the dose again as a new request naming them. Absent is none.
    public var confirm: [ConfirmationToken]
    public var sentAt: Int

    public init(
        requestId: String, outcome: OutcomeToken, requestedMilliunits: Int?, deliveredMilliunits: Int?,
        message: String?, confirm: [ConfirmationToken] = [], sentAt: Int
    ) {
        self.requestId = requestId
        self.outcome = outcome
        self.requestedMilliunits = requestedMilliunits
        self.deliveredMilliunits = deliveredMilliunits
        self.message = message
        self.confirm = confirm
        self.sentAt = sentAt
    }

    var wire: WireValue {
        var w = FieldWriter()
        w.set("requestId", requestId)
        w.set("outcome", outcome.rawValue)
        w.set("requestedMU", requestedMilliunits)
        w.set("deliveredMU", deliveredMilliunits)
        w.set("message", message)
        if !confirm.isEmpty { w.set("confirm", strings: confirm.map(\.rawValue)) }
        w.set("sentAt", sentAt)
        return w.value
    }

    init(wire: WireValue) throws(DecodeError) {
        let r = try FieldReader(wire, path: "payload")
        requestId = try r.id("requestId")
        outcome = try r.token("outcome", as: OutcomeToken.self)
        requestedMilliunits = try r.optionalInt("requestedMU", in: milliunitRange)
        deliveredMilliunits = try r.optionalInt("deliveredMU", in: milliunitRange)
        message = try r.optionalString("message", maxLength: WireLimits.maxTextLength)
        confirm = try r.optionalTokenArray("confirm", as: ConfirmationToken.self)
        // Only a request that wasn't delivered can be confirmed and sent again.
        guard confirm.isEmpty || outcome == .failed || outcome == .refused else {
            throw .outOfRange(field: "payload.confirm")
        }
        sentAt = try r.int("sentAt", in: epochRange)
    }
}

/// Stop the bolus in progress. Never gated. The result arrives as the bolus's outcome and in the status.
public struct CancelPayload: Sendable, Hashable {
    public var requestId: String
    /// The bolus the watch means, when it started one; the phone cancels whatever the pump is delivering.
    public var bolusRequestId: String?
    public init(requestId: String, bolusRequestId: String?) {
        self.requestId = requestId
        self.bolusRequestId = bolusRequestId
    }

    var wire: WireValue {
        var w = FieldWriter()
        w.set("requestId", requestId)
        w.set("bolusRequestId", bolusRequestId)
        return w.value
    }

    init(wire: WireValue) throws(DecodeError) {
        let r = try FieldReader(wire, path: "payload")
        requestId = try r.id("requestId")
        bolusRequestId = try r.optionalId("bolusRequestId")
    }
}

/// Dismiss one alert on the pump. A resend uses the same request ID.
public struct DismissPayload: Sendable, Hashable {
    public var requestId: String
    public var alertId: String
    public init(requestId: String, alertId: String) {
        self.requestId = requestId
        self.alertId = alertId
    }

    var wire: WireValue {
        var w = FieldWriter()
        w.set("requestId", requestId)
        w.set("alertId", alertId)
        return w.value
    }

    init(wire: WireValue) throws(DecodeError) {
        let r = try FieldReader(wire, path: "payload")
        requestId = try r.id("requestId")
        alertId = try r.id("alertId")
    }
}

/// The answer to a dismiss. The status that follows is still the authority on which alerts are active.
public struct DismissResultPayload: Sendable, Hashable {
    public var requestId: String
    public var alertId: String
    public var result: DismissResultToken
    public init(requestId: String, alertId: String, result: DismissResultToken) {
        self.requestId = requestId
        self.alertId = alertId
        self.result = result
    }

    var wire: WireValue {
        var w = FieldWriter()
        w.set("requestId", requestId)
        w.set("alertId", alertId)
        w.set("result", result.rawValue)
        return w.value
    }

    init(wire: WireValue) throws(DecodeError) {
        let r = try FieldReader(wire, path: "payload")
        requestId = try r.id("requestId")
        alertId = try r.id("alertId")
        result = try r.token("result", as: DismissResultToken.self)
    }
}

/// The reply to a message from another protocol version: the two sides can't talk until one is updated.
public struct IncompatiblePayload: Sendable, Hashable {
    /// The version the other side sent.
    public var peerVersion: Int
    public init(peerVersion: Int) { self.peerVersion = peerVersion }

    var wire: WireValue {
        var w = FieldWriter()
        w.set("peerVersion", peerVersion)
        return w.value
    }

    init(wire: WireValue) throws(DecodeError) {
        let r = try FieldReader(wire, path: "payload")
        peerVersion = try r.int("peerVersion", in: 0...1000)
    }
}
