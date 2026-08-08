import Foundation

/// DIF-ux — the shared, surface-agnostic decision for a bolus attempted while the pump's bolus-calculator
/// INPUTS are stale or could not be confirmed fresh at compose time: the active-insulin (IOB) term and the
/// therapy parameters (carb ratio / ISF / target). It is the calc-input analogue of `StaleBolusPrompt` (the
/// stale-CGM three-way): one decision every surface routes through so the behavior — and the safety framing —
/// is identical everywhere the OWNER composes.
///
/// **Two inputs, two independent WARNED TWO-WAY choices — never a three-way, and never a "drop / zero" case.**
///
/// **IOB (`StaleIobPrompt` / `StaleIobChoice`).** The dose SUBTRACTS active insulin. When the IOB read is
/// stale (or the op-115↔op-109 IOB cross-check diverged) the only warned override is to keep SUBTRACTING the
/// last-known IOB, or to cancel. There is deliberately NO "ignore / zero the IOB" option: zeroing a term that
/// is subtracted is the MAXIMUM-dose direction — the opposite of the conservative include-stale-glucose
/// choice — so it is prohibited by the frozen owner decision. `includeLastKnownIob` therefore only ever keeps
/// subtracting the real cached value; it can never increase the dose beyond what a confirmed-fresh read would.
///
/// **Therapy (`StaleTherapyPrompt` / `StaleTherapyChoice`).** CR/ISF/target either come from the pump or they
/// don't; there is no partial / reduced-dose analogue. The warned override is to compute off the last-known
/// settings, or to cancel.
///
/// Both overrides are **per-attempt — never sticky, never a default, never auto-selected** — and both are
/// insulin-affecting, so they are recorded for the §13 clinical-review distribution gate
/// (`dosing-input-freshness-plan-2026-08-07.md`). `cancel` is a pure UI back-out of the compose flow: it must
/// send NOTHING (no pump write, no ledger entry, no `bolusStatus`).
///
/// **Host-owner only.** The HOST (iPhone) is the authoritative gate. A remote (Apple Watch / Mac / Garmin /
/// remote-iPhone) uses `shouldWarn` + the `CalcInputFreshness` age labels to grey/age its rows and PRE-WARN,
/// but NEVER offers `includeLastKnownIob` / `useLastKnownSettings` and NEVER sends an override — it fails
/// closed via the host's `resolveRemoteDose` (which recomputes with NO override).
public enum StaleIobChoice: String, Sendable, Codable, CaseIterable {
    /// Keep SUBTRACTING the last-known active-insulin value (explicit, per-attempt, insulin-affecting but
    /// never insulin-INCREASING). NEVER zeroes IOB.
    case includeLastKnownIob
    /// Abort the compose flow. NOT a pump `cancelBolus` (nothing was sent) — a pure UI back-out.
    case cancel
}

public enum StaleIobPrompt {

    /// Whether to show the two-way IOB warning before composing. Only when the IOB read is stale (past the
    /// `CalcInputFreshness.staleAfterIob` window) or its age is unknown at compose time — a nil date is
    /// unknown-age ⇒ stale ⇒ warn (fail-closed). A fresh IOB read composes normally.
    public static func shouldWarn(iobDate: Date?, now: Date = Date()) -> Bool {
        CalcInputFreshness.isIobStale(iobDate, now: now)
    }

    /// Whether a chosen path should compose and send a dose at all. `false` only for `cancel`.
    public static func proceeds(_ choice: StaleIobChoice) -> Bool { choice != .cancel }

    /// Shared warning lead every surface shows (each renders its own two buttons around it), naming the
    /// last-known IOB, its age, and — critically — that it will be SUBTRACTED (never zeroed), so the framing
    /// is identical everywhere and can never read as "ignore the IOB".
    public static func warningMessage(iobUnits: Double, iobDate: Date?, now: Date = Date()) -> String {
        let age = iobDate.map { CalcInputFreshness.ageLabel(for: $0, now: now) } ?? "of unknown age"
        return String(format: "faBolus couldn't confirm your active insulin is current "
            + "(last known %.2f U, %@). It will keep SUBTRACTING that %.2f U from this dose. "
            + "Use it, or cancel.", iobUnits, age, iobUnits)
    }
}

public enum StaleTherapyChoice: String, Sendable, Codable, CaseIterable {
    /// Compute off the last-known carb ratio / ISF / target (explicit, per-attempt).
    case useLastKnownSettings
    /// Abort the compose flow. Sends nothing (a pure UI back-out).
    case cancel
}

public enum StaleTherapyPrompt {

    /// Whether to show the two-way therapy warning before composing. Only when the therapy-params read is
    /// stale (past `CalcInputFreshness.staleAfterTherapy`) or its age is unknown at compose time. Nil ⇒ stale.
    public static func shouldWarn(therapyDate: Date?, now: Date = Date()) -> Bool {
        CalcInputFreshness.isTherapyStale(therapyDate, now: now)
    }

    /// Whether a chosen path should compose and send a dose at all. `false` only for `cancel`.
    public static func proceeds(_ choice: StaleTherapyChoice) -> Bool { choice != .cancel }

    /// Shared warning lead every surface shows. Names the last-known CR/ISF/target and their age when the
    /// profile is available (so the user sees exactly what the dose will be sized from); a compact fallback
    /// when only the fact of staleness is known.
    public static func warningMessage(profile: BolusMath.Profile?, therapyDate: Date?, now: Date = Date()) -> String {
        let age = therapyDate.map { CalcInputFreshness.ageLabel(for: $0, now: now) } ?? "of unknown age"
        if let p = profile {
            return String(format: "faBolus couldn't confirm this pump's bolus settings are current "
                + "(last known carb ratio %.0f g/U, ISF %d, target %d mg/dL, %@). "
                + "Use those settings, or cancel.",
                p.carbRatioGramsPerUnit, p.isfMgdlPerUnit, p.targetBgMgdl, age)
        }
        return "faBolus couldn't confirm this pump's bolus settings are current (last known settings, \(age)). "
            + "Use them, or cancel."
    }
}
