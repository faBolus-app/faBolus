import Foundation

/// DIF-ux — the shared, surface-agnostic decision for a bolus attempted while the pump's bolus-calculator
/// INPUTS are stale or could not be confirmed fresh at compose time: the active-insulin (IOB) term and the
/// therapy parameters (carb ratio / ISF / target). It is the calc-input analogue of `StaleBolusPrompt` (the
/// stale-CGM three-way): one decision every surface routes through so the behavior — and the safety framing —
/// is identical everywhere the OWNER composes.
///
/// **Two inputs, two independent WARNED TWO-WAY choices — never a three-way, and never a "drop / zero" case.**
/// That §13 no-zero-IOB-override shape is machine-checked on `CalcInputGate.Kind` (the surface the deliver
/// path actually calls), not here.
///
/// **IOB (`StaleIobPrompt`).** The dose SUBTRACTS active insulin. When the IOB read is stale (or the
/// op-115↔op-109 IOB cross-check diverged) the only warned override is to keep SUBTRACTING the last-known
/// IOB, or to cancel. There is deliberately NO "ignore / zero the IOB" option: zeroing a term that is
/// subtracted is the MAXIMUM-dose direction — the opposite of the conservative include-stale-glucose
/// choice — so it is prohibited by the frozen owner decision.
///
/// **Therapy (`StaleTherapyPrompt`).** CR/ISF/target either come from the pump or they don't; there is no
/// partial / reduced-dose analogue. The warned override is to compute off the last-known settings, or to
/// cancel.
///
/// Both overrides are **per-attempt — never sticky, never a default, never auto-selected** — and both are
/// insulin-affecting, so they are recorded for the §13 clinical-review distribution gate
/// (`dosing-input-freshness-plan-2026-08-07.md`). `cancel` is a pure UI back-out of the compose flow: it must
/// send NOTHING (no pump write, no ledger entry, no `bolusStatus`).
///
/// **Host-owner only.** The HOST (iPhone) is the authoritative gate. A remote (Apple Watch / Mac / Garmin /
/// remote-iPhone) uses `shouldWarn` + the `CalcInputFreshness` age labels to grey/age its rows and PRE-WARN,
/// but NEVER offers the include-last-known overrides and NEVER sends an override — it fails closed via the
/// host's `resolveRemoteDose` (which recomputes with NO override).
public enum StaleIobPrompt {

    // NOTE: the deliver-time DECISION of whether to warn — and which two-way prompt — is NOT here; it is the
    // pure, unit-tested `CalcInputGate.decide` (keyed on the recommendation's `inputsVerified`/`iobStale`/
    // `therapyStale`, the values the compose actually produced). This enum only owns the shared WARNING COPY
    // so every surface reads identically. (Earlier `shouldWarn`/`proceeds` helpers here were unused by any
    // production path and were removed — they had tests that gave false confidence they were the gate.)

    /// Shared warning lead every surface shows (each renders its own two buttons around it), naming the
    /// last-known IOB, its age, and — critically — that it will be SUBTRACTED (never zeroed), so the framing
    /// is identical everywhere and can never read as "ignore the IOB".
    public static func warningMessage(iobUnits: Double, iobDate: Date?, now: Date = Date()) -> String {
        let age = iobDate.map { CalcInputFreshness.ageLabel(for: $0, now: now) } ?? "of unknown age"
        // "keep SUBTRACTING" (never drop/zero). If the pump's two active-insulin reads disagree (the
        // cross-check-divergence case, e.g. just after a bolus), the dose subtracts the LARGER of them, so
        // the shown last-known value can only understate — never overstate — what is subtracted (the safe
        // direction). The copy stays honest about that without over-committing to a single number.
        return String(
            format: "faBolus couldn't confirm your active insulin is current "
                + "(last known %.2f U, %@). It will keep SUBTRACTING that active insulin — the higher reading if "
                + "the pump's two readings disagree — never dropping it. Use it, or cancel.", iobUnits, age)
    }
}

public enum StaleTherapyPrompt {

    // The warn/which-prompt decision lives in the pure `CalcInputGate.decide` (see StaleIobPrompt note);
    // this enum only owns the shared warning COPY. (Unused `shouldWarn`/`proceeds` helpers removed.)

    /// Shared warning lead every surface shows. Names the last-known CR/ISF/target and their age when the
    /// profile is available (so the user sees exactly what the dose will be sized from); a compact fallback
    /// when only the fact of staleness is known.
    ///
    /// - Parameter unit: the ACTIVE DISPLAY unit for the ISF/target figures.
    ///   `StaleCalcInputPrompt` is a `faBolusCore` type and must stay app-independent — it cannot read
    ///   `AppSettings.shared` — so the caller (`BolusEntryView`) passes the unit through. Defaults to
    ///   `.mgdl` so every pre-existing call site (and this method's own mg/dL-mode wording) is
    ///   byte-identical to before this parameter was added. `p.isfMgdlPerUnit`/`p.targetBgMgdl` stay
    ///   mg/dL `Int` on `BolusMath.Profile` — only the rendered text changes. Carb ratio is
    ///   unit-agnostic (g/U) and is never touched by this parameter.
    public static func warningMessage(
        profile: BolusMath.Profile?, therapyDate: Date?, now: Date = Date(), unit: GlucoseUnit = .mgdl
    ) -> String {
        let age = therapyDate.map { CalcInputFreshness.ageLabel(for: $0, now: now) } ?? "of unknown age"
        if let p = profile {
            return String(
                format: "faBolus couldn't confirm this pump's bolus settings are current "
                    + "(last known carb ratio %.0f g/U, ISF %d, target %d mg/dL, %@). "
                    + "Use those settings, or cancel.",
                p.carbRatioGramsPerUnit, p.isfMgdlPerUnit, p.targetBgMgdl, age)
        }
        return "faBolus couldn't confirm this pump's bolus settings are current (last known settings, \(age)). "
            + "Use them, or cancel."
    }
}
