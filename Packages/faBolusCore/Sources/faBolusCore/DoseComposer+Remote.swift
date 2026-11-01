import Foundation

/// An insulin request from a paired remote, independent of the transport that carried it.
public struct RemoteDoseRequest: Sendable, Equatable {
    public enum Amount: Sendable, Equatable {
        /// Units the user dialed on the remote. Delivered as sent; the phone doesn't recompute them.
        case units(Double)
        /// Carbs (zero for a correction only) through the calculator. The phone recomputes and is
        /// authoritative; `estimateUnits` is the remote's own result, which the recompute must match.
        case calculator(carbsGrams: Double, estimateUnits: Double?)
    }

    /// The remote's own request ID, so a resent message is the same request.
    public var id: String
    /// Names the remote in the ledger (for example `"garmin"`).
    public var peerId: String
    public var surface: AccessPolicy.Surface
    /// When the remote sent it, by the remote's clock.
    public var sentAt: Date?
    /// `nil` when the message named neither units nor carbs.
    public var amount: Amount?
    /// The glucose the remote estimated from. Never a dose input: the phone corrects from its own reading,
    /// and this only has to match that reading for a stale one to be included.
    public var glucoseMgdl: Int?
    /// The user chose, for this attempt, to include a stale reading in the correction.
    public var includeStaleGlucose: Bool

    public init(
        id: String, peerId: String, surface: AccessPolicy.Surface, sentAt: Date?, amount: Amount?,
        glucoseMgdl: Int? = nil, includeStaleGlucose: Bool = false
    ) {
        self.id = id
        self.peerId = peerId
        self.surface = surface
        self.sentAt = sentAt
        self.amount = amount
        self.glucoseMgdl = glucoseMgdl
        self.includeStaleGlucose = includeStaleGlucose
    }

    /// A v1 `bolusRequest`, or `nil` for any other kind. A carb request is signalled by `carbsGrams`
    /// being present at all, including zero, so a correction-only dose isn't read as zero units. An
    /// extended bolus has no amount, so it is refused rather than delivered all at once.
    public init?(v1 command: RemoteCommand, peerId: String, surface: AccessPolicy.Surface) {
        guard command.kind == .bolusRequest else { return nil }
        let amount: Amount?
        if command.extendedMinutes != nil || command.extendedNowUnits != nil {
            amount = nil
        } else if let carbs = command.carbsGrams {
            amount = .calculator(carbsGrams: carbs, estimateUnits: command.remoteEstimateUnits)
        } else {
            amount = command.units.map { .units($0) }
        }
        let glucose = command.bgMgdl.flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil }
        self.init(
            id: command.requestId, peerId: peerId, surface: surface,
            sentAt: command.sentAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            amount: amount, glucoseMgdl: glucose, includeStaleGlucose: command.includeStaleBG ?? false)
    }

    public var ledgerKey: RemoteBolusLedger.Key { .init(peerId: peerId, requestId: id) }

    /// Whether `recorded` is this same request, by what the remote sent rather than what the phone
    /// computed from it.
    func isSameRequest(as recorded: DoseRequest) -> Bool {
        guard recorded.ledgerKey == ledgerKey, recorded.bgMgdl == glucoseMgdl else { return false }
        switch amount {
        case .units(let units): return recorded.carbsGrams == nil && recorded.shape == .now(units: units)
        case .calculator(let carbs, _): return recorded.carbsGrams == carbs
        case nil: return false
        }
    }
}

/// The composer's answer to a remote request.
public enum RemoteDoseDecision: Sendable, Equatable {
    case deliver(ComposedDose)
    case refused(DoseRefusal)
    /// The ledger already holds this request. Answer with its outcome; it is never delivered again.
    case alreadyRecorded(BolusOutcome)
}

extension DoseComposer {
    /// Compose a remote's request. The remote has already had the user confirm on it; there's no
    /// prompt here, so every check either passes or refuses.
    ///
    /// - Parameter ledger: the ledger as it stands (`DurableBolusLedger.ledger`). A resent request is
    ///   answered from its entry before any other check, so a remote that missed an outcome gets it back
    ///   rather than a refusal computed from inputs that moved because of that very bolus. The same dose
    ///   delivered moments ago under another request ID is refused.
    public static func composeRemote(
        _ request: RemoteDoseRequest, ledger: RemoteBolusLedger, context: DoseContext
    ) -> RemoteDoseDecision {
        // A remote never speaks for the phone: phone rules would skip the remote switches, and the phone's
        // peer ID would share the phone's ledger entries.
        guard request.surface.isRemote, request.peerId != DoseRequest.Origin.phonePeerId else {
            return .refused(.notARemote)
        }
        if let recorded = ledger.entry(request.ledgerKey) {
            guard request.isSameRequest(as: recorded.request) else { return .refused(.requestIdReused) }
            return .alreadyRecorded(recorded.outcome)
        }
        guard let amount = request.amount else { return .refused(.noDoseSpecified) }
        guard let sentAt = request.sentAt, !RemoteCommandFreshness.isStale(sentAt: sentAt, now: context.now) else {
            return .refused(.requestTooOld)
        }
        if let last = context.lastDeliveryAt, last > sentAt { return .refused(.supersededByDelivery) }
        if let refusal = availability(surface: request.surface, context: context) { return .refused(refusal) }

        let units: Double
        var carbsGrams: Double?
        var iob: Double?
        var correction: Int?
        var usedStale = false
        switch amount {
        case .units(let sent):
            guard sent.isFinite, sent >= 0 else { return .refused(.invalidAmount) }
            units = sent
        case .calculator(let carbs, let estimate):
            guard carbs.isFinite, carbs >= 0 else { return .refused(.invalidAmount) }
            guard let estimate, estimate.isFinite else { return .refused(.missingEstimate) }
            let inputs = CalculatorInputs(context: context)
            guard inputs.isVerified else { return .refused(.pumpSettingsNotVerified) }
            (correction, usedStale) = remoteCorrectionGlucose(request, context: context)
            guard let dose = inputs.units(carbsGrams: carbs, glucoseMgdl: correction) else {
                return .refused(.pumpSettingsUnusable)
            }
            if differs(dose, estimate) { return .refused(.doseChanged(estimateUnits: estimate, doseUnits: dose)) }
            units = dose
            carbsGrams = carbs
            iob = inputs.calculatorInsulinOnBoardUnits
        }

        if let refusal = bounds(units, context: context) { return .refused(refusal) }
        if let limit = context.remoteSizeLimitUnits, limit.isFinite, limit > 0, units > limit {
            return .refused(.aboveRemoteLimit(limit))
        }

        let dose = DoseRequest(
            id: request.id, origin: .remote(peerId: request.peerId, sentAt: sentAt), shape: .now(units: units),
            carbsGrams: carbsGrams, bgMgdl: request.glucoseMgdl)
        // A remote that missed the outcome and resends under a new ID would otherwise dose twice.
        if ledger.hasRecentlyDeliveredDuplicate(peerId: request.peerId, doseKey: dose.doseKey, now: context.now) {
            return .refused(.recentlyDelivered)
        }
        let recorded = recordedCorrection(correction)
        return .deliver(
            ComposedDose(
                request: dose, calculatorIOBUnits: iob, correctionGlucoseMgdl: recorded.mgdl,
                usedIncludedStaleGlucose: usedStale,
                notices: pumpNotices(units: units, context: context) + recorded.notices
            ))
    }

    /// The glucose a remote carb dose corrects from. A fresh reading always wins. A stale one is used
    /// only when the user asked to include it, it may be included at all, and it is the value the remote
    /// estimated from. Otherwise there is no correction: carbs only.
    private static func remoteCorrectionGlucose(_ request: RemoteDoseRequest, context: DoseContext) -> (
        mgdl: Int?, usedStale: Bool
    ) {
        if let fresh = context.pump.glucoseIfFresh(now: context.now) { return (fresh.mgdl, false) }
        guard request.includeStaleGlucose, let reading = includableStaleReading(context),
            request.glucoseMgdl == reading.value.mgdl
        else { return (nil, false) }
        return (reading.value.mgdl, true)
    }
}
