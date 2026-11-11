import Foundation
import TandemMessages
import faBolusCore

/// The signed messages for one bolus, built from a composed dose the way Tandem's own app builds them, so
/// the pump's records (and t:connect's) read as they would for a bolus from Tandem's app. Each rule cites
/// the pumpx2 capture (`InitiateBolusRequestTest`, `RemoteCarbEntryRequestTest`, `RemoteBgEntryRequestTest`)
/// it follows.
///
/// - Carbs with a correction on top (ID10677, ID10678): type bits 3, the volume split into the carbs'
///   part and the correction's.
/// - Carbs alone, or carbs with the dose at or under the carbs' part (ID10652, ID10653): type bits 1, all
///   of it food.
/// - No carbs, whether units the user entered or a calculator dose for 0 g (ID10650): type bits 8, no
///   food or correction volume. The phone and the remotes send 0 g the same way.
/// - The BG entry, then the carb entry, carry the pump's seconds since boot (TimeSinceReset's
///   `pumpTimeSinceReset`) and the bolus ID; the BG entry is manual and remote (entry type 0, source 1).
///
/// The delivered amount depends only on the total; the split and the entries are the pump's record.
struct BolusCommands: Sendable {
    let initiate: InitiateBolusRequest
    let bgEntry: RemoteBgEntryRequest?
    let carbEntry: RemoteCarbEntryRequest?
    let totalMilliunits: UInt32

    enum Refusal: Error, Equatable {
        /// An extended bolus: room for later, never built in this release.
        case extendedNotSupported
        /// The dose isn't a finite, positive number of whole milliunits within the pump's limits.
        case invalidAmount
        /// More carbs than the pump records (999 g).
        case carbsOutOfRange
        /// TandemKit's validator refused the request.
        case rejected(String)
    }

    /// The most carbs the pump's bolus screen takes, so the most a record can say.
    static let maxCarbGrams = 999

    /// - Parameter uptime: the pump's seconds since boot, for the entries.
    static func make(_ dose: ComposedDose, bolusId: Int, uptime: UInt32) throws(Refusal) -> BolusCommands {
        guard case .now(let units) = dose.request.shape else { throw .extendedNotSupported }
        guard units.isFinite, units > 0, units * 1000 <= Double(UInt32.max) else { throw .invalidAmount }
        let total = UInt32((units * 1000).rounded())

        let carbs = try carbGrams(dose.request.carbsGrams)
        let bg = dose.correctionGlucoseMgdl.flatMap { CalculatorGlucose.isValid(mgdl: $0) ? $0 : nil } ?? 0
        let iobUnits = dose.calculatorIOBUnits.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        let iob = UInt32(min((iobUnits * 1000).rounded(), 1_000_000))

        var bitmask = InitiateBolusRequest.bitFood2
        var food: UInt32 = 0
        var correction: UInt32 = 0
        if carbs > 0 {
            food = dose.calculatorCarbUnits.map { min(total, UInt32(max(0, ($0 * 1000).rounded()))) } ?? total
            correction = total - food
            bitmask = InitiateBolusRequest.typeBitmask(hasCarbs: true, hasCorrection: correction > 0, isExtended: false)
        }

        let initiate: InitiateBolusRequest
        do {
            initiate = try InitiateBolusRequest(
                validating: total, bolusID: bolusId, bolusTypeBitmask: bitmask, foodVolume: food,
                correctionVolume: correction, bolusCarbs: carbs, bolusBG: bg, bolusIOB: iob, extendedVolume: 0,
                extendedSeconds: 0, extended3: 0)
        } catch {
            throw .rejected(String(describing: error))
        }
        return BolusCommands(
            initiate: initiate,
            bgEntry: bg > 0
                ? RemoteBgEntryRequest(
                    bg: bg, useForCgmCalibration: false, entryTypeId: 0, sourceId: 1, pumpTimeSecondsSinceBoot: uptime,
                    bolusId: bolusId)
                : nil,
            carbEntry: carbs > 0
                ? RemoteCarbEntryRequest(carbs: carbs, unknown: 1, pumpTimeSecondsSinceBoot: uptime, bolusId: bolusId)
                : nil,
            totalMilliunits: total)
    }

    /// Whole grams, as the pump records them. A dose entered in units has none.
    static func carbGrams(_ grams: Double?) throws(Refusal) -> Int {
        guard let grams else { return 0 }
        guard grams.isFinite, grams >= 0 else { throw .carbsOutOfRange }
        let whole = Int(grams.rounded())
        guard whole <= maxCarbGrams else { throw .carbsOutOfRange }
        return whole
    }
}
