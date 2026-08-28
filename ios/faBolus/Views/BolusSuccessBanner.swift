import SwiftUI
import Foundation

/// Transient advisory confirmation for the embedded BolusEntryView. Pure display: no `AppModel`,
/// no delivery API, no dose-path logic — maps an already-resolved `Signal` to display text.
///
/// §13 NOTICE: the amount-stating copy templates in `BolusConfirmation.banner(for:units:extended:)`
/// are DRAFT experimental-distribution surface and must pass owner/clinical review before an
/// `experimental` build is distributed. Deliberately not added to `RegulatoryCopy.swift` (already
/// signed-off).

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
    /// A per-presentation identity assigned at construction. The
    /// auto-dismiss guard in `BolusEntryView.present(_:)` must compare THIS token, not full-value
    /// equality — two back-to-back deliveries of the same amount produce byte-identical
    /// `kind`/`primary`/`secondary`, so a content-`==` check would let the FIRST banner's timer
    /// dismiss the SECOND (distinct) presentation early. Defaulted so the memberwise initializer used
    /// by `BolusConfirmation.banner(...)` is unchanged.
    let token = UUID()

    /// Content equality (kind/primary/secondary) only — `token` is deliberately EXCLUDED so any
    /// consumer comparing banners by displayed content keeps working. `present(_:)` compares `token`
    /// explicitly for its identity check; nothing relies on two constructions being `==` by token.
    static func == (lhs: BolusSuccessBanner, rhs: BolusSuccessBanner) -> Bool {
        lhs.kind == rhs.kind && lhs.primary == rhs.primary && lhs.secondary == rhs.secondary
    }
}

/// Pure, dependency-free mapping from an ALREADY-RESOLVED bolus outcome to display text. NEVER
/// synthesizes a "delivered" banner for a pending outcome, and NEVER synthesizes a banner at all
/// unless the caller supplies real information to show — a truthful confirmation, never a false
/// one, and never a SILENT one either once the caller knows what happened.
enum BolusConfirmation {
    /// The three outcomes a bolus attempt can resolve to, from the caller's ALREADY-KNOWN
    /// `model.lastError` / `model.pendingApproval` state (see `BolusEntryView.deliverFrozen` and its
    /// `.onChange(of: model.pendingApproval)` handler) — this type never inspects `AppModel` itself.
    enum Signal {
        /// Awaiting remote (child-mode) approval — `pendingApproval != nil`. NEVER a banner.
        case staged
        /// Blocked / indeterminate / failed / rejected / timed out. When the
        /// caller supplies a `message` (AppModel's already-accurate `lastError`, which covers BOTH the
        /// failed and the indeterminate case), this now produces a
        /// truthful WARNING banner carrying that message, closing the visible silent-outcome asymmetry
        /// without a new `.indeterminate` case (that distinction lives in frozen `AppModel` only).
        case failed
        /// The bolus actually completed with `lastError == nil` and no pending approval. The ONLY
        /// signal that produces a `.success` banner.
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
    /// convention. `message` is the caller's already-resolved
    /// non-success copy (`model.lastError`) — only consulted for `.failed`; omitting it (the default)
    /// preserves the original silent behavior for callers that haven't been updated yet.
    static func banner(
        for signal: Signal, units: Double, extended: ExtendedDetail? = nil,
        message: String? = nil
    ) -> BolusSuccessBanner? {
        switch signal {
        case .staged:
            return nil
        case .failed:
            // Fail-closed: no message means the caller has nothing truthful to show yet — stay silent
            // rather than show an empty/generic warning (mirrors the original "never a false banner"
            // property, applied to "never an empty one" too).
            guard let message else { return nil }
            return BolusSuccessBanner(
                kind: .warning, primary: String(localized: "Bolus not delivered"),
                secondary: message)
        case .delivered:
            // Route the delivered-amount/combo templates through Localizable.xcstrings. Numeric
            // formatting (`"%.2f U"`/`"%d min"`) is pre-rendered into plain strings and interpolated as
            // `%@` — the same "%@ mg/dL"-style idiom `StatsCardView.glucoseLabel` already uses — so the
            // catalog carries the surrounding phrase, not a raw numeric-format specifier.
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

/// The transient toast itself — `.success` shows a `checkmark.circle.fill` in plain `Color.green` (NOT
/// `AppTheme.inRange`, see the file-level note above); `.warning` shows an
/// `exclamationmark.triangle.fill` in plain `Color.orange` — same reasoning: a plain system color, not
/// a semantic design-system token, so this bolus-outcome affordance never collides with a clinical
/// glucose-band color. Both share the same `.headline`/`.subheadline` text and `thinMaterial`
/// rounded-card chrome. This view owns no delivery
/// state — it only renders the strings (and kind) it's given.
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
