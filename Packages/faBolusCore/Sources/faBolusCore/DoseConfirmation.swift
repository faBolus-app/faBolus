import Foundation

/// Something about the pump the user confirms before a dose goes, as Tandem's apps ask it: the pump
/// flagging too many boluses, the max hourly bolus, and a cartridge that may run out. Each is asked on the
/// phone and on a remote, and a dose goes once the user says to go on; none changes the dose.
public enum DoseConfirmation: Sendable, Equatable {
    /// The pump says too many boluses were asked for in a short time, so it may not track its hourly limit,
    /// IOB, or both, if the user goes on.
    case tooManyBoluses(BolusCalculatorSettings.TooManyBoluses)
    /// This dose and the last hour's boluses come to more than the max hourly bolus.
    case maxHourlyBolus(doseUnits: Double, lastHourUnits: Double, limitUnits: Double)
    /// The dose is more than the insulin left in the cartridge, or under 2 U is left. The pump stops the
    /// bolus when the cartridge runs out.
    case lowInsulin(doseUnits: Double, remainingUnits: Double)

    /// The kind of confirmation, which an answer names.
    public enum Kind: String, Sendable, Hashable, CaseIterable, Codable {
        case tooManyBoluses, maxHourlyBolus, lowInsulin
    }

    public var kind: Kind {
        switch self {
        case .tooManyBoluses: .tooManyBoluses
        case .maxHourlyBolus: .maxHourlyBolus
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
    static func confirmations(units: Double, context: DoseContext) -> [DoseConfirmation] {
        var needed: [DoseConfirmation] = []
        let settings = context.pump.bolusCalculator?.value
        if let flags = settings?.tooManyBoluses, flags.isSet { needed.append(.tooManyBoluses(flags)) }
        // Tandem's app takes the max bolus in whole units here.
        if let lastHour = settings?.bolusedLastHourUnits, lastHour.isFinite, let max = context.pumpMaxBolusUnits {
            let limit = max.rounded(.down) * DoseConfirmation.maxHourlyBolusMultiple
            if units + lastHour > limit + mismatchSlack {
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
