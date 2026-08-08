import Foundation

/// DIF-ux — the PURE, exhaustively-testable decision for whether a bolus compose must show the warned
/// stale/unconfirmed-calc-inputs override before delivering, and which two-way prompt to show. Extracted
/// out of `BolusEntryView.attemptDeliver` deliberately: while this branch logic lived inline in the SwiftUI
/// view it had NO test coverage and repeatedly harbored dose-path defects (gate firing in Units mode /
/// then a carb-derived dose leaking into Units mode un-acknowledged; the neither-flag unconfirmed-but-
/// in-window case; override-kind selection). A SwiftUI view has no test seam, so those decisions were only
/// ever checked by after-the-fact adversarial review. Pulling the decision here makes the whole branch
/// matrix a unit test, so a future edit that reintroduces any of those holes fails a test rather than
/// shipping. The view keeps the UI-transient bits (a prompt is already showing, presenting the dialog).
public enum CalcInputGate {

    /// Which input(s) were unconfirmed → which warned two-way prompt to show, and (derived) which override
    /// the "use / include last-known" button applies. `iob` = include-last-known-IOB only; `therapy` =
    /// use-last-known-settings only; `both` = the unified override — also the neither-flag case (inputs
    /// unconfirmed THIS attempt but each still inside its display window), so an unconfirmed dose is never
    /// silently delivered just because both staleness flags happen to be false.
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case iob, therapy, both
        public var allowStaleIob: Bool { self == .iob || self == .both }
        public var allowStaleTherapy: Bool { self == .therapy || self == .both }
    }

    public enum Decision: Equatable, Sendable {
        case proceed              // no gate — deliver on the normal path
        case prompt(Kind)         // show the warned two-way override of this kind BEFORE composing a dose
    }

    /// The gate. Returns `.prompt` iff a warned override must be shown first. It fires:
    ///   • ONLY in carbs-calculator mode — a Units-mode dose is the exact number the user dialed and does
    ///     NOT use the pump's CR/ISF/target/IOB, so the "inputs unconfirmed" warning does not apply to it;
    ///     a carbs-calculator dose that was left in the Units field is cleared on the mode switch, so it
    ///     can never reach delivery in Units mode either.
    ///   • ONLY when the recommendation is not verified-fresh (`!inputsVerified`) — checked BEFORE any
    ///     staleness flag, so the unconfirmed-but-in-window case (`iobStale == therapyStale == false` yet
    ///     `!inputsVerified`, i.e. the compose-time read timed out but the cache is still in-window) is
    ///     still caught and routed to `.both`.
    ///   • ONLY if the owner has NOT already accepted an override for this attempt (`overrideAccepted`),
    ///     so the re-entry after accepting the prompt proceeds to actually deliver.
    public static func decide(isCarbsMode: Bool, inputsVerified: Bool,
                              iobStale: Bool, therapyStale: Bool, overrideAccepted: Bool) -> Decision {
        guard isCarbsMode, !inputsVerified, !overrideAccepted else { return .proceed }
        if therapyStale && !iobStale { return .prompt(.therapy) }
        if iobStale && !therapyStale { return .prompt(.iob) }
        return .prompt(.both)   // both stale, OR neither flag set but still unverified
    }

    /// The delivered dose for an accepted override on the manual/absent-BG path (the CGM path has its own
    /// fresh-read + divergence guard). Capped at the dose the warned button showed (`baseline`, what the
    /// owner consented to) and never above a fresh deliver-time recompute — so a routine IOB poll landing
    /// between the button and the tap can't silently inflate the correction. `min` is safe in both
    /// directions: IOB decayed (recompute larger) → deliver the consented baseline; IOB rose / therapy
    /// tightened (recompute smaller) → deliver the smaller fresh value.
    public static func overrideDeliverUnits(baseline: Double, freshRecompute: Double) -> Double {
        min(baseline, freshRecompute)
    }
}
