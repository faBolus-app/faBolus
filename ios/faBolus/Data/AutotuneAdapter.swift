#if FABOLUS_NUDGE
import Foundation
import faBolusCore
import AutotuneKit

/// Builds oref-format inputs from faBolus's stored data and runs the **real oref0 autotune**
/// (AutotuneKit, JavaScriptCore) to suggest tuned basal / ISF / carb-ratio. Advisory, experimental —
/// oref autotune wants **weeks** of good insulin+basal+CGM data to be meaningful, so this returns nil
/// until there's enough. Never blocks; any construction/run error just yields nil. See MIGRATION.md.
enum AutotuneAdapter {

    /// Returns human-readable suggestions, or nil if there isn't enough data / it couldn't run.
    static func suggestions(cgm: [GlucoseReading], boluses: [BolusMarker], basalByHour: [Double],
                            isf: Int, carbRatio: Double, targetBg: Int, diaHours: Double) -> [String]? {
        guard basalByHour.count == 24, cgm.count >= 288, isf > 0, carbRatio > 0 else { return nil }
        do {
            let autotune = try OrefAutotune()
            let tunedJSON = try autotune.run(
                pumpHistoryJSON: pumpHistory(boluses),
                profileJSON: profile(basalByHour: basalByHour, isf: isf, carbRatio: carbRatio,
                                     targetBg: targetBg, dia: diaHours),
                glucoseJSON: glucose(cgm),
                pumpProfileJSON: profile(basalByHour: basalByHour, isf: isf, carbRatio: carbRatio,
                                         targetBg: targetBg, dia: diaHours))
            return parse(tunedJSON, currentISF: isf, currentCR: carbRatio, currentBasal: basalByHour)
        } catch { return nil }
    }

    // MARK: oref input builders

    private static func json(_ obj: Any) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: obj), encoding: .utf8)) ?? "{}"
    }
    private static func isoFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }
    private static func hhmmss(_ minutes: Int) -> String {
        String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
    }

    private static func pumpHistory(_ boluses: [BolusMarker]) -> String {
        let iso = isoFormatter()
        return json(boluses.map { ["timestamp": iso.string(from: $0.date), "_type": "Bolus",
                                   "amount": $0.units, "duration": 0] as [String: Any] })
    }

    private static func glucose(_ cgm: [GlucoseReading]) -> String {
        let iso = isoFormatter()
        return json(cgm.sorted { $0.date > $1.date }.map {
            ["date": Int($0.date.timeIntervalSince1970 * 1000), "dateString": iso.string(from: $0.date),
             "sgv": $0.mgdl, "glucose": $0.mgdl, "type": "sgv"] as [String: Any]
        })
    }

    /// Build an oref profile from the schedule + ISF/CR/target/DIA (single-segment ISF/CR/target).
    private static func profile(basalByHour: [Double], isf: Int, carbRatio: Double, targetBg: Int,
                                dia: Double) -> String {
        // Collapse identical consecutive hours into basal segments.
        var basalprofile: [[String: Any]] = []
        for h in 0..<24 where h == 0 || basalByHour[h] != basalByHour[h - 1] {
            basalprofile.append(["minutes": h * 60, "rate": basalByHour[h], "start": hhmmss(h * 60),
                                 "i": basalprofile.count])
        }
        let maxBasal = max(basalByHour.max() ?? 1, 0.1)
        let p: [String: Any] = [
            "carb_ratio": carbRatio,
            "carb_ratios": ["units": "grams", "schedule": [[
                "x": 0, "i": 0, "offset": 0, "ratio": carbRatio, "r": carbRatio, "start": "00:00:00"]]],
            "isfProfile": ["first": 1, "units": "mg/dL", "user_preferred_units": "mg/dL",
                "sensitivities": [["endOffset": 1440, "offset": 0, "x": 0, "sensitivity": isf,
                                   "start": "00:00:00", "i": 0]]],
            "sens": isf,
            "bg_targets": ["first": 1, "units": "mg/dL", "user_preferred_units": "mg/dL",
                "targets": [["max_bg": targetBg, "min_bg": targetBg, "x": 0, "offset": 0, "low": targetBg,
                             "start": "00:00:00", "high": targetBg, "i": 0]]],
            "max_bg": targetBg, "min_bg": targetBg, "out_units": "mg/dL",
            "max_basal": maxBasal * 4, "min_5m_carbimpact": 8, "maxCOB": 120, "max_iob": 6,
            "max_daily_safety_multiplier": 4, "current_basal_safety_multiplier": 5,
            "autosens_max": 2, "autosens_min": 0.5, "remainingCarbsCap": 90,
            "curve": "rapid-acting", "useCustomPeakTime": false, "insulinPeakTime": 75, "dia": dia,
            "current_basal": basalByHour[0], "max_daily_basal": maxBasal,
            "basalprofile": basalprofile,
        ]
        return json(p)
    }

    // MARK: parse the tuned profile → suggestions

    private static func parse(_ tunedJSON: String, currentISF: Int, currentCR: Double,
                              currentBasal: [Double]) -> [String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(tunedJSON.utf8)) as? [String: Any]
        else { return nil }
        var out: [String] = []
        if let sens = (obj["isfProfile"] as? [String: Any])?["sensitivities"] as? [[String: Any]],
           let tunedISF = (sens.first?["sensitivity"] as? NSNumber)?.doubleValue,
           abs(tunedISF - Double(currentISF)) >= 1 {
            out.append("oref autotune: ISF ~\(Int(tunedISF)) mg/dL/U (current \(currentISF))")
        }
        if let cr = (obj["carb_ratio"] as? NSNumber)?.doubleValue, abs(cr - currentCR) >= 0.5 {
            out.append("oref autotune: carb ratio ~\(Int(cr)) g/U (current \(Int(currentCR)))")
        }
        if let basal = obj["basalprofile"] as? [[String: Any]] {
            let tunedAvg = basal.compactMap { ($0["rate"] as? NSNumber)?.doubleValue }.reduce(0, +)
                / Double(max(1, basal.count))
            let curAvg = currentBasal.reduce(0, +) / 24
            if abs(tunedAvg - curAvg) >= 0.05 {
                out.append(String(format: "oref autotune: average basal ~%.2f U/hr (current %.2f)", tunedAvg, curAvg))
            }
        }
        return out.isEmpty ? nil : out
    }
}
#endif // FABOLUS_NUDGE
