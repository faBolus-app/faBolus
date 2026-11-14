import Alerts
import CryptoKit
import Foundation
import RemoteProtocol
import faBolusCore

/// Everything a status is built from, captured at one moment.
public struct StatusInputs: Sendable {
    /// With glucose already merged from any backup source (`GlucoseArbiter.merge`).
    public var pump: PumpState
    public var glucoseProvenance: GlucoseProvenance
    public var access: AccessPolicy.AccessContext
    public var bolusBlock: BolusBlock?
    /// The alerts the phone holds and has announced (`AlertSnapshot.active`).
    public var alerts: [ActiveAlert]
    /// When Control-IQ last gave an automatic correction, from the pump's history; `nil` when none is known.
    public var lastAutoCorrection: Date?
    public var configRevision: String
    public var remoteSizeLimitUnits: Double?
    public var now: Date

    public init(
        pump: PumpState, glucoseProvenance: GlucoseProvenance, access: AccessPolicy.AccessContext,
        bolusBlock: BolusBlock?, alerts: [ActiveAlert], lastAutoCorrection: Date?,
        configRevision: String, remoteSizeLimitUnits: Double?, now: Date
    ) {
        self.pump = pump
        self.glucoseProvenance = glucoseProvenance
        self.access = access
        self.bolusBlock = bolusBlock
        self.alerts = alerts
        self.lastAutoCorrection = lastAutoCorrection
        self.configRevision = configRevision
        self.remoteSizeLimitUnits = remoteSizeLimitUnits
        self.now = now
    }
}

/// Builds the status the watch is sent. Each value keeps the time it was measured, so the watch judges its
/// age itself; a value whose time can't be trusted isn't sent, rather than sent as current. A value outside
/// what the message allows isn't sent either: one bad reading must not make every status unreadable.
public enum StatusComposer {
    /// The pump's reason its reading shouldn't correct a dose by itself, as the phone's composer checks it:
    /// the remote then doses carbs only, with no question, as the phone does.
    static func cautionToken(_ caution: PumpGlucoseCaution) -> GlucoseCautionToken {
        switch caution {
        case .outOfRange(.low): return .low
        case .outOfRange(.high): return .high
        case .sensorState: return .sensor
        case .checkBG: return .checkBG
        case .autoFillOff: return .autoFillOff
        case .cgmStateNotRead: return .notRead
        }
    }

    public static func compose(_ inputs: StatusInputs) -> StatusPayload {
        let pump = inputs.pump
        let now = inputs.now
        func at<V>(_ o: Observed<V>?) -> Int? {
            guard let o, o.hasValidTime, o.measuredAt <= now.addingTimeInterval(Observed<V>.futureSkewTolerance)
            else { return nil }
            return epoch(o.measuredAt)
        }
        let glucose = pump.glucose.flatMap { g -> Timed<RemoteProtocol.GlucoseReading>? in
            guard WireLimits.glucose.contains(g.value.mgdl) else { return nil }
            return at(g).map {
                Timed(
                    GlucoseReading(
                        mgdl: g.value.mgdl, trend: g.value.trend.flatMap(trendToken),
                        backup: inputs.glucoseProvenance.isFailover,
                        caution: pump.glucoseCaution().map(cautionToken)), at: $0)
            }
        }
        let iob = pump.insulinOnBoard.flatMap { o in at(o).flatMap { t in milliunits(o.value).map { Timed($0, at: t) } }
        }
        let reservoir = pump.reservoirUnits.flatMap { o in
            at(o).flatMap { t in milliunits(o.value).map { Timed($0, at: t) } }
        }
        let battery = pump.battery.flatMap { o -> Timed<BatteryReading>? in
            guard (0...100).contains(o.value.percent) else { return nil }
            return at(o).map { Timed(BatteryReading(percent: o.value.percent, charging: o.value.isCharging), at: $0) }
        }
        let basal = pump.basalDeliveryState.flatMap { o -> Timed<BasalReading>? in
            guard let t = at(o) else { return nil }
            switch o.value {
            case .suspended: return Timed(.suspended, at: t)
            // The watch's protocol has no temp rate or Basal-IQ suspension: it shows the rate delivered. A
            // Basal-IQ suspension isn't sent as suspended, which says a bolus can't go.
            case .active(let rate), .tempRate(let rate, _):
                return milliunits(rate).map { Timed(.active(milliunitsPerHour: $0), at: t) }
            case .basalIQSuspended: return Timed(.active(milliunitsPerHour: 0), at: t)
            }
        }
        let lastBolus = pump.lastBolus.flatMap { o -> Timed<Int>? in
            guard at(o) != nil, let t = epoch(o.value.startDate) else { return nil }
            return milliunits(o.value.deliveredUnits ?? o.value.programmedUnits).map { Timed($0, at: t) }
        }
        let calculator = pump.bolusCalculator.flatMap { o -> Timed<CalculatorSettings>? in
            // With carbs off the ratio isn't used, and what the pump reports for it then isn't known: 0.
            guard let t = at(o), o.value.isUsable, let max = milliunits(o.value.maxBolusUnits),
                let ratio = o.value.carbsOff ? 0 : milliunits(o.value.carbRatio),
                WireLimits.carbRatioMilligrams.contains(ratio),
                WireLimits.calculatorMgdl.contains(o.value.correctionFactor),
                WireLimits.calculatorMgdl.contains(o.value.targetMgdl)
            else { return nil }
            return Timed(
                CalculatorSettings(
                    carbRatioMilligramsPerUnit: ratio, correctionFactor: o.value.correctionFactor,
                    targetMgdl: o.value.targetMgdl, maxBolusMilliunits: max, carbsOff: o.value.carbsOff), at: t)
        }
        let controlIQ = pump.controlIQ.flatMap { o in
            at(o).map {
                Timed(ControlIQReading(enabled: o.value.isEnabled, activity: activityToken(o.value.activity)), at: $0)
            }
        }
        let maxBasal = pump.maxBasalUnitsPerHour.flatMap { o in
            at(o).flatMap { t in milliunits(o.value).map { Timed($0, at: t) } }
        }
        var active: ActiveBolus?
        if case .inProgress(let entry)? = pump.bolusState?.value, let requested = milliunits(entry.programmedUnits),
            let started = epoch(entry.startDate)
        {
            active = ActiveBolus(
                requestedMilliunits: requested, deliveredMilliunits: entry.deliveredUnits.flatMap(milliunits),
                startedAt: started)
        }
        let autoCorrection = inputs.lastAutoCorrection.flatMap {
            $0 <= now.addingTimeInterval(CalcInputFreshness.futureSkewTolerance) ? epoch($0) : nil
        }
        let refusal = DoseComposer.availability(
            surface: .garmin, pump: pump, access: inputs.access, bolusBlock: inputs.bolusBlock)
        return StatusPayload(
            sentAt: wireEpoch(now), configRevision: inputs.configRevision, pumpLink: linkToken(pump.link),
            glucose: glucose, insulinOnBoardMilliunits: iob, reservoirMilliunits: reservoir, battery: battery,
            basal: basal, lastBolusMilliunits: lastBolus, calculator: calculator, controlIQ: controlIQ,
            maxBasalMilliunitsPerHour: maxBasal, lastAutoCorrectionAt: autoCorrection,
            bolusBlock: refusal.map(blockToken), activeBolus: active,
            alerts: alertItems(inputs.alerts),
            remoteLimitMilliunits: inputs.remoteSizeLimitUnits.flatMap(milliunits))
    }

    /// The alerts the watch mirrors, most severe first, as many as a message carries. One the user turned
    /// off on the phone isn't in the list at all.
    static func alertItems(_ alerts: [ActiveAlert]) -> [AlertItem] {
        let items = alerts.compactMap { alert -> AlertItem? in
            let intent: WatchIntentToken
            switch alert.watchIntent {
            case .off: return nil
            case .quiet: intent = .quiet
            case .alert, .urgent: intent = .alert
            }
            // The watch clears only what's `.available`: a pump not yet known is the phone's to try.
            let dismissable = alert.pumpAlert?.remoteClearOffered ?? false
            return AlertItem(
                id: wireId(alert.identifier),
                title: truncated(alert.title, WireLimits.maxTitleLength),
                body: truncated(alert.body, WireLimits.maxTextLength), severity: severityToken(alert.severity),
                intent: intent, dismissable: dismissable)
        }
        let ranked = items.enumerated().sorted {
            let a = rank($0.element.severity)
            let b = rank($1.element.severity)
            return a != b ? a > b : $0.offset < $1.offset
        }
        return Array(ranked.map(\.element).prefix(WireLimits.maxListCount))
    }

    /// An alert's ID on the wire: the phone's identifier when it fits, else a prefix and a digest of the
    /// whole, so two long identifiers never become one. A dismiss is matched the same way.
    static func wireId(_ identifier: String) -> String {
        guard identifier.count > WireLimits.maxIdLength else { return identifier }
        let digest = SHA256.hash(data: Data(identifier.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return String(identifier.prefix(WireLimits.maxIdLength - 17)) + "#" + digest
    }

    static func blockToken(_ refusal: DoseRefusal) -> BolusBlockToken {
        switch refusal {
        case .unavailable(let reason):
            switch reason {
            case .pumpNotLinked, .remoteUnreachable: return .pumpNotConnected
            case .bolusInFlight: return .bolusInProgress
            case .noCartridge: return .cartridgeNotReady
            case .accessDenied(.remotesReadOnly), .accessDenied(.phoneReadOnly): return .readOnly
            case .accessDenied(.remoteBolusDisabled): return .watchBolusOff
            case .accessDenied(.capabilityUnavailable), .belowMinimum, .aboveMax: return .pumpCannotBolus
            }
        case .blocked(let block):
            switch block {
            case .bolusInProgress: return .bolusInProgress
            case .unknownOutcome: return .outcomeUnknown
            case .noDurableStore, .ledgerUnreadable, .outcomeNotSaved: return .deliveryLocked
            }
        default:
            return .pumpCannotBolus
        }
    }

    static func linkToken(_ link: PumpLinkState) -> PumpLinkToken {
        switch link {
        case .disconnected: return .disconnected
        case .scanning: return .scanning
        case .connecting: return .connecting
        case .authenticating: return .authenticating
        case .connected: return .connected
        }
    }

    static func trendToken(_ trend: GlucoseTrend) -> TrendToken? { TrendToken(rawValue: trend.token) }

    static func activityToken(_ activity: ControlIQActivity) -> ActivityToken {
        switch activity {
        case .normal: return .normal
        case .sleep: return .sleep
        case .exercise: return .exercise
        }
    }

    static func severityToken(_ severity: AlertSeverity) -> SeverityToken {
        switch severity {
        case .info: return .info
        case .warning: return .warning
        case .critical: return .critical
        }
    }

    private static func rank(_ s: SeverityToken) -> Int {
        switch s {
        case .info: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }
}

/// Units to milliunits, for the wire. `nil` for a value that isn't a finite amount in range.
func milliunits(_ units: Double) -> Int? {
    guard units.isFinite else { return nil }
    let mU = (units * 1000).rounded()
    guard mU >= 0, mU <= Double(WireLimits.maxMilliunits) else { return nil }
    return Int(mU)
}

/// Now in epoch seconds for a message's `sentAt`, held to what the watch can store: a phone whose clock is
/// that far off still sends messages that read.
func wireEpoch(_ date: Date) -> Int {
    let s = date.timeIntervalSince1970
    guard s.isFinite else { return WireLimits.epochs.lowerBound }
    return Int(min(Double(WireLimits.epochs.upperBound), max(Double(WireLimits.epochs.lowerBound), s.rounded(.down))))
}

/// Epoch seconds the watch can hold, or `nil`.
func epoch(_ date: Date) -> Int? {
    let s = date.timeIntervalSince1970
    guard s.isFinite, s >= 1_577_836_800, s <= 2_147_483_647 else { return nil }
    return Int(s.rounded(.down))
}

func truncated(_ s: String, _ limit: Int) -> String {
    guard s.count > limit else { return s }
    return String(s.prefix(limit - 1)) + "…"
}
