import Foundation

/// Something about the pump the user confirms before a dose goes, as Tandem's apps ask it: the pump
/// flagging too many boluses, the max hourly bolus, and a cartridge that may run out; and, faBolus's own,
/// those limits going unchecked when the pump's count couldn't be read. Each is asked on the
/// phone and on a remote, and a dose goes once the user says to go on; none changes the dose.
public enum DoseConfirmation: Sendable, Equatable {
    /// The pump says too many boluses were asked for in a short time, so it may not track its hourly limit,
    /// IOB, or both, if the user goes on.
    case tooManyBoluses(BolusCalculatorSettings.TooManyBoluses)
    /// This dose and the last hour's boluses come to more than the max hourly bolus.
    case maxHourlyBolus(doseUnits: Double, lastHourUnits: Double, limitUnits: Double)
    /// The calculator snapshot is older than the IOB window, or than the last bolus, even after the dose's own
    /// read of it (the read went unanswered), so what the last hour's boluses come to, and whether the pump
    /// flags too many, aren't known: neither the max hourly bolus nor too many boluses can be checked. Its own kind, never the max
    /// hourly bolus's: a remote's answer names only the kind, so the two must never answer each other.
    case bolusLimitsNotChecked(doseUnits: Double, limitUnits: Double?)
    /// The dose is more than the insulin left in the cartridge, or under 2 U is left. The pump stops the
    /// bolus when the cartridge runs out.
    case lowInsulin(doseUnits: Double, remainingUnits: Double)

    /// The kind of confirmation, which an answer names.
    public enum Kind: String, Sendable, Hashable, CaseIterable, Codable {
        case tooManyBoluses, maxHourlyBolus, bolusLimitsNotChecked, lowInsulin
    }

    public var kind: Kind {
        switch self {
        case .tooManyBoluses: .tooManyBoluses
        case .maxHourlyBolus: .maxHourlyBolus
        case .bolusLimitsNotChecked: .bolusLimitsNotChecked
        case .lowInsulin: .lowInsulin
        }
    }

    /// Under this much insulin left, a dose is confirmed whatever its size.
    public static let lowInsulinUnits = 2.0
    /// The max hourly bolus is this many times the pump's max bolus.
    public static let maxHourlyBolusMultiple = 1.5

    public var title: String {
        switch self {
        case .tooManyBoluses: "Too many boluses"
        case .maxHourlyBolus: "Max hourly bolus"
        case .bolusLimitsNotChecked: "Bolus limits not checked"
        case .lowInsulin: "Low insulin"
        }
    }

    public var message: String {
        switch self {
        case .tooManyBoluses(let flags):
            let what =
                switch (flags.insulinOnBoard, flags.hourlyLimit) {
                case (true, true): "IOB or the max hourly bolus"
                case (true, false): "IOB"
                default: "the max hourly bolus"
                }
            return "The pump says too many boluses were asked for in a short time. It may not track \(what) if "
                + "you go on."
        case .maxHourlyBolus(let dose, let lastHour, let limit):
            return "This bolus and the last hour's (\(Self.units(lastHour))) come to \(Self.units(dose + lastHour)), "
                + "over the max hourly bolus of \(Self.units(limit))."
        case .bolusLimitsNotChecked(_, let limit):
            let max = limit.map { " of \(Self.units($0))" } ?? ""
            return "The pump's count of the last hour's boluses couldn't be read, so whether this bolus goes over "
                + "the max hourly bolus\(max), or the pump says too many boluses were asked for, can't be checked."
        case .lowInsulin(let dose, let remaining):
            let left =
                dose > remaining
                ? "The cartridge has \(Self.units(remaining)) left, less than this bolus."
                : "The cartridge has only \(Self.units(remaining)) left."
            return left + " The bolus stops if the insulin runs out."
        }
    }

    /// The same in a few words, for a remote's small screen.
    public var shortMessage: String {
        switch self {
        case .tooManyBoluses(let flags):
            let what =
                switch (flags.insulinOnBoard, flags.hourlyLimit) {
                case (true, true): "IOB or the hourly limit"
                case (true, false): "IOB"
                default: "the hourly limit"
                }
            return "Too many boluses: the pump may not track \(what)."
        case .maxHourlyBolus(let dose, let lastHour, let limit):
            return String(format: "Over the max hourly bolus (%.2f of %.2f U).", dose + lastHour, limit)
        case .bolusLimitsNotChecked:
            return "Bolus limits not checked: the pump's hourly count couldn't be read."
        case .lowInsulin(_, let remaining):
            return "Low insulin: \(Self.units(remaining)) left."
        }
    }

    private static func units(_ value: Double) -> String { String(format: "%.2f U", value) }
}

extension DoseComposer {
    /// What the user confirms before `units` goes, in the order they are asked. From the calculator reply the
    /// dose was sized from and the freshest cartridge reading; a value the pump hasn't reported asks nothing,
    /// and the pump's own checks still apply.
    ///
    /// The too-many-boluses flags and the last hour's total change with every bolus, so they're taken only
    /// from a reply no older than the IOB window. The dose's preparation reads the reply again first
    /// (`PumpSession.prepareDose`), so an older one means that read went unanswered: then they can't be
    /// checked, and the user is asked to go on knowing that, never let through unasked.
    static func confirmations(units: Double, context: DoseContext) -> [DoseConfirmation] {
        var needed: [DoseConfirmation] = []
        let settings = context.pump.bolusCalculator?.value
        // Tandem's app takes the max bolus in whole units here.
        let limit = context.pumpMaxBolusUnits.map { $0.rounded(.down) * DoseConfirmation.maxHourlyBolusMultiple }
        if bolusLimitsUncheckable(context) {
            needed.append(.bolusLimitsNotChecked(doseUnits: units, limitUnits: limit))
        } else {
            if let flags = settings?.tooManyBoluses, flags.isSet { needed.append(.tooManyBoluses(flags)) }
            if let lastHour = settings?.bolusedLastHourUnits, lastHour.isFinite, let limit,
                units + lastHour > limit + mismatchSlack
            {
                needed.append(.maxHourlyBolus(doseUnits: units, lastHourUnits: lastHour, limitUnits: limit))
            }
        }
        if let remaining = insulinRemaining(context),
            units > remaining + mismatchSlack || remaining < DoseConfirmation.lowInsulinUnits
        {
            needed.append(.lowInsulin(doseUnits: units, remainingUnits: remaining))
        }
        return needed
    }

    /// Whether the last hour's total and the too-many-boluses flags can't be checked now: the calculator reply
    /// held reports them and is older than the IOB window, or was read before the last bolus the phone
    /// delivered (whose units it doesn't count). With no reply at all, or one that doesn't report them, the
    /// pump hasn't said and nothing is asked: the app adds no limit of its own, and the pump's apply.
    static func bolusLimitsUncheckable(_ context: DoseContext) -> Bool {
        guard let reply = context.pump.bolusCalculator,
            reply.value.tooManyBoluses != nil || reply.value.bolusedLastHourUnits != nil
        else { return false }
        if let delivered = context.lastDeliveryAt, reply.agedFrom < delivered { return true }
        return reply.isStale(after: context.freshness.insulinOnBoardStaleAfter, now: context.now)
    }

    /// The insulin left: the lower of the calculator reply's and the insulin reading's, each while no older
    /// than the window a reservoir reading is shown on. `nil` when neither is current.
    static func insulinRemaining(_ context: DoseContext) -> Double? {
        let window = context.freshness.glucoseStaleAfter
        let fromCalculator = context.pump.bolusCalculator.flatMap { reading in
            reading.value.insulinRemainingUnits.flatMap {
                reading.isStale(after: window, now: context.now) ? nil : $0
            }
        }
        let fromReading = context.pump.reservoirUnitsIfFresh(thresholds: context.freshness, now: context.now)
        return [fromCalculator, fromReading].compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }.min()
    }
}
