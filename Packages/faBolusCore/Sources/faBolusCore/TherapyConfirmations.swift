import Foundation

/// P14 S10 (§2.1(5)): TDD-relative therapy-edit SANITY bounds that **confirm, never block**.
///
/// Deliberately and strictly separate from `Interlocks` (the absolute HARD caps, e.g. the owner-locked
/// 25 U max-bolus ceiling): those clamp a value and can never be overridden; these only surface a
/// confirmation the user can always accept. §2.1(5)'s point is that today's therapy-edit bounds are
/// *only* absolute hard clamps, while the pump's own total daily insulin (TDD) is read into the snapshot
/// (`controlIQTotalDailyInsulin`) but never used as a bound. This introduces that use.
///
/// Each threshold here is a STARTING-POINT default with **no evidence base** — the same honesty the
/// SG / DS1 clinician defaults carry. It prompts a second look at an unusually large edit relative to
/// the user's own insulin use; it is not a clinical limit. A `nil` result means "no confirmation
/// needed", which INCLUDES the TDD-unknown case: a relative bound can't be computed without TDD, and
/// this is a sanity layer, not a safety gate — the hard cap (`Interlocks.clampMaxBolusLimit`) applies
/// regardless of what this returns.
public enum TherapyConfirmations {
    /// Fraction of TDD above which a max-bolus LIMIT edit warrants confirmation. A single-bolus ceiling
    /// above roughly half a day's insulin is unusual enough to re-confirm. Starting point, no evidence base.
    public static let maxBolusLimitTddFraction = 0.5

    /// A confirmation prompt for a proposed max-bolus **limit** that is large relative to the pump's TDD,
    /// or `nil` when it is within the sanity bound / TDD is unknown. Does NOT clamp — pair it with
    /// `Interlocks.clampMaxBolusLimit`, which still enforces the absolute 25 U hard cap independently.
    public static func maxBolusLimitConfirm(proposedUnits: Double, totalDailyInsulinUnits: Int) -> String? {
        guard totalDailyInsulinUnits > 0 else { return nil }
        let threshold = Double(totalDailyInsulinUnits) * maxBolusLimitTddFraction
        guard proposedUnits > threshold else { return nil }
        // `formatUnits` already appends " U" — do not double it.
        return
            "\(formatUnits(proposedUnits, fractionDigits: 1)) is a large max bolus for your total daily insulin of \(totalDailyInsulinUnits) U. Set it anyway?"
    }

    // MARK: - B1(d) §2.1(5): per-segment therapy-value advisories vs the TDD rules of thumb (WARN-ONLY)

    /// How far a value must sit from its TDD rule-of-thumb before an advisory fires: OUTSIDE
    /// `[expected / band, expected * band]`. A WIDE band (3×) on purpose — these flag a gross entry error
    /// (a typo, a units mix-up, an order-of-magnitude slip), NOT ordinary individual variation or normal
    /// per-segment differences (dawn phenomenon, etc.). Starting point, **no evidence base**; subject to
    /// §13 clinician review. Widen/narrow, never treat as a limit.
    public static let tddRuleBand = 3.0

    /// True when `value` is more than `tddRuleBand`× away (either direction) from `expected`. Guards a
    /// non-positive `expected` (returns false ⇒ no advisory) so a zero/negative rule can't fire spuriously.
    private static func isFarFromRule(_ value: Double, expected: Double) -> Bool {
        guard expected > 0, value > 0 else { return false }
        return value > expected * tddRuleBand || value < expected / tddRuleBand
    }

    /// **ISF (correction factor) advisory** vs the "1800 rule" (ISF ≈ 1800 / TDD, mg/dL per unit). Returns a
    /// double-check prompt when the entered value is wildly off for the pump's TDD, else `nil` — and `nil`
    /// ALSO covers TDD-unknown (TDD comes only from a configured Control-IQ; 0 ⇒ can't compute). WARN-ONLY:
    /// the caller shows this as a passive advisory; it never blocks, clamps, or resizes the edit.
    /// - Parameter unit: the ACTIVE DISPLAY unit for the returned advisory text (04-08 gap closure,
    ///   SC1). `TherapyConfirmations` is a `faBolusCore` type and must stay app-independent — it cannot
    ///   read `AppSettings.shared` — so the caller (`PumpWizardViews`) passes the unit through.
    ///   Defaults to `.mgdl` so every pre-existing call site (and this method's own mg/dL-mode wording)
    ///   is byte-identical to before this parameter was added. `isfMgdlPerUnit`/`expected` stay mg/dL
    ///   `Int`/`Double` throughout the "1800 rule" math — only the rendered text changes.
    public static func isfTddAdvisory(isfMgdlPerUnit: Int, totalDailyInsulinUnits: Int, unit: GlucoseUnit = .mgdl)
        -> String?
    {
        guard totalDailyInsulinUnits > 0 else { return nil }
        let expected = 1800.0 / Double(totalDailyInsulinUnits)
        guard isFarFromRule(Double(isfMgdlPerUnit), expected: expected) else { return nil }
        let expectedMgdl = Int(expected.rounded())
        switch unit {
        case .mgdl:
            return
                "For a total daily insulin of \(totalDailyInsulinUnits) U, a correction factor near \(expectedMgdl) mg/dL per unit is typical (the “1800 rule”). \(isfMgdlPerUnit) mg/dL per unit is unusual — double-check."
        case .mmol:
            return
                "For a total daily insulin of \(totalDailyInsulinUnits) U, a correction factor near \(unit.format(mgdl: expectedMgdl)) mmol/L per unit is typical (the “1800 rule”). \(unit.format(mgdl: isfMgdlPerUnit)) mmol/L per unit is unusual — double-check."
        }
    }

    /// **Carb ratio (ICR) advisory** vs the "500 rule" (ICR ≈ 500 / TDD, grams per unit). Same warn-only,
    /// nil-on-fine / nil-on-TDD-unknown contract as `isfTddAdvisory`.
    public static func carbRatioTddAdvisory(carbRatioGramsPerUnit: Double, totalDailyInsulinUnits: Int) -> String? {
        guard totalDailyInsulinUnits > 0 else { return nil }
        let expected = 500.0 / Double(totalDailyInsulinUnits)
        guard isFarFromRule(carbRatioGramsPerUnit, expected: expected) else { return nil }
        return
            "For a total daily insulin of \(totalDailyInsulinUnits) U, a carb ratio near \(Int(expected.rounded())) g per unit is typical (the “500 rule”). \(Int(carbRatioGramsPerUnit.rounded())) g per unit is unusual — double-check."
    }

    /// **Basal-rate advisory** vs the "~50% of TDD as basal, spread across the day" rule of thumb (per-hour
    /// ≈ 0.5 · TDD / 24). Because individual segments legitimately vary a lot (dawn phenomenon), this is the
    /// weakest of the three — the wide `tddRuleBand` is what keeps it from nagging on normal variation; it
    /// only catches a grossly out-of-range rate. Same warn-only / nil contract.
    public static func basalTddAdvisory(basalUnitsPerHour: Double, totalDailyInsulinUnits: Int) -> String? {
        guard totalDailyInsulinUnits > 0 else { return nil }
        let expected = 0.5 * Double(totalDailyInsulinUnits) / 24.0
        guard isFarFromRule(basalUnitsPerHour, expected: expected) else { return nil }
        return
            "For a total daily insulin of \(totalDailyInsulinUnits) U, an average basal near \(String(format: "%.2f", expected)) U/hr is typical (about half of daily insulin as basal; individual segments vary). \(String(format: "%.2f", basalUnitsPerHour)) U/hr is unusual — double-check."
    }
}
