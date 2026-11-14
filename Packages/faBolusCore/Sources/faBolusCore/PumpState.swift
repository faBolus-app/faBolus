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
    /// The pump marked the reading LOW or HIGH: the sensor is beyond its range, so the number is only its
    /// edge, not the glucose. `nil` for a reading in range.
    public var outOfRange: GlucoseOutOfRange?
    public init(mgdl: Int, trend: GlucoseTrend?, outOfRange: GlucoseOutOfRange? = nil) {
        self.mgdl = mgdl
        self.trend = trend
        self.outOfRange = outOfRange
    }
}

public enum GlucoseOutOfRange: String, Sendable, Hashable, Codable {
    case low, high
}

/// The CGM state the pump's home screen shows. Only `noError` shows the reading; the others replace it.
public enum PumpCGMState: Sendable, Hashable, Codable {
    case noError
    case warmingUp, calibrate, calibrationError
    case replaceSensor, sensorFailed, replaceTransmitter, restartSensor
    /// The CGM is out of range of the pump.
    case outOfRange
    /// No reading to show (the pump's "---").
    case noReading
    /// The sensor is below or above the range it can measure.
    case low, high
    /// An icon faBolus doesn't know, by its id.
    case unknown(Int)
}

/// What the pump's home screen shows for its CGM besides the number.
public struct PumpCGMDisplay: Sendable, Hashable, Codable {
    public var state: PumpCGMState
    /// The trend icon is a Libre Check BG icon: the reading may not be accurate.
    public var checkBG: Bool
    public init(state: PumpCGMState, checkBG: Bool) {
        self.state = state
        self.checkBG = checkBG
    }
}

/// Why the pump says its own CGM reading shouldn't correct a dose by itself. The dose can still be for
/// carbs only, or correct from a BG the user types.
public enum PumpGlucoseCaution: Sendable, Hashable {
    /// The reading is LOW or HIGH.
    case outOfRange(GlucoseOutOfRange)
    /// The pump shows a sensor state in place of the number.
    case sensorState(PumpCGMState)
    /// A Libre's Check BG icon.
    case checkBG
    /// The pump's calculator doesn't allow its reading to fill in a correction.
    case autoFillOff
    /// The pump's CGM state wasn't read for this dose, so it can't be checked.
    case cgmStateNotRead
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
    /// Delivering at this rate, from the profile or Control-IQ, or from a temp rate the pump's home screen
    /// hasn't shown.
    case active(unitsPerHour: Double)
    /// A temp rate set on the pump: the rate delivered now, and the temp rate's percent of the profile's
    /// rate, or `nil` until it is read.
    case tempRate(unitsPerHour: Double, percent: Int?)
    /// Insulin delivery is suspended.
    case suspended
    /// Basal-IQ has stopped basal for a predicted low. Unlike `suspended`, the pump still delivers a bolus.
    case basalIQSuspended

    public var isSuspended: Bool { self == .suspended }
}

/// The status icons the pump's home screen shows beside the CGM and the bolus. Display only: nothing here
/// is a dose input, and the icons' meanings in each pump state are unverified.
public struct PumpStatusIcons: Sendable, Hashable, Codable {
    /// The bolus icon, when it shows a bolus running.
    public var bolus: Bolus?
    /// The transmitter icon, when it shows one.
    public var transmitter: Transmitter?
    /// The blood-drop icon: the CGM wants a calibration.
    public var calibrationDue: Bool

    public enum Bolus: String, Sendable, Hashable, Codable {
        /// A bolus is running.
        case bolus
        /// A Control-IQ automatic bolus is running.
        case autoBolus
    }

    public enum Transmitter: String, Sendable, Hashable, Codable {
        case inRange, outOfRange
    }

    public init(bolus: Bolus? = nil, transmitter: Transmitter? = nil, calibrationDue: Bool = false) {
        self.bolus = bolus
        self.transmitter = transmitter
        self.calibrationDue = calibrationDue
    }
}

/// When the CGM sensor started and was last calibrated, as the pump reports them, placed in phone time.
/// `nil` for a time the pump reports as unset or that couldn't be placed.
public struct PumpCGMSessionTimes: Sendable, Hashable, Codable {
    public var sensorStarted: Date?
    public var lastCalibration: Date?

    public init(sensorStarted: Date?, lastCalibration: Date?) {
        self.sensorStarted = sensorStarted
        self.lastCalibration = lastCalibration
    }
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
    /// Whether the pump lets its CGM reading fill in a correction, when it said. `false` turns off every
    /// automatic correction from the pump's reading.
    public var glucoseAutoFillAllowed: Bool?
    /// The insulin left in the cartridge, whole units, as the calculator reply reports it.
    public var insulinRemainingUnits: Double?
    /// The insulin bolused in the last hour, units, as the calculator reply reports it.
    public var bolusedLastHourUnits: Double?
    /// The pump's own word that too many boluses were asked for in a short time, when it said.
    public var tooManyBoluses: TooManyBoluses?
    /// Whether the active profile takes carbs (the reply's carb entry, byte 13), when it said. With carbs
    /// off, Tandem's apps take the calculator's food entry as insulin units, not grams, and send no carbs.
    public var carbEntryEnabled: Bool?

    /// Carbs are off on the pump: the calculator's food entry is units, and no carb amount goes.
    public var carbsOff: Bool { carbEntryEnabled == false }

    /// The calculator reply's two too-many-boluses flags. Either set means the pump may stop tracking that
    /// limit if the user goes on.
    public struct TooManyBoluses: Sendable, Hashable, Codable {
        /// The max hourly bolus limit (byte 24).
        public var hourlyLimit: Bool
        /// IOB (byte 25).
        public var insulinOnBoard: Bool
        public init(hourlyLimit: Bool, insulinOnBoard: Bool) {
            self.hourlyLimit = hourlyLimit
            self.insulinOnBoard = insulinOnBoard
        }
        public var isSet: Bool { hourlyLimit || insulinOnBoard }
    }

    /// The pump's own CGM reading the reply carries for its calculator (bytes 1-2), when the reply says it
    /// is valid and its time (byte 26) could be placed. `nil` otherwise, and then the pump's CGM corrects
    /// nothing.
    public var reading: Reading?

    /// A calculator reading: its value, when the pump took it, and whether it is the sensor's LOW or HIGH.
    public struct Reading: Sendable, Hashable, Codable {
        public var mgdl: Int
        public var measuredAt: Date
        public var outOfRange: GlucoseOutOfRange?

        public init(mgdl: Int, measuredAt: Date, outOfRange: GlucoseOutOfRange? = nil) {
            self.mgdl = mgdl
            self.measuredAt = measuredAt
            self.outOfRange = outOfRange
        }
    }

    public init(
        carbRatio: Double, correctionFactor: Int, targetMgdl: Int, maxBolusUnits: Double,
        insulinOnBoardUnits: Double? = nil, glucoseAutoFillAllowed: Bool? = nil, insulinRemainingUnits: Double? = nil,
        bolusedLastHourUnits: Double? = nil, tooManyBoluses: TooManyBoluses? = nil, carbEntryEnabled: Bool? = nil,
        reading: Reading? = nil
    ) {
        self.reading = reading
        self.carbRatio = carbRatio
        self.correctionFactor = correctionFactor
        self.targetMgdl = targetMgdl
        self.maxBolusUnits = maxBolusUnits
        self.insulinOnBoardUnits = insulinOnBoardUnits
        self.glucoseAutoFillAllowed = glucoseAutoFillAllowed
        self.insulinRemainingUnits = insulinRemainingUnits
        self.bolusedLastHourUnits = bolusedLastHourUnits
        self.tooManyBoluses = tooManyBoluses
        self.carbEntryEnabled = carbEntryEnabled
    }

    /// A carb ratio, correction factor or target of zero (or less) is impossible, so such a set isn't a
    /// reading the calculator can use. With carbs off the calculator never divides by the carb ratio, so
    /// it isn't needed then (what the pump reports for it with carbs off isn't known).
    public var isUsable: Bool {
        (carbsOff || (carbRatio.isFinite && carbRatio > 0)) && correctionFactor > 0 && targetMgdl > 0
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
    /// The pump's CGM state from its home screen, read with the glucose.
    public var cgmDisplay: Observed<PumpCGMDisplay>?
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
    /// The pump's home-screen status icons. Display only.
    public var statusIcons: Observed<PumpStatusIcons>?
    /// The time left of insulin action, seconds, from the IOB reply, only when the pump's IOB model is
    /// Mudaliar (Control-IQ off), as t:connect shows it. Display only.
    public var insulinActionTimeLeft: Observed<TimeInterval>?
    /// When the CGM sensor started and was last calibrated. Display only.
    public var cgmSessionTimes: Observed<PumpCGMSessionTimes>?
    /// The cartridge level below which t:connect marks it low, units. Display only.
    public var insulinLowThresholdUnits: Observed<Double>?
    /// The pump's home screen shows a "+" before the cartridge's units. Display only.
    public var insulinPlus: Observed<Bool>?

    public init() {}

    /// The phone's clock was set by `seconds` (back when negative) since these readings were taken: their
    /// stamps move with it, so each reading's age stays the time that really passed since it, and one read
    /// before a dose's refresh still reads as before it.
    public mutating func phoneClockSet(by seconds: TimeInterval) {
        func move<T>(_ reading: inout Observed<T>?) {
            reading?.measuredAt.addTimeInterval(seconds)
            reading?.receivedAt.addTimeInterval(seconds)
        }
        move(&apiVersion)
        move(&glucose)
        move(&cgmDisplay)
        move(&insulinOnBoard)
        move(&reservoirUnits)
        move(&battery)
        move(&basalDeliveryState)
        move(&bolusState)
        move(&lastBolus)
        if let bolus = lastBolus?.value {
            // Its own times were placed by the pump-clock anchor in the clock before the step.
            lastBolus?.value = DoseEntry(
                startDate: bolus.startDate.addingTimeInterval(seconds),
                endDate: bolus.endDate.addingTimeInterval(seconds), programmedUnits: bolus.programmedUnits,
                deliveredUnits: bolus.deliveredUnits, syncIdentifier: bolus.syncIdentifier)
        }
        move(&bolusCalculator)
        // The calculator's reading time was placed by the anchor too, and a correction is aged from it.
        bolusCalculator?.value.reading?.measuredAt.addTimeInterval(seconds)
        move(&maxBasalUnitsPerHour)
        move(&controlIQ)
        move(&cartridge)
        move(&cgmSessionActive)
        move(&alerts)
        move(&cgmHardwareInfo)
        move(&statusIcons)
        move(&insulinActionTimeLeft)
        move(&cgmSessionTimes)
        move(&insulinLowThresholdUnits)
        move(&insulinPlus)
        // Like the last bolus's, these times were placed by the pump-clock anchor in the clock before the step.
        if let times = cgmSessionTimes?.value {
            cgmSessionTimes?.value = PumpCGMSessionTimes(
                sensorStarted: times.sensorStarted?.addingTimeInterval(seconds),
                lastCalibration: times.lastCalibration?.addingTimeInterval(seconds))
        }
    }

    /// Names one observed value, so an event can say which readings changed without the receiver
    /// comparing states.
    public enum Reading: String, Sendable, Hashable, Codable, CaseIterable {
        case apiVersion, glucose, insulinOnBoard, reservoirUnits, battery, basalDeliveryState, bolusState
        case lastBolus, bolusCalculator, maxBasalUnitsPerHour, controlIQ, cartridge, cgmSessionActive, alerts
        case cgmHardwareInfo, cgmDisplay, statusIcons, insulinActionTimeLeft, cgmSessionTimes
        case insulinLowThresholdUnits, insulinPlus
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

    /// The glucose reading while it is current, else `nil`.
    public func glucoseIfFresh(thresholds: FreshnessThresholds, now: Date = Date()) -> PumpGlucose? {
        glucose?.valueIfFresh(within: thresholds.glucoseStaleAfter, now: now)
    }

    /// The reading a correction is computed from. The pump's own is the one its calculator reply carries,
    /// aged from that reply's reading time, as t:connect's calculator takes it, not the latest CGM reading;
    /// with none there, the pump's CGM corrects nothing. A reading from another glucose source stays that
    /// source's.
    public var correctionReading: Observed<PumpGlucose>? {
        if let glucose, glucose.source != .pump { return glucose }
        guard let calculator = bolusCalculator, let reading = calculator.value.reading else { return nil }
        return Observed(
            PumpGlucose(mgdl: reading.mgdl, trend: glucose?.value.trend, outOfRange: reading.outOfRange),
            measuredAt: reading.measuredAt, receivedAt: calculator.receivedAt, source: calculator.source)
    }

    /// The correction reading when it may correct a dose by itself: fresh, and with no caution from the pump.
    /// The only form that may fill a correction.
    public func glucoseForCorrection(
        thresholds: FreshnessThresholds, now: Date = Date(), cgmStateReadSince: Date? = nil
    ) -> PumpGlucose? {
        guard glucoseCaution(cgmStateReadSince: cgmStateReadSince) == nil else { return nil }
        return correctionReading?.valueIfFresh(within: thresholds.glucoseStaleAfter, now: now)
    }

    /// The pump's own reason its reading shouldn't correct a dose by itself, or `nil`. A reading from
    /// another glucose source is that source's to judge. `cgmStateReadSince`: the CGM state must have been
    /// received since then (the start of a dose attempt), else it can't be checked.
    public func glucoseCaution(cgmStateReadSince: Date? = nil) -> PumpGlucoseCaution? {
        guard let reading = correctionReading ?? glucose, reading.source == .pump else { return nil }
        if let range = reading.value.outOfRange { return .outOfRange(range) }
        guard let display = cgmDisplay, display.receivedAt >= (cgmStateReadSince ?? .distantPast) else {
            return .cgmStateNotRead
        }
        if display.value.state != .noError { return .sensorState(display.value.state) }
        if display.value.checkBG { return .checkBG }
        // The flag comes with the calculator settings: a dose from settings not read for the attempt has
        // already asked the user to accept the last-known ones, this flag with them.
        if bolusCalculator?.value.glucoseAutoFillAllowed == false { return .autoFillOff }
        return nil
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
