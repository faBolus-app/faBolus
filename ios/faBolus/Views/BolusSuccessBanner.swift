import SwiftUI

// Phase 09.4 D-04/D-05/D-06/D-07 — a truthful, transient advisory confirmation for the embedded
// BolusEntryView.
//
// §13 NOTICE: the amount-stating copy templates in `BolusConfirmation.banner(for:units:extended:)`
// below are DRAFT and are experimental-distribution surface — they must pass owner/clinical review
// before an `experimental` build is distributed (BRANCHES.md §13), mirroring the DRAFT-copy pattern in
// `ModeViews.swift`. This copy is DELIBERATELY NOT added to `RegulatoryCopy.swift` — that file's strings
// are already SIGNED-OFF (2026-08-09); folding new DRAFT wording in there would re-open that sign-off
// for unrelated text. Keep the two gates separate.
//
// D-08/D-11: this file is a pure decision seam + a display-only view. It references no `AppModel`, no
// delivery API, and contains zero dose-path logic — it only maps an ALREADY-RESOLVED outcome (`Signal`)
// to display text, exactly like the repo's other static-for-test seams (`RootTabView.resolveSelection`,
// `BolusEntryView.reenterMatches`).

/// A resolved bolus-success banner: two lines of already-formatted display text. `nil` from
/// `BolusConfirmation.banner` means "show nothing" — there is no "banner but hidden" state.
struct BolusSuccessBanner: Equatable {
    let primary: String
    let secondary: String
}

/// Pure, dependency-free mapping from an ALREADY-RESOLVED bolus outcome to display text. NEVER
/// synthesizes a "delivered" banner for a pending or failed outcome — the core safety property of
/// D-04/D-05: a truthful confirmation, never a false one.
enum BolusConfirmation {
    /// The three outcomes a bolus attempt can resolve to, from the caller's ALREADY-KNOWN
    /// `model.lastError` / `model.pendingApproval` state (see `BolusEntryView.deliverFrozen` and its
    /// `.onChange(of: model.pendingApproval)` handler) — this type never inspects `AppModel` itself.
    enum Signal {
        /// Awaiting remote (child-mode) approval — `pendingApproval != nil`. NEVER a banner (D-05).
        case staged
        /// Blocked / indeterminate / failed / rejected / timed out. NEVER a banner (D-04/D-05).
        case failed
        /// The bolus actually completed with `lastError == nil` and no pending approval. The ONLY
        /// signal that produces a banner.
        case delivered
    }

    /// Extended (combo) bolus detail for the "{now} U now, {total} U total over {duration} min"
    /// secondary line (Copywriting Contract §3). `nil` (the default) means a standard bolus.
    struct ExtendedDetail {
        let nowUnits: Double
        let totalUnits: Double
        let durationMinutes: Int
    }

    /// `units` is the frozen total units the pump was actually sent (standard bolus amount, or the
    /// extended bolus's total). Formatting uses the repo's existing `String(format: "%.2f U", ...)`
    /// convention (`MainHUDView.swift:70/136/142`).
    static func banner(for signal: Signal, units: Double, extended: ExtendedDetail? = nil) -> BolusSuccessBanner? {
        guard signal == .delivered else { return nil }
        let primary = "Bolus delivered"
        let secondary: String
        if let extended {
            secondary = String(format: "%.2f U now, %.2f U total over %d min",
                                extended.nowUnits, extended.totalUnits, extended.durationMinutes)
        } else {
            secondary = String(format: "%.2f U delivered", units)
        }
        return BolusSuccessBanner(primary: primary, secondary: secondary)
    }
}
