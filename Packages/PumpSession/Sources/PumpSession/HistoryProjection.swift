import Foundation
import TandemMessages
import faBolusCore

/// What a batch of pump history records means to the app: chart glucose, boluses and carbs for the
/// history store, and the logbook's events. Every time is placed by the pump-clock anchor; a record
/// dated in the future beyond clock skew is dropped, never moved to now.
public struct PumpHistoryBatch: Sendable {
    public var glucose: [GlucoseReading] = []
    public var boluses: [BolusMarker] = []
    public var carbs: [CarbEntry] = []
    /// Basal rate changes, suspends and resumes, for the chart's basal line.
    public var deliveryChanges: [DeliveryChange] = []
    /// Newest first.
    public var events: [HistoryEvent] = []
    /// The sequence numbers the batch holds: every record but those dropped for a time in the future.
    public var sequences: Set<UInt32> = []

    public struct CarbEntry: Sendable, Equatable {
        public let date: Date
        public let grams: Double
    }

    public var isEmpty: Bool {
        glucose.isEmpty && boluses.isEmpty && carbs.isEmpty && deliveryChanges.isEmpty && events.isEmpty
    }
}

/// The history store, or anything else that keeps pump history. A failed write throws, so the session
/// doesn't credit records it couldn't keep and fetches them again on the next sync.
public protocol PumpHistorySink: Sendable {
    func record(_ batch: PumpHistoryBatch) async throws
    /// The logbook's events recorded so far, newest first, so a relaunch shows them without fetching the
    /// pump's history again (the session doesn't re-read what it already holds).
    func loadEvents(limit: Int) async -> [HistoryEvent]
    /// Forget the logbook's events and the chart's basal changes, when the pump they came from is forgotten
    /// or its log restarts.
    func clearEvents() async
}

extension PumpHistorySink {
    public func loadEvents(limit: Int) async -> [HistoryEvent] { [] }
    public func clearEvents() async {}
}

/// The completed bolus a history record shows, for settling a bolus.
struct HistoryBolus: Sendable, Equatable {
    let bolusId: Int
    let pumpTime: UInt32
    let deliveredUnits: Double
    let requestedUnits: Double
}

enum HistoryProjection {
    /// Decodes raw 26-byte records.
    static func events(_ records: [[UInt8]]) -> [any HistoryLogEvent] {
        records.map { HistoryLogParser.parse(record: $0) }
    }

    static func batch(_ records: [[UInt8]], anchor: PumpClockAnchor, now: Date) -> PumpHistoryBatch {
        var batch = PumpHistoryBatch()
        func date(_ pumpTime: UInt32) -> Date? {
            let d = anchor.date(forPumpTime: pumpTime)
            return d <= now.addingTimeInterval(GlucoseFreshness.futureSkewTolerance) ? d : nil
        }
        let frame = HistoryLogStreamResponse(
            cargo: [UInt8(min(records.count, 255)), 0] + records.prefix(255).flatMap { $0 })
        for r in frame.cgmReadings {
            if let d = date(r.pumpTimeSec) { batch.glucose.append(GlucoseReading(date: d, mgdl: r.glucoseMgdl)) }
        }
        for e in events(records) {
            // A record dropped for its date isn't kept, so it isn't counted as held either.
            guard let d = date(e.pumpTimeSec) else { continue }
            batch.sequences.insert(e.sequenceNum)
            switch e {
            case let m as BolusCompletedHistoryLog where m.insulinDelivered > 0:
                batch.boluses.append(BolusMarker(date: d, units: Double(m.insulinDelivered)))
            case let m as BolexCompletedHistoryLog where m.insulinDelivered > 0:
                batch.boluses.append(BolusMarker(date: d, units: Double(m.insulinDelivered)))
            case let m as CarbEnteredHistoryLog where m.carbs > 0:
                batch.carbs.append(.init(date: d, grams: Double(m.carbs)))
            case let m as BasalRateChangeHistoryLog:
                batch.deliveryChanges.append(
                    DeliveryChange(date: d, kind: .basalRate, unitsPerHour: Double(m.commandBasalRate)))
            case is PumpingSuspendedHistoryLog:
                batch.deliveryChanges.append(DeliveryChange(date: d, kind: .suspended))
            case is PumpingResumedHistoryLog:
                batch.deliveryChanges.append(DeliveryChange(date: d, kind: .resumed))
            default:
                break
            }
            if let event = event(e, date: d) { batch.events.append(event) }
        }
        batch.events.sort { $0.date > $1.date }
        return batch
    }

    /// Completed boluses among `records`.
    static func completedBoluses(_ records: [[UInt8]]) -> [HistoryBolus] {
        events(records).compactMap {
            switch $0 {
            case let m as BolusCompletedHistoryLog:
                return HistoryBolus(
                    bolusId: m.bolusId, pumpTime: m.pumpTimeSec, deliveredUnits: Double(m.insulinDelivered),
                    requestedUnits: Double(m.insulinRequested))
            case let m as BolexCompletedHistoryLog:
                return HistoryBolus(
                    bolusId: m.bolusId, pumpTime: m.pumpTimeSec, deliveredUnits: Double(m.insulinDelivered),
                    requestedUnits: Double(m.insulinRequested))
            default:
                return nil
            }
        }
    }

    /// The bolus ID a record names when the record shows the pump started the bolus: the initiate records
    /// newer firmware writes, and requested, activated, delivering and completed. Such a record means the
    /// bolus isn't absent from history, even before it completes.
    ///
    /// The permission records (types 338 and 297) are left out on purpose: the pump writes one when it
    /// grants permission (the capture of bolus 3 has one naming it), and a granted permission that no
    /// InitiateBolus followed is exactly the bolus that never started.
    static func bolusId(of e: any HistoryLogEvent) -> Int? {
        switch e {
        case let m as BolusCompletedHistoryLog: return m.bolusId
        case let m as BolusDeliveryHistoryLog: return m.bolusID
        case let m as BolusActivatedHistoryLog: return m.bolusId
        case let m as BolusRequestedMsg1HistoryLog: return m.bolusId
        case let m as BolusRequestedMsg2HistoryLog: return m.bolusId
        case let m as BolusRequestedMsg3HistoryLog: return m.bolusId
        case let m as BolexActivatedHistoryLog: return m.bolusId
        case let m as BolexCompletedHistoryLog: return m.bolusId
        case let m as InitiateBolusRequestMsg1HistoryLog: return m.bolusId
        case let m as InitiateBolusRequestMsg2HistoryLog: return m.bolusId
        case let m as InitiateBolusRequestMsg3HistoryLog: return m.bolusId
        case let m as InitiateBolusResponseHistoryLog: return m.bolusId
        default: return nil
        }
    }

    /// The pump's clock was changed: records on either side of it aren't on one timeline.
    static func isClockChange(_ e: any HistoryLogEvent) -> Bool {
        e is TimeChangedHistoryLog || e is DateChangeHistoryLog
    }

    /// The completion statuses t:connect counts as a bolus cut short: stopped on the pump (0), by an
    /// alarm (1) or a malfunction (2), from the phone (4), or for a predicted low (6). Delivered (3), a
    /// request the pump refused (5) and a value it doesn't know count as delivered.
    static let abortedCompletionStatuses: Set<Int> = [0, 1, 2, 4, 6]

    /// A stopped bolus's entry, named by why it stopped, from the completion status's names in Tandem's
    /// apps (guess #19).
    static func stoppedTitle(_ status: BolusCompletedHistoryLog.CompletionStatus?) -> String {
        switch status {
        case .userAborted: return "Bolus stopped on the pump"
        case .terminatedByAlarm: return "Bolus stopped by an alarm"
        case .terminatedByMalfunction: return "Bolus stopped by a malfunction"
        case .abortedViaWirelessLink: return "Bolus cancelled from a phone"
        case .abortedForPredictedLow: return "Bolus stopped for a predicted low"
        case .completed, .rejectedViaWirelessLink, nil: return "Bolus stopped"
        }
    }

    /// The logbook's entry for a record, or `nil` for records it doesn't show (CGM samples, which the
    /// chart shows, and types with nothing to say).
    static func event(_ e: any HistoryLogEvent, date: Date) -> HistoryEvent? {
        func u(_ f: Float) -> String { String(format: "%.2f U", f) }
        let seq = e.sequenceNum
        func named(_ name: (title: String, detail: String?)?, _ fallback: String, _ id: Int) -> (String, String) {
            name.map { ($0.title, $0.detail ?? "") } ?? (fallback, "id \(id)")
        }
        // An alert TandemKit doesn't name gets the same copy the live alert shows (`PumpReadings.alert`).
        func alertNamed(_ id: Int) -> (String, String) {
            if let name = AlertStatusResponse.name(for: id) { return (name.title, name.detail ?? "") }
            let copy = PumpAlertCopyOverlay.resolve(kind: .alert, id: id, decodedTitle: "Alert", decodedDetail: nil)
            return copy.detail.isEmpty ? ("Alert", "id \(id)") : copy
        }
        // A bolus that went in short is "stopped", with what it asked for, as t:connect shows it: a
        // standard bolus when its status says it was cut short, an extended one whenever it went in short.
        // Short by the outcome's own rule, so the logbook and the bolus's outcome agree.
        func short(_ delivered: Float, of requested: Float) -> Bool {
            if case .stopped = BolusOutcome.settled(
                deliveredUnits: Double(delivered), requestedUnits: Double(requested))
            {
                return true
            }
            return false
        }
        func stopped(_ delivered: Float, of requested: Float) -> String {
            "\(formatUnits(Double(delivered))) of \(formatUnits(Double(requested)))"
        }
        switch e {
        case let m as BolusCompletedHistoryLog
        where Self.abortedCompletionStatuses.contains(m.completionStatusId)
            && short(m.insulinDelivered, of: m.insulinRequested):
            return HistoryEvent(
                id: seq, date: date, category: .bolus, title: Self.stoppedTitle(m.completionStatus),
                detail: stopped(m.insulinDelivered, of: m.insulinRequested))
        case let m as BolusCompletedHistoryLog:
            return HistoryEvent(
                id: seq, date: date, category: .bolus, title: "Bolus delivered", detail: u(m.insulinDelivered))
        case let m as BolusDeliveryHistoryLog where m.bolusSource == 7:
            return HistoryEvent(id: seq, date: date, category: .autoCorrection, title: "Control-IQ auto-corrected")
        case let m as BolexCompletedHistoryLog where short(m.insulinDelivered, of: m.insulinRequested):
            return HistoryEvent(
                id: seq, date: date, category: .bolus, title: "Extended bolus stopped",
                detail: stopped(m.insulinDelivered, of: m.insulinRequested))
        case let m as BolexCompletedHistoryLog:
            return HistoryEvent(
                id: seq, date: date, category: .bolus, title: "Extended bolus", detail: u(m.insulinDelivered))
        case let m as CarbEnteredHistoryLog:
            return HistoryEvent(
                id: seq, date: date, category: .carbs, title: "Carbs entered", detail: String(format: "%.0f g", m.carbs)
            )
        case let m as BGHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .bg, title: "BG entered", detail: "\(m.bg) mg/dL")
        case let m as BasalRateChangeHistoryLog:
            return HistoryEvent(
                id: seq, date: date, category: .basal, title: "Basal rate change", detail: u(m.commandBasalRate) + "/hr"
            )
        case let m as TempRateActivatedHistoryLog:
            return HistoryEvent(
                id: seq, date: date, category: .tempRate, title: "Temp rate started",
                detail: String(format: "%.0f%%", m.percent))
        case is TempRateCompletedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .tempRate, title: "Temp rate ended")
        case is AaAutoBolusRejectedHistoryLog:
            // pumpx2's "AA Auto Bolus Rejected": the record carries no reason, so none is given.
            return HistoryEvent(
                id: seq, date: date, category: .couldNotDeliver, title: "Control-IQ auto-bolus rejected")
        case let m as CorrectionDeclinedHistoryLog:
            // The bolus calculator's correction, declined for a bolus: not Control-IQ.
            return HistoryEvent(
                id: seq, date: date, category: .bolus, title: "Correction declined",
                detail: m.bg > 0 ? "BG \(m.bg) mg/dL" : "")
        case let m as PumpingSuspendedHistoryLog:
            return HistoryEvent(
                id: seq, date: date, category: .pumping, title: "Insulin suspended",
                detail: m.reasonId == 0 ? "" : "reason \(m.reasonId)")
        case is PumpingResumedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .pumping, title: "Insulin resumed")
        case let m as CartridgeFilledHistoryLog:
            return HistoryEvent(
                id: seq, date: date, category: .cartridge, title: "Cartridge filled", detail: u(m.insulinActual))
        case is CannulaFilledHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .cartridge, title: "Cannula filled")
        case is TubingFilledHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .cartridge, title: "Tubing filled")
        case is CartridgeInsertedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .cartridge, title: "Cartridge inserted")
        case is CartridgeRemovedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .cartridge, title: "Cartridge removed")
        case let m as AlarmActivatedHistoryLog:
            let n = named(AlarmStatusResponse.name(for: m.alarmId), "Alarm", m.alarmId)
            return HistoryEvent(id: seq, date: date, category: .alarm, title: n.0, detail: n.1)
        case let m as AlarmClearedHistoryLog:
            let n = named(AlarmStatusResponse.name(for: m.alarmId), "Alarm", m.alarmId)
            return HistoryEvent(id: seq, date: date, category: .alarm, title: n.0 + " cleared")
        case let m as AlarmAckHistoryLog:
            let n = named(AlarmStatusResponse.name(for: m.alarmId), "Alarm", m.alarmId)
            return HistoryEvent(id: seq, date: date, category: .alarm, title: n.0 + " acknowledged")
        case let m as AlertActivatedHistoryLog:
            let n = alertNamed(m.alertId)
            return HistoryEvent(id: seq, date: date, category: .alert, title: n.0, detail: n.1)
        case let m as AlertClearedHistoryLog:
            let n = alertNamed(m.alertId)
            return HistoryEvent(id: seq, date: date, category: .alert, title: n.0 + " cleared")
        case let m as AlertAckHistoryLog:
            let n = alertNamed(m.alertId)
            return HistoryEvent(id: seq, date: date, category: .alert, title: n.0 + " acknowledged")
        case let m as CgmAlertActivatedHistoryLog:
            let n = named(CGMAlertStatusResponse.name(for: m.alertId), "CGM alert", m.alertId)
            return HistoryEvent(id: seq, date: date, category: .alert, title: n.0, detail: n.1)
        case let m as ReminderActivatedHistoryLog:
            return HistoryEvent(
                id: seq, date: date, category: .reminder, title: "Reminder", detail: "id \(m.reminderId)")
        default:
            return nil
        }
    }
}
