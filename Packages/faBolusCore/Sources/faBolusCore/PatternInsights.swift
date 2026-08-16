import Foundation

/// Plain-language retrospective insights from the user's CGM (+ optional carbs) history — the kind of
/// pattern-spotting a clinician does in a review, surfaced automatically. Decision-support, not acute;
/// advisory display only — it never blocks, clamps, or changes a dose.
///
/// Moved from the private faBolusNudge `TherapyInsightsKit` into `faBolusCore` (#92): retrospective
/// time-in-range / recurring-pattern reporting is verifiable and non-automating, so it belongs in the
/// stable, always-built core package rather than the optional advisory SDK. The algorithm is unchanged.
public final class PatternInsights {
    /// Lightweight glucose sample for the insights algorithm (mg/dL as `Double`). Nested to stay
    /// namespaced under `PatternInsights` and avoid colliding with faBolusCore's `GlucoseReading`
    /// (which carries an `Int` mg/dL) or any host-app type.
    public struct CGMPoint { public let mgdl: Double; public let date: Date
        public init(mgdl: Double, date: Date) { self.mgdl = mgdl; self.date = date } }
    public struct Carbs { public let grams: Double; public let date: Date
        public init(grams: Double, date: Date) { self.grams = grams; self.date = date } }

    public struct Insight { public let title: String; public let detail: String; public let severity: Int } // 0 info … 2 act

    public struct Config {
        public var low = 70.0, high = 180.0, minDays = 3.0
        public init() {}
    }
    let cfg: Config
    public init(config: Config = Config()) { self.cfg = config }

    /// - Parameter unit: the ACTIVE DISPLAY unit for the generated prose (04-08 gap closure, SC1).
    ///   `PatternInsights` is a `faBolusCore` type and must stay app-independent — it cannot read
    ///   `AppSettings.shared` — so the caller (`SmartAssist`/`AppModel.therapyInsights()`) passes the
    ///   unit through. Defaults to `.mgdl` so every pre-existing call site (and this method's own
    ///   mg/dL-mode wording) is byte-identical to before this parameter was added. The underlying
    ///   `Config.low`/`Config.high`/derived values this method reasons about stay mg/dL `Double` —
    ///   only the rendered `detail` text changes.
    public func insights(cgm: [CGMPoint], carbs: [Carbs] = [], unit: GlucoseUnit = .mgdl) -> [Insight] {
        let g = cgm.sorted { $0.date < $1.date }
        let span = (g.last?.date.timeIntervalSince(g.first?.date ?? Date()) ?? 0) / 86400
        guard span >= cfg.minDays, g.count > 100 else { return [] }
        var out: [Insight] = []
        let cal = Calendar.current

        // hourly time-below / time-above / mean
        var lowN = [Int](repeating: 0, count: 24), highN = [Int](repeating: 0, count: 24), n = [Int](repeating: 0, count: 24)
        for p in g {
            let h = cal.component(.hour, from: p.date); n[h] += 1
            if p.mgdl < cfg.low { lowN[h] += 1 }; if p.mgdl > cfg.high { highN[h] += 1 }
        }
        // worst low-risk hour cluster
        if let (h, frac) = (0..<24).compactMap({ n[$0] > 20 ? ($0, Double(lowN[$0])/Double(n[$0])) : nil })
                                    .max(by: { $0.1 < $1.1 }), frac > 0.06 {
            out.append(.init(title: "Recurring lows around \(hourLabel(h))",
                             detail: "About \(Int(frac*100))% of readings near \(hourLabel(h)) are below \(glucoseText(Int(cfg.low), unit: unit)). Consider less insulin / a snack before then, or discuss basal timing.",
                             severity: 2))
        }
        // worst high-time cluster
        if let (h, frac) = (0..<24).compactMap({ n[$0] > 20 ? ($0, Double(highN[$0])/Double(n[$0])) : nil })
                                    .max(by: { $0.1 < $1.1 }), frac > 0.5 {
            out.append(.init(title: "Highs concentrated around \(hourLabel(h))",
                             detail: "Readings near \(hourLabel(h)) are above \(glucoseText(Int(cfg.high), unit: unit)) ~\(Int(frac*100))% of the time.",
                             severity: 1))
        }
        // dawn phenomenon: rise between ~3am and ~7am on most days
        var dawnRises: [Double] = []
        let byDay = Dictionary(grouping: g) { cal.startOfDay(for: $0.date) }
        for (_, day) in byDay {
            let a = day.first { cal.component(.hour, from: $0.date) == 3 }
            let b = day.last { cal.component(.hour, from: $0.date) == 7 }
            if let a, let b, b.mgdl - a.mgdl > 0 { dawnRises.append(b.mgdl - a.mgdl) }
        }
        if dawnRises.count >= 3, dawnRises.filter({ $0 > 30 }).count >= Int(0.5*Double(dawnRises.count)) {
            let avg = dawnRises.reduce(0,+)/Double(dawnRises.count)
            out.append(.init(title: "Dawn rise most mornings",
                             detail: "Glucose rises on average \(glucoseText(Int(avg), unit: unit)) between 3–7am. A basal adjustment before dawn may help — discuss with your clinician.",
                             severity: 1))
        }
        // overall TIR
        let tir = Double(g.filter { $0.mgdl >= cfg.low && $0.mgdl <= cfg.high }.count) / Double(g.count)
        out.append(.init(title: "Time in range: \(Int(tir*100))%",
                         detail: "Over the last \(Int(span)) days, \(Int(tir*100))% of readings were \(rangeText(Int(cfg.low), Int(cfg.high), unit: unit)).",
                         severity: tir < 0.6 ? 1 : 0))
        return out.sorted { $0.severity > $1.severity }
    }

    private func hourLabel(_ h: Int) -> String {
        let am = h < 12; let hr = h % 12 == 0 ? 12 : h % 12; return "\(hr)\(am ? "am" : "pm")"
    }

    /// A single glucose figure in `unit`'s display text (e.g. `"70 mg/dL"` / `"3.9 mmol/L"`). `.mgdl`
    /// reproduces the exact pre-04-08 literal wording (`"\(mgdl) mg/dL"`); `.mmol` routes the SAME
    /// mg/dL `Int` through the canonical `GlucoseUnit.format` funnel — no second conversion path.
    private func glucoseText(_ mgdl: Int, unit: GlucoseUnit) -> String {
        switch unit {
        case .mgdl: return "\(mgdl) mg/dL"
        case .mmol: return "\(unit.format(mgdl: mgdl)) mmol/L"
        }
    }

    /// A low–high glucose RANGE in `unit`'s display text with a single trailing unit label (e.g.
    /// `"70–180 mg/dL"` / `"3.9–10.0 mmol/L"`). Same byte-identical-mgdl / funnel-routed-mmol contract
    /// as `glucoseText`.
    private func rangeText(_ lowMgdl: Int, _ highMgdl: Int, unit: GlucoseUnit) -> String {
        switch unit {
        case .mgdl: return "\(lowMgdl)–\(highMgdl) mg/dL"
        case .mmol: return "\(unit.format(mgdl: lowMgdl))–\(unit.format(mgdl: highMgdl)) mmol/L"
        }
    }
}
