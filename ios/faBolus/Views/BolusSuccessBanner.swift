import SwiftUI
import Foundation

/// Transient advisory confirmation for the embedded BolusEntryView. Pure display: no `AppModel`,
/// no delivery API, no dose-path logic — maps an already-resolved `Signal` to display text.
/// Amount-stating templates in `banner(for:)` are experimental-distribution copy, not the
/// signed-off `RegulatoryCopy` set.

/// A resolved bolus outcome banner: two lines of already-formatted display text plus a `kind` the
/// view uses to pick its icon/tint. `nil` from `BolusConfirmation.banner` means "show nothing" — there
/// is no "banner but hidden" state.
struct BolusSuccessBanner: Equatable {
    /// `.warning` is the truthful non-success banner (failed/indeterminate);
    /// `.success` is the original delivered banner. Never inferred from the text — set explicitly by
    /// `banner(for:)` alongside the `Signal` it resolved.
    enum Kind: Equatable { case success, warning }
    let kind: Kind
    let primary: String
    let secondary: String
    /// Per-presentation identity. `BolusEntryView.present(_:)` must compare this token, not content
    /// equality — two back-to-back deliveries of the same amount are byte-identical in
    /// `kind`/`primary`/`secondary`, so a content-`==` check would let the first timer dismiss the
    /// second toast. Defaulted so `BolusConfirmation.banner(...)`'s memberwise init stays unchanged.
    let token = UUID()

    /// Content equality only — `token` is excluded so consumers comparing displayed content keep
    /// working. `present(_:)` compares `token` explicitly.
    static func == (lhs: BolusSuccessBanner, rhs: BolusSuccessBanner) -> Bool {
        lhs.kind == rhs.kind && lhs.primary == rhs.primary && lhs.secondary == rhs.secondary
    }
}

/// Maps an already-resolved bolus outcome to display text. Never synthesizes "delivered" for a
/// pending outcome, and never a silent banner once the caller knows what happened.
enum BolusConfirmation {
    /// Outcomes from the caller's already-known `lastError` — this type never inspects
    /// `AppModel` itself.
    enum Signal {
        /// Blocked / indeterminate / failed / rejected / timed out. A supplied `message`
        /// (`AppModel.lastError`) becomes a warning banner so a non-success is never silent; omit it
        /// to stay silent. Failed vs indeterminate stays in `AppModel` — this type does not split them.
        case failed
        /// The bolus actually completed with `lastError == nil` and no pending approval. The ONLY
        /// signal that produces a `.success` banner.
        case delivered
    }

    /// Extended (combo) bolus detail for the "{now} U now, {total} U total over {duration} min"
    /// secondary line. `nil` (the default) means a standard bolus.
    struct ExtendedDetail {
        let nowUnits: Double
        let totalUnits: Double
        let durationMinutes: Int
    }

    /// `units` is the frozen total units the pump was actually sent (standard bolus amount, or the
    /// extended bolus's total). Formatting uses the repo's existing `String(format: "%.2f U", ...)`
    /// convention. `message` is the caller's already-resolved
    /// non-success copy (`model.lastError`) — only consulted for `.failed`; omitting it (the default)
    /// preserves the original silent behavior for callers that haven't been updated yet.
    static func banner(
        for signal: Signal, units: Double, extended: ExtendedDetail? = nil,
        message: String? = nil
    ) -> BolusSuccessBanner? {
        switch signal {
        case .failed:
            // Fail-closed: no message means nothing truthful to show yet — stay silent rather than
            // invent an empty/generic warning.
            guard let message else { return nil }
            return BolusSuccessBanner(
                kind: .warning, primary: String(localized: "Bolus not delivered"),
                secondary: message)
        case .delivered:
            // Catalog whole phrases; pre-render `"%.2f U"` / `"%d min"` and interpolate as `%@`
            // so Localizable never owns a raw numeric-format specifier.
            let primary = String(localized: "Bolus delivered")
            let secondary: String
            if let extended {
                secondary = String(
                    format: String(localized: "%@ now, %@ total over %@"),
                    String(format: "%.2f U", extended.nowUnits),
                    String(format: "%.2f U", extended.totalUnits),
                    String(format: "%d min", extended.durationMinutes))
            } else {
                secondary = String(format: String(localized: "%@ delivered"), String(format: "%.2f U", units))
            }
            return BolusSuccessBanner(kind: .success, primary: primary, secondary: secondary)
        }
    }
}

/// Transient toast. Uses plain `Color.green` / `Color.orange` — never `AppTheme.inRange` /
/// glucose-band tokens — so a bolus outcome cannot be read as a clinical range. Owns no delivery
/// state; renders the strings and kind it's given.
struct BolusSuccessBannerView: View {
    let banner: BolusSuccessBanner

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: banner.kind == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.kind == .warning ? Color.orange : Color.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.primary).font(.headline)
                Text(banner.secondary).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding().frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
