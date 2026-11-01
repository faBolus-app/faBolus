import Foundation
import TandemMessages
import faBolusCore

/// Ties the pump's wall clock to the phone's. The pump stamps glucose, boluses and history in its own
/// local seconds since 2008 (TimeSinceReset's `currentTime`), and its clock is set by hand: it may be in
/// another time zone, or an hour off after a DST change nobody made on the pump. So a pump time is placed
/// by the measured offset between the two clocks, never by reading it as the phone's local time.
public struct PumpClockAnchor: Sendable, Equatable {
    /// The pump's clock when it answered.
    public let pumpTime: UInt32
    /// When the answer arrived, by the phone's clock.
    public let phoneTime: Date

    public init(pumpTime: UInt32, phoneTime: Date) {
        self.pumpTime = pumpTime
        self.phoneTime = phoneTime
    }

    /// The phone time a pump timestamp names.
    public func date(forPumpTime t: UInt32) -> Date {
        phoneTime.addingTimeInterval(TimeInterval(Int64(t) - Int64(pumpTime)))
    }

    /// The pump's clock at a phone time.
    public func pumpTime(at date: Date) -> UInt32 {
        let t = Double(pumpTime) + date.timeIntervalSince(phoneTime)
        return UInt32(clamping: Int64(t.rounded(.down)))
    }
}

/// The pump's open notifications, kept by kind: each status read replaces only its own kind.
struct PumpAlertLists: Sendable, Equatable {
    var byKind: [PumpAlertKind: [PumpAlert]] = [:]
    var malfunctions: [PumpAlert] = []

    var merged: [PumpAlert] {
        PumpAlertKind.allCases.flatMap { byKind[$0] ?? [] } + malfunctions
    }

    static func alert(_ n: PumpNotification) -> PumpAlert {
        PumpAlert(
            id: n.id, kind: PumpAlertKind(rawValue: n.kind.rawValue) ?? .alert, title: n.title,
            detail: n.detail ?? "", isDismissable: n.dismissable)
    }

    /// The pump names a malfunction only by its bit in the malfunction status (pumpx2 decodes no other
    /// code), so that bit is the malfunction's code.
    static func malfunction(_ n: PumpNotification) -> PumpAlert {
        PumpAlert(
            id: n.id, kind: .alarm, title: n.title, detail: n.detail ?? "", isDismissable: false,
            malfunctionCode: n.id)
    }
}

/// How each reply the session reads changes `PumpState`. Every value keeps the pump's own measurement
/// time where the pump gives one, and the reply's arrival time where it doesn't. Nothing is modeled: a
/// value the pump didn't report stays as it was, and a reply that can't be trusted changes nothing.
enum PumpReadings {
    struct Context {
        let receivedAt: Date
        let anchor: PumpClockAnchor?
    }

    /// Applies `message` to `state` (and `alerts`), returning the readings that changed.
    static func apply(
        _ message: any TandemMessages.Message, to state: inout PumpState, alerts: inout PumpAlertLists,
        context: Context
    ) -> Set<PumpState.Reading> {
        let at = context.receivedAt
        func observed<T: Sendable>(_ value: T, measuredAt: Date? = nil) -> Observed<T> {
            Observed(value, measuredAt: measuredAt ?? at, receivedAt: at)
        }
        switch message {
        case let m as ControlIQIOBResponse:
            state.insulinOnBoard = observed(Double(displayedIOB(m)) / 1000)
            return [.insulinOnBoard]

        case let m as BolusCalcDataSnapshotResponse:
            let settings = BolusCalculatorSettings(
                carbRatio: m.carbRatioGramsPerUnit, correctionFactor: m.isf, targetMgdl: m.targetBg,
                maxBolusUnits: Double(m.maxBolusAmount) / 1000, insulinOnBoardUnits: Double(m.iob) / 1000)
            state.bolusCalculator = observed(settings)
            return [.bolusCalculator]

        case let m as InsulinStatusResponse:
            state.reservoirUnits = observed(Double(m.currentInsulinAmount))
            return [.reservoirUnits]

        case let m as CurrentBatteryV2Response:
            // pumpx2 names only status 1 as charging; any other value is not.
            state.battery = observed(PumpBattery(percent: m.batteryPercent, isCharging: m.chargingStatus == 1))
            return [.battery]

        case let m as CurrentBatteryV1Response:
            state.battery = observed(PumpBattery(percent: m.batteryPercent, isCharging: nil))
            return [.battery]

        case let m as CurrentEGVGuiDataResponse:
            // Only a valid reading with a time the anchor can place. Without an anchor the reading's age
            // is unknown, and an unknown age must never look current.
            guard isValidReading(status: m.egvStatusId, mgdl: m.cgmReading), let anchor = context.anchor else {
                return []
            }
            let measured = anchor.date(forPumpTime: UInt32(truncatingIfNeeded: m.bgReadingTimestampSeconds))
            let trend = state.glucose?.value.trend
            state.glucose = observed(PumpGlucose(mgdl: m.cgmReading, trend: trend), measuredAt: measured)
            return [.glucose]

        case let m as HomeScreenMirrorResponse:
            // The pump's own trend icon is the trend. "No arrow" is a real answer: no trend, not flat.
            guard var glucose = state.glucose else { return [] }
            glucose.value.trend = GlucoseTrend(rawValue: m.cgmTrendArrow)
            state.glucose = glucose
            return [.glucose]

        case let m as CurrentBasalStatusResponse:
            state.basalDeliveryState = observed(.active(unitsPerHour: m.currentBasalUnitsPerHour))
            return [.basalDeliveryState]

        case let m as BasalLimitSettingsResponse:
            state.maxBasalUnitsPerHour = observed(m.basalLimitUnitsPerHour)
            return [.maxBasalUnitsPerHour]

        case let m as ControlIQInfoV2Response:
            state.controlIQ = observed(
                ControlIQStatus(
                    isEnabled: m.closedLoopEnabled, activity: ControlIQActivity(rawMode: m.currentUserModeType)))
            return [.controlIQ]

        case let m as LoadStatusResponse:
            state.cartridge = observed(CartridgeLoadState(rawValue: m.loadStateId))
            return [.cartridge]

        case let m as CGMStatusResponse:
            state.cgmSessionActive = observed(m.sessionActive)
            return [.cgmSessionActive]

        case let m as CGMHardwareInfoResponse:
            let info = m.hardwareInfoString.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            guard !info.isEmpty else { return [] }
            state.cgmHardwareInfo = observed(info)
            return [.cgmHardwareInfo]

        case let m as CurrentBolusStatusResponse:
            if m.isActive {
                let entry = DoseEntry(
                    startDate: at, programmedUnits: Double(m.requestedVolume) / 1000, syncIdentifier: "\(m.bolusId)")
                state.bolusState = observed(.inProgress(entry))
            } else {
                state.bolusState = observed(.noBolus)
            }
            return [.bolusState]

        case let m as LastBolusStatusV2Response:
            guard m.bolusId > 0, let anchor = context.anchor else { return [] }
            let entry = DoseEntry(
                startDate: anchor.date(forPumpTime: m.timestamp), programmedUnits: Double(m.requestedVolume) / 1000,
                deliveredUnits: m.deliveredUnits, syncIdentifier: "\(m.bolusId)")
            state.lastBolus = observed(entry, measuredAt: entry.startDate)
            return [.lastBolus]

        case let m as ApiVersionResponse:
            state.apiVersion = observed(PumpAPIVersion(major: m.majorVersion, minor: m.minorVersion))
            return [.apiVersion]

        case let m as AlertStatusResponse:
            return setAlerts(.alert, m.notifications, state: &state, alerts: &alerts, at: at)
        case let m as AlarmStatusResponse:
            return setAlerts(.alarm, m.notifications, state: &state, alerts: &alerts, at: at)
        case let m as CGMAlertStatusResponse:
            return setAlerts(.cgmAlert, m.notifications, state: &state, alerts: &alerts, at: at)
        case let m as ReminderStatusResponse:
            return setAlerts(.reminder, m.notifications, state: &state, alerts: &alerts, at: at)
        case let m as MalfunctionBitmaskStatusResponse:
            let before = alerts.merged
            alerts.malfunctions = m.notifications.map(PumpAlertLists.malfunction)
            state.alerts = observed(alerts.merged)
            return before == alerts.merged ? [] : [.alerts]

        default:
            return []
        }
    }

    /// The IOB the pump displays, by the model it reports (pumpx2's `getPumpDisplayedIOB`): Mudaliar for
    /// type 0, Swan 6-hour for type 1, and the larger of the two for a type it doesn't know, so an
    /// unknown model never subtracts less insulin than either implies.
    static func displayedIOB(_ m: ControlIQIOBResponse) -> UInt32 {
        switch m.iobType {
        case 0: return m.mudaliarIOB
        case 1: return m.swan6hrIOB
        default: return max(m.mudaliarIOB, m.swan6hrIOB)
        }
    }

    /// EGV status per pumpx2: 1 valid, 2 low, 3 high; 0 invalid and 4 unavailable carry no reading.
    static func isValidReading(status: Int, mgdl: Int) -> Bool {
        (1...3).contains(status) && mgdl > 0 && mgdl < 600
    }

    private static func setAlerts(
        _ kind: PumpAlertKind, _ notifications: [PumpNotification], state: inout PumpState,
        alerts: inout PumpAlertLists, at: Date
    ) -> Set<PumpState.Reading> {
        let before = alerts.merged
        alerts.byKind[kind] = notifications.map(PumpAlertLists.alert)
        state.alerts = Observed(alerts.merged, measuredAt: at, receivedAt: at)
        return before == alerts.merged ? [] : [.alerts]
    }
}
