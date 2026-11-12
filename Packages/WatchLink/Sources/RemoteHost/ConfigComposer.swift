import Foundation
import RemoteProtocol
import faBolusCore

/// The phone's settings that shape the watch, as the app stores them. Unknown or impossible values are
/// corrected when the config is built, so the watch always gets one it can use.
public struct WatchPreferences: Sendable, Hashable {
    /// `"carbs"` or `"units"`.
    public var bolusMode = "carbs"
    public var bolusIncrementUnits = 0.05
    public var carbIncrementGrams = 5
    public var screenOrder = ["glance", "alerts", "history", "details"]
    public var defaultScreen = "glance"
    public var detailsOrder = [
        "iob", "reservoir", "battery", "cgm", "lastBolus", "carbRatio", "isf", "target", "maxBolus"
    ]
    public var watchChartRanges = [3, 6, 12, 24]
    public var complicationSlots = ["iob", "reservoir", "battery"]
    /// The slots' labels name what they show; off (the default), the value alone.
    public var complicationLabels = false
    /// `"mgdl"` or `"mmol"`.
    public var glucoseDisplayUnit = "mgdl"
    public var glucosePlotFloor: Int?
    public var glucosePlotCeiling: Int?
    /// The small-screen override, which a watch uses ahead of the shared bounds.
    public var glucosePlotFloorSmall: Int?
    public var glucosePlotCeilingSmall: Int?

    public init() {}
}

public enum ConfigComposer {
    /// Whether the watch may bolus comes from the access context the phone enforces, and its staleness from
    /// the windows the phone itself uses (`PumpSession.freshness`), so neither can drift apart: one setting,
    /// both surfaces.
    public static func compose(
        _ p: WatchPreferences, access: AccessPolicy.AccessContext, freshness: FreshnessThresholds
    ) -> WatchConfig {
        let defaults = WatchPreferences()
        var order = unique(p.screenOrder.compactMap(ScreenToken.init(rawValue:)))
        if order.isEmpty { order = defaults.screenOrder.compactMap(ScreenToken.init(rawValue:)) }
        let defaultScreen = ScreenToken(rawValue: p.defaultScreen).flatMap { order.contains($0) ? $0 : nil } ?? order[0]
        var hours = unique(p.watchChartRanges.filter(WatchConfig.allowedChartHours.contains))
        if hours.isEmpty { hours = WatchConfig.allowedChartHours }
        let plot = GlucosePlotScale.resolve(
            storedFloor: p.glucosePlotFloorSmall ?? p.glucosePlotFloor,
            storedCeiling: p.glucosePlotCeilingSmall ?? p.glucosePlotCeiling)
        let step = milliunits(p.bolusIncrementUnits).map { min(10_000, max(10, $0)) } ?? 50
        return WatchConfig(
            bolusEnabled: access.garminBolusEnabled, readOnly: access.remotesReadOnly,
            defaultBolusMode: BolusModeToken(rawValue: p.bolusMode) ?? .carbs, unitsStepMilliunits: step,
            carbStepGrams: min(50, max(1, p.carbIncrementGrams)), screenOrder: order, defaultScreen: defaultScreen,
            detailsOrder: unique(p.detailsOrder.compactMap(DetailToken.init(rawValue:))), chartHours: hours,
            complicationSlots: Array(
                unique(p.complicationSlots.compactMap(ComplicationSlotToken.init(rawValue:)))
                    .prefix(WatchConfig.maxComplicationSlots)),
            complicationLabels: p.complicationLabels,
            glucoseUnit: GlucoseUnitToken(rawValue: p.glucoseDisplayUnit) ?? .mgdl,
            glucoseStaleMinutes: minutes(freshness.glucoseStaleAfter, max: 60),
            iobStaleMinutes: minutes(freshness.insulinOnBoardStaleAfter, max: 60),
            therapyStaleMinutes: minutes(freshness.therapyStaleAfter, max: 240),
            pumpStatusStaleMinutes: minutes(freshness.pumpStatusStaleAfter, max: 240),
            glucoseHideDelayMinutes: hideDelayMinutes(freshness),
            glucoseIncludableMinutes: minutes(freshness.maxIncludableGlucoseAge, max: 240),
            plotFloorMgdl: plot.floor, plotCeilingMgdl: plot.ceiling)
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Whole minutes, rounded down, so the watch never counts a value current for longer than the phone does.
    /// A window the phone can't use (not finite, or negative) makes every reading stale there; 0 does the same
    /// on the watch.
    static func minutes(_ window: TimeInterval, max upper: Int) -> Int {
        guard window.isFinite, window >= 0 else { return 0 }
        return min(upper, Int(window / 60))
    }

    /// How long after going stale a reading is hidden; the phone's window is the age it's hidden at.
    static func hideDelayMinutes(_ f: FreshnessThresholds) -> Int? {
        guard let hide = f.glucoseHideAfter, hide.isFinite else { return nil }
        let stale = minutes(f.glucoseStaleAfter, max: 60)
        return min(1440, max(0, Int((hide - Double(stale * 60)) / 60)))
    }
}

extension RemoteDoseRequest {
    /// A version 2 bolus request. Milliunits become units exactly, so a resend matches its ledger entry.
    public init(v2 p: BolusRequestPayload, peerId: String, surface: AccessPolicy.Surface) {
        let amount: Amount
        switch p.amount {
        case .units(let mU): amount = .units(Double(mU) / 1000)
        case .calculator(let carbs, let estimate):
            amount = .calculator(carbsGrams: Double(carbs), estimateUnits: Double(estimate) / 1000)
        case .insulinCalculator(let food, let estimate):
            amount = .calculator(food: .insulin(units: Double(food) / 1000), estimateUnits: Double(estimate) / 1000)
        }
        self.init(
            id: p.requestId, peerId: peerId, surface: surface,
            sentAt: Date(timeIntervalSince1970: TimeInterval(p.sentAt)), amount: amount, glucoseMgdl: p.glucoseMgdl,
            includeStaleGlucose: p.includeStaleGlucose, confirmed: Set(p.confirmed.map(DoseConfirmation.Kind.init)),
            declineCorrection: p.declineCorrection)
    }
}

extension ConfirmationToken {
    init(_ kind: DoseConfirmation.Kind) {
        switch kind {
        case .tooManyBoluses: self = .tooManyBoluses
        case .maxHourlyBolus: self = .maxHourlyBolus
        case .lowInsulin: self = .lowInsulin
        }
    }
}

extension DoseConfirmation.Kind {
    init(_ token: ConfirmationToken) {
        switch token {
        case .tooManyBoluses: self = .tooManyBoluses
        case .maxHourlyBolus: self = .maxHourlyBolus
        case .lowInsulin: self = .lowInsulin
        }
    }
}

extension BolusOutcomePayload {
    /// The watch's view of a ledger entry.
    public init(requestId: String, outcome: BolusOutcome, requestedUnits: Double?, sentAt: Int) {
        let token: OutcomeToken
        var delivered: Int?
        var message: String?
        switch outcome {
        case .requested: token = .received
        case .accepted: token = .accepted
        case .delivering: token = .delivering
        case .delivered(let units):
            token = .delivered
            delivered = milliunits(units)
        case .stopped(let units, _):
            token = .stopped
            delivered = milliunits(units)
        case .refused(let reason):
            token = .refused
            message = truncated(reason, WireLimits.maxTextLength)
        case .failed(let reason):
            token = .failed
            message = truncated(reason, WireLimits.maxTextLength)
        case .unknown:
            token = .unknown
            message = Self.unknownMessage
        }
        self.init(
            requestId: requestId, outcome: token, requestedMilliunits: requestedUnits.flatMap(milliunits),
            deliveredMilliunits: delivered, message: message, sentAt: sentAt)
    }

    /// Nothing was delivered, for a reason the phone gave before anything was sent.
    public static func notDelivered(
        requestId: String, reason: String, confirm: [DoseConfirmation.Kind] = [], sentAt: Int
    ) -> BolusOutcomePayload {
        BolusOutcomePayload(
            requestId: requestId, outcome: .failed, requestedMilliunits: nil, deliveredMilliunits: nil,
            message: truncated(reason, WireLimits.maxTextLength), confirm: confirm.map(ConfirmationToken.init),
            sentAt: sentAt)
    }

    public static let unknownMessage = "Bolus sent but outcome is unknown — check the pump before dosing again."
}
