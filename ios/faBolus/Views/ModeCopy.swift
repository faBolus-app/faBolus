import Foundation
import faBolusCore

// P16 F6 (N13) — localization SEED. The mode/Objectives descriptions, centralised as catalog-backed
// `String(localized:)` values so the P14 mode slice resolves through `Localizable.xcstrings` (the first
// real String Catalog in the app). This is a MECHANISM seed, not a copy change: the ENGLISH values are
// byte-for-byte the ones previously inlined in `ModeViews.swift`. The rest of that view's copy stays as
// SwiftUI `Text("…")`/`Button("…")`/etc. string literals — those already localize automatically via
// `LocalizedStringKey`, and their keys are seeded in the same catalog. The only strings that did NOT
// auto-localize were these mode descriptions (a plain `String` rendered verbatim), so they are the
// concrete conversion this seed makes explicit.
//
// §13 NOTICE: this wording is DRAFT and is experimental-distribution surface — the mode/Objectives copy
// must pass owner + §13 clinical review (endocrinologist / CDCES) before any `experimental` build is
// distributed (BRANCHES.md §13). Making the copy localizable does NOT alter that gate. `ModeCopyTests`
// asserts each description still resolves to its expected English value (so the slice is real, not an
// empty catalog), exactly as `RegulatoryCopyTests` guards the regulatory copy.
//
// FOLLOW-UP (deferred, owner-vetoable): `AppMode.title` and the other faBolusCore-package strings are
// intentionally NOT localized here. Localizing package strings needs `Package.swift`
// `defaultLocalization` + a `Bundle.module` catalog and is a separate decision; the package stays
// English for now (recommended default: defer).
enum ModeCopy {
    /// One-line description of what each mode adds, shown in the mode picker footer and the
    /// setup-next-step footer. Catalog-backed via `Localizable.xcstrings`.
    static func description(_ mode: AppMode) -> String {
        switch mode {
        case .simple:
            return String(localized: "Just the essentials: glucose and bolus.")
        case .standard:
            return String(localized: "Adds suspend/resume, activity (Sleep/Exercise) modes, and display customization.")
        case .advanced:
            return String(localized: "Adds temp basal, profiles, Control-IQ settings, cartridge & fill, and pump limits — features that change therapy.")
        }
    }
}
