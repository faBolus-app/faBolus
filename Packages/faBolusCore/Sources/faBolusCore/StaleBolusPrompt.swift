import Foundation

/// P15 Addendum B — the shared, surface-agnostic decision for a bolus attempted while the current CGM
/// reading is **stale**.
///
/// Today a stale reading is silently dropped from the correction term (a carb bolus quietly becomes
/// carbs-only: every surface passes `bgMgdl: nil` when `GlucoseFreshness.isStale`). This type makes that
/// drop **explicit** and gives the user a warned, per-attempt three-way choice before the dose is composed.
/// iPhone, Apple Watch, Garmin and Mac all route through the SAME decision here so the behavior — and the
/// safety framing — is identical on every surface.
///
/// **Safety framing (C3/§9).** `includeStale` doses off a **stale-but-REAL measured** reading the user
/// explicitly chooses to trust. That is categorically different from dosing off a *predicted / modelled*
/// glucose (which is prohibited): no projection is invented, the user is warned, and the choice is
/// **per-attempt — never sticky, never a default, and never auto-selected.** It is an insulin-INCREASING
/// override, so the `includeStale` path must be recorded for the §13 clinical-review distribution gate
/// before it ships on `experimental`. `cancel` is a pure UI back-out of the compose flow: it must send
/// **nothing** — no pump write, no ledger entry, no `bolusStatus`.
public enum StaleBolusChoice: String, Sendable, Codable, CaseIterable {
    /// Use the stale reading in the correction term anyway (explicit, per-attempt, insulin-INCREASING).
    case includeStale
    /// Deliver carbs-only / no correction — today's silent behavior, now acknowledged.
    case proceedWithout
    /// Abort the compose flow. NOT a pump `cancelBolus` (nothing was sent) — a pure UI back-out.
    case cancel
}

public enum StaleBolusPrompt {

    /// Whether to show the three-way warning before composing a bolus. Only when there IS a reading value
    /// AND it is stale at compose time: no reading at all is not a "stale" case (it is simply carbs-only,
    /// with nothing to include), and a fresh reading composes normally. Judged from the reading's own
    /// source timestamp via `GlucoseFreshness` (so a future-skewed reading also counts as stale).
    public static func shouldWarn(glucoseMgdl: Int?, glucoseDate: Date?, now: Date = Date()) -> Bool {
        guard glucoseMgdl != nil else { return false }
        return GlucoseFreshness.isStale(glucoseDate, now: now)
    }

    /// Whether the **include-the-stale-reading** OPTION may be OFFERED for the current reading (Addendum B
    /// includable-age cap). True only when a reading EXISTS *and* its age is inside the includable window
    /// `(staleAfter, maxIncludableStaleness]` — genuinely stale, yet no older than the includable cap. This is
    /// the SAME single bound the host applies in `resolveRemoteDose` (`GlucoseFreshness.withinIncludableStaleness`).
    ///
    /// A reading OLDER than the cap — or fresh, missing, or future-skewed — returns false, so the caller must
    /// fall closed to carbs-only exactly as it does when there is nothing to include. This is a **strict subset**
    /// of `shouldWarn`: it only ADDS the upper bound `shouldWarn` lacks (an unbounded `> staleAfter`), never
    /// enabling an include the warn predicate wouldn't already flag. So an include offered off this predicate can
    /// never dose an insulin-INCREASING correction off a reading of arbitrary age.
    public static func mayOfferInclude(glucoseMgdl: Int?, glucoseDate: Date?, now: Date = Date()) -> Bool {
        guard glucoseMgdl != nil else { return false }
        return GlucoseFreshness.withinIncludableStaleness(glucoseDate, now: now)
    }

    /// The BG (mg/dL) to feed `BolusMath.estimate(bgMgdl:)` for a chosen path:
    /// - `includeStale` → the stale value (recompute WITH it),
    /// - `proceedWithout` / `cancel` → `nil` (no correction term — today's carbs-only dose).
    ///
    /// This only governs the dose input when a bolus is actually composed; for `cancel` the caller must
    /// not compose or send anything at all (see `proceeds`).
    public static func bgForCalculation(_ choice: StaleBolusChoice, staleGlucoseMgdl: Int?) -> Int? {
        switch choice {
        case .includeStale: return staleGlucoseMgdl
        case .proceedWithout, .cancel: return nil
        }
    }

    /// Whether a chosen path should compose and send a dose at all. `false` only for `cancel`.
    public static func proceeds(_ choice: StaleBolusChoice) -> Bool { choice != .cancel }

    /// Shared warning lead every surface shows (each renders its own three buttons around it), so the
    /// wording — including that the stale value was DROPPED from the dose — is identical everywhere.
    public static func warningMessage(glucoseMgdl: Int, glucoseDate: Date, now: Date = Date()) -> String {
        "Your CGM reading (\(glucoseMgdl) mg/dL) is \(GlucoseFreshness.ageLabel(for: glucoseDate, now: now)) "
            + "and was left out of this dose. Include it in the correction, bolus for carbs only, or cancel?"
    }
}
