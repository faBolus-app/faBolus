import Foundation
import os

/// **Insulin Stacking Guard — pure friction/disclosure surface.**
///
/// **These are DISCLOSURE / FRICTION facts, never therapy — and they NEVER affect delivery.** Nothing here
/// blocks, disables, clamps, delays, resizes, or reorders a dose; the deliver button and the number that
/// reaches the pump are unchanged. Every function here returns a `Disclosure` — a friction level plus a
/// string to show, or `nil` — never a units/dose value. This mirrors `AutoCorrectionDisclosure`'s exact
/// shape: a namespace enum of static pure functions over explicit inputs, mechanism-gated on the pump's OWN
/// reported values (never a hardcoded clinical constant).
///
/// **Structural "never a dose decision" guarantee:** `Friction` has NO `.block`
/// case — it is `Comparable`/`CaseIterable` over exactly four levels, none of which the delivery path is
/// wired to. No function below returns a units/dose field. A future refactor that tries to thread a
/// `StackingGuard` result into `attemptDeliver` / `CalcInputGate.decide` / `TandemBackend.validateDeliver`
/// would have to invent a NEW type to do it — this file gives it nothing to grab.
///
/// **SG1** (`calcOverride`): discloses when the entered dose exceeds the pump's own op-115 calculator
/// suggestion while glucose is above the pump's own op-115 target — never a fixed clinical threshold.
/// **SG2** (`maxBolusProximity`): discloses when the entered dose is at or above the pump's own reported
/// Max-Bolus (op-115 `maxBolusAmount`) — anchored purely on that pump read, never a hardcoded cap.
/// **SG3a** (`escalation`): composes the SG1/SG2 signals into a single escalating `Friction`
/// (`.disclose` → `.confirmExtra` → `.reenter`) as the override magnitude crosses owner-confirmable,
/// lock-backed cut-points (`confirmExtraOverrideRatio` / `reenterOverrideRatio`) — still friction/disclosure
/// only, never a `.block` case, never a units field.
/// **SG3b** (`tempRateOffer`): a strictly-inert stub — see its doc comment.
public enum StackingGuard {

    /// Friction levels a StackingGuard function can report. Ordered (`Comparable` via `rawValue`) so a
    /// future caller could pick the max across multiple guards, but nothing here computes or compares a
    /// dose. **No `.block` case exists, and none will be added** — this is the compile-time half of the
    /// MUST-NOT-BLOCK guarantee (the other half is `StackingGuardDeliverInvariantTests`).
    public enum Friction: Int, Comparable, CaseIterable, Sendable {
        case none, disclose, confirmExtra, reenter

        public static func < (lhs: Friction, rhs: Friction) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A single friction/disclosure result. `message` is the primary line a surface renders; `detail` is
    /// optional supporting context (e.g. current IOB) a surface may show alongside it. Neither field is ever
    /// a units/dose value — only descriptive text.
    public struct Disclosure: Equatable, Sendable {
        public let friction: Friction
        public let message: String?
        public let detail: String?

        public init(friction: Friction, message: String? = nil, detail: String? = nil) {
            self.friction = friction
            self.message = message
            self.detail = detail
        }

        /// The inert result: no friction, nothing to show. Every guard's negative case returns this.
        public static let none = Disclosure(friction: .none)
    }

    // MARK: - SG1: calc-override disclosure

    /// **SG1** — discloses when the user is about to bolus more than the pump's own bolus-calculator
    /// suggested, while glucose is above the pump's own op-115 target. Purely informational: it never gates,
    /// clamps, or delays the Deliver button (see `StackingGuardDeliverInvariantTests`).
    ///
    /// Fires (`.disclose`) when ALL hold: `displaysNumericDose` (never cite a dose sized off the
    /// hardcoded CR/ISF/target guess, mirrors `carbOverrideWarning`'s guard), `enteredUnits > 0`, glucose is
    /// present and strictly above `targetMgdl` (the pump's OWN op-115 target — never a Control-IQ 110 or any
    /// other clinical constant), and `enteredUnits` is strictly greater than `recommendedUnits`.
    ///
    /// The `recommendedUnits == 0` case is an explicit branch checked BEFORE any ratio — a nonzero entered
    /// dose against a zero recommendation discloses "the calculator did not suggest a dose" rather than ever
    /// computing an entered/recommended ratio, so this function can never divide by zero and never renders a
    /// NaN/inf into a string.
    ///
    /// Does NOT fire (`.none`) when: `enteredUnits <= recommendedUnits` (includes the exact-match case — a
    /// carb bolus taken exactly as the calculator recommended, at ANY size, is not an override); glucose is
    /// absent or at/below `targetMgdl`; or `displaysNumericDose` is false.
    ///
    /// `pumpIOBUnits` is accepted (op-109 `swan6hrIOB`, the same value later plans' SG2 stacking check reads)
    /// and surfaced as optional `detail` context when SG1 fires — it never affects whether SG1 fires.
    public static func calcOverride(
        enteredUnits: Double,
        recommendedUnits: Double,
        displaysNumericDose: Bool,
        pumpIOBUnits: Double,
        glucoseMgdl: Int?,
        targetMgdl: Int
    ) -> Disclosure {
        guard displaysNumericDose else { return .none }
        guard enteredUnits > 0 else { return .none }
        guard let glucose = glucoseMgdl, glucose > targetMgdl else { return .none }

        // Full-override branch — BEFORE any ratio. A nonzero entered dose against a zero recommendation
        // discloses without ever computing entered/recommended (no NaN/inf can leak into the message).
        if recommendedUnits == 0 {
            return Disclosure(
                friction: .disclose,
                message:
                    "You're entering \(Self.formatUnits(enteredUnits)) U — the pump's calculator did not suggest a dose.",
                detail: Self.iobDetail(pumpIOBUnits))
        }

        guard enteredUnits > recommendedUnits else { return .none }
        return Disclosure(
            friction: .disclose,
            message: "You're entering more than the pump's calculator suggested.",
            detail: Self.iobDetail(pumpIOBUnits))
    }

    // MARK: - SG2: max-bolus proximity disclosure

    /// **SG2** — discloses when the entered dose is at or above the pump's OWN reported Max-Bolus
    /// (`snapshot.maxBolusUnits`, a direct op-115 `maxBolusAmount` read) — never a hardcoded cap and never a
    /// near-band fraction (an 80%-of-max warning is an owner-confirmable param, default off, not built
    /// here). Purely
    /// informational: it never gates, clamps, or delays the Deliver button (see
    /// `StackingGuardDeliverInvariantTests`).
    ///
    /// Fires (`.disclose`) when `maxBolusUnits > 0` (a valid pump max was actually reported) AND
    /// `enteredUnits >= maxBolusUnits` (at or above the pump's own max — the existing `overMax` label already
    /// covers strictly-above; SG2's disclosure additionally covers the boundary exactly-at-max case).
    ///
    /// Does NOT fire (`.none`) when `enteredUnits < maxBolusUnits`, or when `maxBolusUnits <= 0` (no valid
    /// pump max reported — never disclose against an invalid/unread anchor).
    public static func maxBolusProximity(enteredUnits: Double, maxBolusUnits: Double) -> Disclosure {
        guard maxBolusUnits > 0 else { return .none }
        guard enteredUnits >= maxBolusUnits else { return .none }
        return Disclosure(
            friction: .disclose,
            message:
                "You're entering \(Self.formatUnits(enteredUnits)) U — at or above this pump's maximum bolus of \(Self.formatUnits(maxBolusUnits)) U."
        )
    }

    // MARK: - insufficientReservoir: out-of-insulin over-request disclosure

    /// **Out-of-insulin over-request disclosure** — discloses when the entered dose exceeds
    /// the pump's OWN reported reservoir remaining (`snapshot.reservoirUnits`, a direct
    /// `InsulinStatusResponse.currentInsulinAmount` read) — never a hardcoded threshold. Purely informational,
    /// a sibling of `maxBolusProximity`: it never gates, clamps, resizes, or delays the Deliver button (see
    /// `StackingGuardDeliverInvariantTests`). The pump is the physical enforcer of what it can actually
    /// deliver; clamping the number here would be a silent dose decision, against Stacking-Guard philosophy.
    ///
    /// Fires (`.disclose`) when `reservoirUnits >= 0` (a valid pump reading — `0` is a legitimate "empty"
    /// reservoir, distinct from an unread/invalid negative value) AND `enteredUnits > reservoirUnits` (strictly
    /// above — the exact-match boundary does NOT fire, mirroring `maxBolusProximity`'s own boundary
    /// convention but on the opposite side: here the pump can still deliver exactly what remains).
    ///
    /// Does NOT fire (`.none`) when `enteredUnits <= reservoirUnits`, or when `reservoirUnits < 0` (no valid
    /// pump reading — never disclose against an unread/invalid anchor).
    public static func insufficientReservoir(enteredUnits: Double, reservoirUnits: Double) -> Disclosure {
        guard reservoirUnits >= 0 else { return .none }
        guard enteredUnits > reservoirUnits else { return .none }
        return Disclosure(
            friction: .disclose,
            message:
                "You're entering \(Self.formatUnits(enteredUnits)) U — more than the \(Self.formatUnits(reservoirUnits)) U reported remaining in the pump's reservoir. The pump may refuse or short-deliver this dose."
        )
    }

    // MARK: - SG3a: escalating friction (SG1 override magnitude + SG2 max-proximity)

    // Thread-safe backing (mirrors `CalcInputFreshness`'s `OSAllocatedUnfairLock` idiom): set at launch
    // (or by a future Settings screen) and read from many isolation domains, so a bare
    // `nonisolated(unsafe) static var` would only silence the checker, not make the mutation actually safe.
    //
    // **Owner-confirmable starting points with no evidence base.** These are the
    // override-ratio (entered ÷ recommended) cut-points at which SG3a escalates the friction tier. They are
    // NOT clinical thresholds; they exist purely to decide how much friction/confirmation to surface before
    // an unusually large override reaches the (unaffected) Deliver button.
    private static let _confirmExtraOverrideRatio = OSAllocatedUnfairLock<Double>(initialState: 1.5)
    private static let _reenterOverrideRatio = OSAllocatedUnfairLock<Double>(initialState: 2.0)

    /// The override ratio (`enteredUnits / recommendedUnits`) at or above which `escalation` steps up from
    /// `.disclose` to `.confirmExtra` — e.g. the default `1.5` means "50% more than the pump's calculator
    /// suggested". **Owner-confirmable default; not a clinical constant.**
    public static var confirmExtraOverrideRatio: Double {
        get { _confirmExtraOverrideRatio.withLock { $0 } }
        set { _confirmExtraOverrideRatio.withLock { $0 = newValue } }
    }

    /// The override ratio at or above which `escalation` steps up to the most extreme tier, `.reenter` —
    /// e.g. the default `2.0` means "double the pump's calculator suggestion". Must stay `>=
    /// confirmExtraOverrideRatio` for the tiers to remain ordered; **owner-confirmable default.**
    public static var reenterOverrideRatio: Double {
        get { _reenterOverrideRatio.withLock { $0 } }
        set { _reenterOverrideRatio.withLock { $0 = newValue } }
    }

    /// **SG3a** — composes the SG1 override signal (`calcOverride`) and the SG2 max-proximity signal
    /// (`maxBolusProximity`) into a single escalating `Friction` outcome. Purely informational/friction:
    /// like every function in this file, it never gates, clamps, delays, or resizes the Deliver button (see
    /// `StackingGuardDeliverInvariantTests`), and the return type is `Disclosure` — never a units/dose value.
    ///
    /// Escalation ladder, keyed on the override ratio `enteredUnits / recommendedUnits`:
    /// - `.none` — SG1 would not fire (see `calcOverride`'s guards: not displayable, no glucose above the
    ///   pump's own target, or `enteredUnits <= recommendedUnits` — the exact-match false-positive included,
    ///   at ANY dose size).
    /// - `.disclose` — SG1 fires and the ratio is below `confirmExtraOverrideRatio`, and the dose is below
    ///   the pump's own reported max (SG2 does not fire either).
    /// - `.confirmExtra` — the ratio has crossed `confirmExtraOverrideRatio` (a materially stronger
    ///   override), OR the dose is at/above the pump's own reported max (SG2 fires) even if the ratio alone
    ///   hasn't crossed that cut-point yet.
    /// - `.reenter` — the ratio has crossed `reenterOverrideRatio` (the most extreme override), OR
    ///   `recommendedUnits == 0` (a nonzero dose against a calculator that suggested nothing at all — the
    ///   most extreme case there is, disclosed WITHOUT ever computing an entered/recommended ratio, so this
    ///   branch can never divide by zero and never renders a NaN/inf into a message).
    ///
    /// Monotonic in override magnitude: a strictly larger `enteredUnits` (all else held fixed) never steps
    /// the friction level DOWN, because the ratio and the max-proximity signal are each monotonic in
    /// `enteredUnits` and the ladder above only ever steps up as either crosses its cut-point.
    public static func escalation(
        enteredUnits: Double,
        recommendedUnits: Double,
        displaysNumericDose: Bool,
        pumpIOBUnits: Double,
        glucoseMgdl: Int?,
        targetMgdl: Int,
        maxBolusUnits: Double
    ) -> Disclosure {
        let sg1 = calcOverride(
            enteredUnits: enteredUnits, recommendedUnits: recommendedUnits,
            displaysNumericDose: displaysNumericDose, pumpIOBUnits: pumpIOBUnits,
            glucoseMgdl: glucoseMgdl, targetMgdl: targetMgdl)
        guard sg1.friction != .none else { return .none }

        let sg2 = maxBolusProximity(enteredUnits: enteredUnits, maxBolusUnits: maxBolusUnits)
        let atOrAboveMax = sg2.friction != .none

        // Full-override branch — BEFORE any ratio, mirroring `calcOverride`'s own zero-recommendation
        // guard. The most extreme tier: there is no basis at all to measure "how much" of an override this
        // is, so it goes straight to `.reenter` rather than ever dividing by zero.
        if recommendedUnits == 0 {
            return Disclosure(
                friction: .reenter,
                message:
                    "You're entering \(Self.formatUnits(enteredUnits)) U with no calculator suggestion to compare against — please re-enter to confirm.",
                detail: sg1.detail)
        }

        let ratio = enteredUnits / recommendedUnits
        if ratio >= reenterOverrideRatio {
            return Disclosure(
                friction: .reenter,
                message: "This dose is far above what the pump's calculator suggested — please re-enter to confirm.",
                detail: sg1.detail)
        }
        if ratio >= confirmExtraOverrideRatio || atOrAboveMax {
            return Disclosure(
                friction: .confirmExtra,
                message:
                    "This dose is well above what the pump's calculator suggested — please confirm before delivering.",
                detail: sg1.detail)
        }
        return Disclosure(friction: .disclose, message: sg1.message, detail: sg1.detail)
    }

    // MARK: - SG3b: temp-rate offer (BLOCKED, strictly inert)

    /// **SG3b** — a structurally-unreachable stub. `SetTempRateRequest` is Mobi-only and requires
    /// Control-IQ OFF (`TempRateRequests.swift:3-5`), while SG3b's entire premise — offering the 150%
    /// temp-rate as an alternative to a correction bolus — only makes sense while Control-IQ is ON. That
    /// contradiction means this function can never legitimately fire; it exists ONLY to complete the
    /// `Friction`/`Disclosure` type surface, documented BLOCKED until a saline-bench check of
    /// temp-rate-while-Control-IQ-on unblocks it. Returns `.none` unconditionally — no default branch,
    /// no recommended-dose comparison, no units field, under every input.
    public static func tempRateOffer(
        iobUnits: Double,
        glucoseMgdl: Int?,
        controlIQEnabled: Bool
    ) -> Disclosure {
        .none
    }

    // MARK: - Formatting helpers (never used to derive a value that flows into a dose)

    private static func formatUnits(_ units: Double) -> String {
        String(format: "%.2f", units)
    }

    /// Optional IOB context for a firing disclosure. `nil` when there's no active insulin to mention.
    private static func iobDetail(_ iobUnits: Double) -> String? {
        guard iobUnits > 0 else { return nil }
        return String(format: "Active insulin on board: %.2f U.", iobUnits)
    }
}
