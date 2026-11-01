// The `basalDeliveryState` and `bolusState` names and their `active`/`suspended`/`noBolus`/`inProgress`
// cases are adapted from LoopKit's PumpManagerStatus (LoopKit/LoopKit `a5beee96`,
// DeviceManager/PumpManagerStatus.swift), Copyright © 2018 LoopKit Authors, MIT License.

import Foundation

/// The phone's link to the pump.
public enum PumpLinkState: String, Sendable, Hashable, Codable {
    case disconnected
    case scanning
    case connecting
    /// Connected, not yet authenticated. Nothing is trusted and nothing is written.
    case authenticating
    /// Connected and authenticated.
    case connected

    public var isConnected: Bool { self == .connected }
}

/// The pump's own CGM reading.
public struct PumpGlucose: Sendable, Hashable, Codable {
    public var mgdl: Int
    /// The trend the source reported, or `nil` when it reported none. Never inferred.
    public var trend: GlucoseTrend?
    public init(mgdl: Int, trend: GlucoseTrend?) {
        self.mgdl = mgdl
        self.trend = trend
    }
}

public struct PumpBattery: Sendable, Hashable, Codable {
    public var percent: Int
    /// Whether the pump says it is charging. `nil` when it didn't say.
    public var isCharging: Bool?
    public init(percent: Int, isCharging: Bool?) {
        self.percent = percent
        self.isCharging = isCharging
    }
}

/// What basal delivery the pump reports.
public enum BasalDeliveryState: Sendable, Hashable, Codable {
    /// Delivering at this rate, whatever set it (profile, temp rate or Control-IQ).
    case active(unitsPerHour: Double)
    /// Insulin delivery is suspended.
    case suspended

    public var isSuspended: Bool { self == .suspended }
}

/// The bolus the pump says it is delivering.
public enum PumpBolusState: Sendable, Hashable, Codable {
    case noBolus
    case inProgress(DoseEntry)
}

/// The bolus calculator settings the pump resolves for its active profile and time segment. They
/// arrive together in one reply, so they share one timestamp and are never half-updated.
public struct BolusCalculatorSettings: Sendable, Hashable, Codable {
    /// Grams of carbohydrate per unit.
    public var carbRatio: Double
    /// Correction factor: mg/dL lowered per unit.
    public var correctionFactor: Int
    /// Target glucose, mg/dL.
    public var targetMgdl: Int
    /// The pump's configured max bolus, units.
    public var maxBolusUnits: Double
    /// The IOB the calculator reply itself reports, units, when it reported one. The dose subtracts the
    /// separate IOB reading; this one only checks it, because right after a bolus one of the two can lag.
    public var insulinOnBoardUnits: Double?

    public init(
        carbRatio: Double, correctionFactor: Int, targetMgdl: Int, maxBolusUnits: Double,
        insulinOnBoardUnits: Double? = nil
    ) {
        self.carbRatio = carbRatio
        self.correctionFactor = correctionFactor
        self.targetMgdl = targetMgdl
        self.maxBolusUnits = maxBolusUnits
        self.insulinOnBoardUnits = insulinOnBoardUnits
    }

    /// A carb ratio, correction factor or target of zero (or less) is impossible, so such a set isn't a
    /// reading the calculator can use.
    public var isUsable: Bool {
        carbRatio.isFinite && carbRatio > 0 && correctionFactor > 0 && targetMgdl > 0
    }
}

public struct ControlIQStatus: Sendable, Hashable, Codable {
    public var isEnabled: Bool
    public var activity: ControlIQActivity
    public init(isEnabled: Bool, activity: ControlIQActivity) {
        self.isEnabled = isEnabled
        self.activity = activity
    }
}

/// The pump's cartridge load state (pumpx2 `LoadStatus.loadStateId`).
public struct CartridgeLoadState: Sendable, Hashable, Codable {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Change cartridge (0), load cartridge (1) and prime tubing (2): Tandem's own loading-state
    /// triad, during which a bolus is impossible. Prime cannula (3) and prime nudge (4) aren't included,
    /// because whether the pump refuses a bolus then hasn't been checked.
    public var isLoading: Bool { (0...2).contains(rawValue) }
}

/// Whether the cartridge allows a bolus attempt.
public enum CartridgeReadiness: Sendable, Hashable {
    /// The pump reported a state other than loading.
    case ready
    /// The pump reported a loading state. A bolus is blocked.
    case notReady
    /// Not read, or the pump doesn't answer the read. A bolus is allowed with a notice, and the pump
    /// refuses without a cartridge.
    case unknown
}

/// The pump's negotiated API version. Says nothing about the model: a t:slim X2 reports 4.0.
public struct PumpAPIVersion: Sendable, Hashable, Codable {
    public var major: Int
    public var minor: Int
    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }
}

/// Everything the app knows about the pump, each value with its measurement time, receipt time and
/// source, or `nil` when it hasn't been read. There are no zero placeholders. `PumpSession` owns it and
/// reports changes as `PumpEvent`s.
///
/// Freshness is always decided from a value's measurement time. The `…IfFresh` accessors are for
/// display; dose decisions use the calculator-input gate, which applies the same windows.
public struct PumpState: Sendable, Hashable, Codable {
    public var link: PumpLinkState = .disconnected
    /// From the stored pairing, so a reconnect without an advertisement still knows it.
    public var model: PumpModel = .unknown
    public var apiVersion: Observed<PumpAPIVersion>?

    public var glucose: Observed<PumpGlucose>?
    /// Insulin on board, units.
    public var insulinOnBoard: Observed<Double>?
    /// Units left in the cartridge. `0` is a real reading: an empty cartridge.
    public var reservoirUnits: Observed<Double>?
    public var battery: Observed<PumpBattery>?
    public var basalDeliveryState: Observed<BasalDeliveryState>?
    public var bolusState: Observed<PumpBolusState>?
    public var lastBolus: Observed<DoseEntry>?
    public var bolusCalculator: Observed<BolusCalculatorSettings>?
    /// The pump's max basal rate limit, units per hour.
    public var maxBasalUnitsPerHour: Observed<Double>?
    public var controlIQ: Observed<ControlIQStatus>?
    public var cartridge: Observed<CartridgeLoadState>?
    /// A CGM sensor session is running on the pump. A warming-up session has no glucose yet.
    public var cgmSessionActive: Observed<Bool>?
    public var alerts: Observed<[PumpAlert]>?
    /// The CGM hardware string the pump reports (op-96). With a Dexcom G6 it is expected to be the
    /// transmitter ID, which is unverified; it is passed on as the pump's string, never as a confirmed ID.
    public var cgmHardwareInfo: Observed<String>?

    public init() {}

    /// Names one observed value, so an event can say which readings changed without the receiver
    /// comparing states.
    public enum Reading: String, Sendable, Hashable, Codable, CaseIterable {
        case apiVersion, glucose, insulinOnBoard, reservoirUnits, battery, basalDeliveryState, bolusState
        case lastBolus, bolusCalculator, maxBasalUnitsPerHour, controlIQ, cartridge, cgmSessionActive, alerts
        case cgmHardwareInfo
    }

    public var capabilities: PumpCapabilities { model.capabilities }

    // MARK: - Freshness
    //
    // Every check takes the windows as a value (`FreshnessThresholds`), so the dose path and the display
    // decide from the same windows the caller holds, never from a process-wide setting.

    /// There is a glucose reading and it is older than the glucose window, or its time can't be trusted:
    /// shown marked as stale, never as current. No reading at all is "no data", not stale; use
    /// `glucoseIfFresh` wherever a current value is needed.
    public func isGlucoseStale(thresholds: FreshnessThresholds, now: Date = Date()) -> Bool {
        glucose?.isStale(after: thresholds.glucoseStaleAfter, now: now) ?? false
    }

    /// The glucose reading while it is current, else `nil`. The only form that may fill a correction.
    public func glucoseIfFresh(thresholds: FreshnessThresholds, now: Date = Date()) -> PumpGlucose? {
        glucose?.valueIfFresh(within: thresholds.glucoseStaleAfter, now: now)
    }

    /// IOB older than the IOB window isn't used without a prompt.
    public func isInsulinOnBoardStale(thresholds: FreshnessThresholds, now: Date = Date()) -> Bool {
        insulinOnBoard?.isStale(after: thresholds.insulinOnBoardStaleAfter, now: now) ?? true
    }

    /// Calculator settings older than the therapy window aren't used without a prompt. Settings that
    /// aren't usable count as stale.
    public func isBolusCalculatorStale(thresholds: FreshnessThresholds, now: Date = Date()) -> Bool {
        guard let bolusCalculator, bolusCalculator.value.isUsable else { return true }
        return bolusCalculator.isStale(after: thresholds.therapyStaleAfter, now: now)
    }

    /// Reservoir units while the reading is no older than the glucose window, else `nil`, so a value that
    /// has gone quiet shows as unknown rather than as current.
    public func reservoirUnitsIfFresh(thresholds: FreshnessThresholds, now: Date = Date()) -> Double? {
        reservoirUnits?.valueIfFresh(within: thresholds.glucoseStaleAfter, now: now)
    }

    /// Battery while the reading is no older than the glucose window, else `nil`.
    public func batteryIfFresh(thresholds: FreshnessThresholds, now: Date = Date()) -> PumpBattery? {
        battery?.valueIfFresh(within: thresholds.glucoseStaleAfter, now: now)
    }

    /// IOB on the same window the dose path gates on, so the display and the calculator can't disagree
    /// about whether it is current.
    public func insulinOnBoardIfFresh(thresholds: FreshnessThresholds, now: Date = Date()) -> Double? {
        insulinOnBoard?.valueIfFresh(within: thresholds.insulinOnBoardStaleAfter, now: now)
    }

    /// Calculator settings on the same window the dose path gates on.
    public func bolusCalculatorIfFresh(thresholds: FreshnessThresholds, now: Date = Date()) -> BolusCalculatorSettings?
    {
        isBolusCalculatorStale(thresholds: thresholds, now: now) ? nil : bolusCalculator?.value
    }

    // MARK: - Cartridge

    public var cartridgeReadiness: CartridgeReadiness {
        guard let cartridge else { return .unknown }
        return cartridge.value.isLoading ? .notReady : .ready
    }
}
