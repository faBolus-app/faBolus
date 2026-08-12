import Foundation

/// **Insulin Stacking Guard — pure friction/disclosure surface (SG1–SG3b).**
///
/// **These are DISCLOSURE / FRICTION facts, never therapy — and they NEVER affect delivery.** Nothing here
/// blocks, disables, clamps, delays, resizes, or reorders a dose; the deliver button and the number that
/// reaches the pump are unchanged. Every function here returns a `Disclosure` — a friction level plus a
/// string to show, or `nil` — never a units/dose value. This mirrors `AutoCorrectionDisclosure`'s exact
/// shape: a namespace enum of static pure functions over explicit inputs, mechanism-gated on the pump's OWN
/// reported values (never a hardcoded clinical constant, C10 §2.4).
///
/// **Structural "never a dose decision" guarantee (task #93, criterion 4):** `Friction` has NO `.block`
/// case — it is `Comparable`/`CaseIterable` over exactly four levels, none of which the delivery path is
/// wired to. No function below returns a units/dose field. A future refactor that tries to thread a
/// `StackingGuard` result into `attemptDeliver` / `CalcInputGate.decide` / `TandemBackend.validateDeliver`
/// would have to invent a NEW type to do it — this file gives it nothing to grab (T-01-01).
///
/// **SG1** (`calcOverride`): discloses when the entered dose exceeds the pump's own op-115 calculator
/// suggestion while glucose is above the pump's own op-115 target — never a fixed clinical threshold.
/// **SG2** (`maxBolusProximity`): discloses when the entered dose is at or above the pump's own reported
/// Max-Bolus (op-115 `maxBolusAmount`) — anchored purely on that pump read, never a hardcoded cap.
/// **SG3b** (`tempRateOffer`): a strictly-inert stub — see its doc comment; BLOCKED pending a saline-bench
/// check, per `PROJECT.md`'s Out-of-Scope entry and `TempRateRequests.swift:3-5`.
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
    /// Fires (`.disclose`) when ALL hold: `displaysNumericDose` (§13 Rule-1 — never cite a dose sized off the
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
    public static func calcOverride(enteredUnits: Double,
                                    recommendedUnits: Double,
                                    displaysNumericDose: Bool,
                                    pumpIOBUnits: Double,
                                    glucoseMgdl: Int?,
                                    targetMgdl: Int) -> Disclosure {
        guard displaysNumericDose else { return .none }
        guard enteredUnits > 0 else { return .none }
        guard let glucose = glucoseMgdl, glucose > targetMgdl else { return .none }

        // Full-override branch — BEFORE any ratio. A nonzero entered dose against a zero recommendation
        // discloses without ever computing entered/recommended (no NaN/inf can leak into the message).
        if recommendedUnits == 0 {
            return Disclosure(friction: .disclose,
                              message: "You're entering \(Self.formatUnits(enteredUnits)) U — the pump's calculator did not suggest a dose.",
                              detail: Self.iobDetail(pumpIOBUnits))
        }

        guard enteredUnits > recommendedUnits else { return .none }
        return Disclosure(friction: .disclose,
                          message: "You're entering more than the pump's calculator suggested.",
                          detail: Self.iobDetail(pumpIOBUnits))
    }

    // MARK: - SG2: max-bolus proximity disclosure

    /// **SG2** — discloses when the entered dose is at or above the pump's OWN reported Max-Bolus
    /// (`snapshot.maxBolusUnits`, a direct op-115 `maxBolusAmount` read) — never a hardcoded cap and never a
    /// near-band fraction (an 80%-of-max warning is a §13 param, default off, NOT built this phase). Purely
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
        return Disclosure(friction: .disclose,
                          message: "You're entering \(Self.formatUnits(enteredUnits)) U — at or above this pump's maximum bolus of \(Self.formatUnits(maxBolusUnits)) U.")
    }

    // MARK: - SG3b: temp-rate offer (BLOCKED, strictly inert)

    /// **SG3b** — a structurally-unreachable stub. `SetTempRateRequest` is Mobi-only and requires
    /// Control-IQ OFF (`TempRateRequests.swift:3-5`), while SG3b's entire premise — offering the 150%
    /// temp-rate as an alternative to a correction bolus — only makes sense while Control-IQ is ON. That
    /// contradiction means this function can never legitimately fire; it exists ONLY to complete the
    /// `Friction`/`Disclosure` type surface for Phase 5 (task #93 criterion 5), documented BLOCKED and not
    /// schedulable until a saline-bench check of temp-rate-while-Control-IQ-on unblocks it (`PROJECT.md`
    /// Out-of-Scope). Returns `.none` unconditionally — no default branch, no recommended-dose comparison,
    /// no units field, under every input.
    public static func tempRateOffer(iobUnits: Double,
                                     glucoseMgdl: Int?,
                                     controlIQEnabled: Bool) -> Disclosure {
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
