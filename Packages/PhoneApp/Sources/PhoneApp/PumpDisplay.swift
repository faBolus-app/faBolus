import Foundation
import faBolusCore

/// What the phone's screens show for each pump value at one moment: its text, whether it's known, and
/// whether it's stale. Every screen reads these, so the dashboard ring, the pills and the Details card can't
/// disagree about a value or its age. A value past its window shows as unknown ("—"), never as current; the
/// window is the one the phone uses for that value (glucose, IOB, therapy settings or pump status).
public struct PumpDisplay: Sendable {
    public static let unknown = "—"

    public struct Value: Sendable, Equatable {
        public var text: String
        public var isKnown: Bool
        /// Read once, but older than its window.
        public var isStale: Bool
        public static let unknown = Value(text: PumpDisplay.unknown, isKnown: false, isStale: false)
    }

    public enum Glucose: Sendable, Equatable {
        /// No reading at all.
        case none
        case current(mgdl: Int, trend: GlucoseTrend?, measuredAt: Date)
        /// Shown marked, with its age.
        case stale(mgdl: Int, trend: GlucoseTrend?, measuredAt: Date)
        /// Past the hide window: shown as "—".
        case hidden(measuredAt: Date)
    }

    public let pump: PumpState
    public let freshness: FreshnessThresholds
    public let unit: GlucoseUnit
    public let showUnitLabels: Bool
    public let lastAutoCorrection: Date?
    public let now: Date

    public init(
        pump: PumpState, freshness: FreshnessThresholds, unit: GlucoseUnit, showUnitLabels: Bool,
        lastAutoCorrection: Date?, now: Date
    ) {
        self.pump = pump
        self.freshness = freshness
        self.unit = unit
        self.showUnitLabels = showUnitLabels
        self.lastAutoCorrection = lastAutoCorrection
        self.now = now
    }

    // MARK: Glucose

    public var glucose: Glucose {
        guard let g = pump.glucose else { return .none }
        guard g.isStale(after: freshness.glucoseStaleAfter, now: now) else {
            return .current(mgdl: g.value.mgdl, trend: g.value.trend, measuredAt: g.measuredAt)
        }
        if let hide = freshness.glucoseHideAfter, let age = g.age(now: now),
            age >= max(hide, freshness.glucoseStaleAfter)
        {
            return .hidden(measuredAt: g.measuredAt)
        }
        return .stale(mgdl: g.value.mgdl, trend: g.value.trend, measuredAt: g.measuredAt)
    }

    public var unitLabel: String { "mg/dL" }

    /// "3 min ago", "just now".
    public func age(_ date: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours) h ago" : "\(hours / 24) d ago"
    }

    // MARK: Pump values

    private func value<V>(_ o: Observed<V>?, window: TimeInterval, _ format: (V) -> String) -> Value {
        guard let o else { return .unknown }
        guard let v = o.valueIfFresh(within: window, now: now) else {
            return Value(text: Self.unknown, isKnown: false, isStale: true)
        }
        return Value(text: format(v), isKnown: true, isStale: false)
    }

    public var insulinOnBoard: Value {
        value(pump.insulinOnBoard, window: freshness.insulinOnBoardStaleAfter) { formatUnits($0) }
    }

    /// The cartridge's units, with the "+" the pump's home screen shows before them.
    public var reservoir: Value {
        let plus = pump.insulinPlus?.valueIfFresh(within: freshness.pumpStatusStaleAfter, now: now) == true
        return value(pump.reservoirUnits, window: freshness.pumpStatusStaleAfter) {
            (plus ? "+" : "") + String(format: "%.0f U", $0)
        }
    }

    /// The cartridge is below the pump's low-insulin level, as t:connect marks it.
    public var reservoirIsLow: Bool {
        guard let units = pump.reservoirUnits?.valueIfFresh(within: freshness.pumpStatusStaleAfter, now: now),
            let low = pump.insulinLowThresholdUnits?.valueIfFresh(within: freshness.pumpStatusStaleAfter, now: now)
        else { return false }
        return units < low
    }

    public var battery: PumpBattery? { pump.battery?.valueIfFresh(within: freshness.pumpStatusStaleAfter, now: now) }
    public var batteryIsStale: Bool { pump.battery != nil && battery == nil }

    public var basal: Value {
        value(pump.basalDeliveryState, window: freshness.pumpStatusStaleAfter) {
            switch $0 {
            case .suspended, .basalIQSuspended: return "Suspended"
            case .active(let rate), .tempRate(let rate, _): return String(format: "%.2f U/hr", rate)
            }
        }
    }

    public var isSuspended: Bool {
        pump.basalDeliveryState?.valueIfFresh(within: freshness.pumpStatusStaleAfter, now: now) == .suspended
    }

    /// Basal-IQ has stopped basal for a predicted low; boluses still go.
    public var isBasalIQSuspended: Bool {
        pump.basalDeliveryState?.valueIfFresh(within: freshness.pumpStatusStaleAfter, now: now) == .basalIQSuspended
    }

    /// A temp rate set on the pump, named for the basal's label with its percent once read ("Temp rate
    /// 150%"), or nil when the pump shows none.
    public var tempRate: String? {
        guard
            case .tempRate(_, let percent) = pump.basalDeliveryState?.valueIfFresh(
                within: freshness.pumpStatusStaleAfter, now: now)
        else { return nil }
        return percent.map { "Temp rate \($0)%" } ?? "Temp rate"
    }

    public var controlIQ: ControlIQStatus? {
        pump.controlIQ?.valueIfFresh(within: freshness.pumpStatusStaleAfter, now: now)
    }

    public var controlIQText: Value {
        value(pump.controlIQ, window: freshness.pumpStatusStaleAfter) {
            guard $0.isEnabled else { return "Off" }
            switch $0.activity {
            case .normal: return "On"
            case .sleep: return "Sleep"
            case .exercise: return "Exercise"
            }
        }
    }

    /// On the pump-status window, like the pump's other status values.
    public var cgmSessionActive: Bool? {
        pump.cgmSessionActive?.valueIfFresh(within: freshness.pumpStatusStaleAfter, now: now)
    }

    /// The time left of insulin action ("1 h 30 m left"), when the pump reports it (the Mudaliar IOB model
    /// only) and the IOB beside it is current; aged from the reading, and nil once it has run out.
    public var insulinActionLeft: String? {
        guard let left = pump.insulinActionTimeLeft, insulinOnBoard.isKnown, !insulinOnBoard.isStale,
            let value = left.valueIfFresh(within: freshness.insulinOnBoardStaleAfter, now: now),
            let age = left.age(now: now)
        else { return nil }
        let minutes = Int((value - age) / 60)
        guard minutes > 0 else { return nil }
        return minutes < 60 ? "\(minutes) m left" : "\(minutes / 60) h \(minutes % 60) m left"
    }

    private var statusIcons: PumpStatusIcons? {
        pump.statusIcons?.valueIfFresh(within: freshness.pumpStatusStaleAfter, now: now)
    }

    /// The pump's home screen shows a bolus or an automatic bolus running.
    public var bolusMark: String? {
        switch statusIcons?.bolus {
        case .bolus: return "Bolus running"
        case .autoBolus: return "Auto-bolus running"
        case nil: return nil
        }
    }

    /// The pump's home screen shows the transmitter out of range or a calibration due.
    public var cgmMark: String? {
        guard let icons = statusIcons else { return nil }
        if icons.transmitter == .outOfRange { return "Transmitter out of range" }
        return icons.calibrationDue ? "Calibrate" : nil
    }

    /// The CGM session's times, while the pump says a session is running, as t:connect shows them.
    private var cgmSessionTimes: PumpCGMSessionTimes? {
        guard cgmSessionActive == true else { return nil }
        return pump.cgmSessionTimes?.valueIfFresh(within: freshness.pumpStatusStaleAfter, now: now)
    }

    /// When the sensor started ("3 d ago"), or nil to leave the row out.
    public var sensorStarted: String? { cgmSessionTimes?.sensorStarted.map { age($0) } }

    /// When the CGM was last calibrated ("5 h ago"), or nil to leave the row out.
    public var lastCalibration: String? { cgmSessionTimes?.lastCalibration.map { age($0) } }

    public var lastBolus: Value {
        guard let b = pump.lastBolus else { return .unknown }
        let units = b.value.deliveredUnits ?? b.value.programmedUnits
        return Value(text: "\(formatUnits(units)) · \(age(b.value.startDate))", isKnown: true, isStale: false)
    }

    private var calculator: Observed<BolusCalculatorSettings>? { pump.bolusCalculator }

    public var carbRatio: Value {
        // With carbs off the pump's ratio isn't used, and what it reports then isn't known.
        value(calculator, window: freshness.therapyStaleAfter) {
            $0.carbsOff ? "Carbs off" : String(format: "%.0f g/U", $0.carbRatio)
        }
    }

    public var correctionFactor: Value {
        value(calculator, window: freshness.therapyStaleAfter) {
            let v = unit.format(mgdl: $0.correctionFactor)
            return showUnitLabels ? "\(v) mg/dL/U" : v
        }
    }

    public var target: Value {
        value(calculator, window: freshness.therapyStaleAfter) {
            let v = unit.format(mgdl: $0.targetMgdl)
            return showUnitLabels ? "\(v) mg/dL" : v
        }
    }

    /// The pump's max bolus; a setting, so it's shown while known at all.
    public var maxBolus: Value {
        guard let c = calculator else { return .unknown }
        return Value(text: String(format: "%.1f U", c.value.maxBolusUnits), isKnown: true, isStale: false)
    }

    /// `nil` while none is known, so the row is hidden.
    public var autoCorrection: String? { lastAutoCorrection.map { age($0) } }

    /// A Details row's value, or `nil` to leave the row out.
    public func detail(_ field: DetailsField) -> String? {
        switch field {
        case .iob: return insulinOnBoard.text + (insulinActionLeft.map { " · \($0)" } ?? "")
        case .reservoir: return reservoir.text
        case .battery:
            guard let battery else { return Self.unknown }
            return "\(battery.percent)%" + (battery.isCharging == true ? " · charging" : "")
        case .cgm: return cgmSessionActive.map { $0 ? "Active" : "Inactive" } ?? Self.unknown
        case .lastBolus: return lastBolus.isKnown ? lastBolus.text : nil
        case .carbRatio: return carbRatio.text
        case .isf: return correctionFactor.text
        case .target: return target.text
        case .maxBolus: return maxBolus.text
        case .autoCorrection: return autoCorrection
        case .sensorStarted: return sensorStarted
        case .lastCalibration: return lastCalibration
        }
    }
}
