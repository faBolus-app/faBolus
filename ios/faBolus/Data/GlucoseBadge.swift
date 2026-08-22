import Foundation

/// Phase 7 (FEAT-03, D-04 literal no-op stub — owner decision 2026-08-21, 07-OWNER-FLAGS.md FEAT-03
/// RESOLVED). This is a main-only INERT replacement for the real opt-in app-icon glucose badge — the
/// real implementation (a pure freshness function + a badge-count notification-center I/O sink) is
/// `git rm`'d and preserved on `dev/glucose-badge`.
///
/// `apply(_:now:)`/`clear()` do nothing; `value(for:now:)` always returns `0`. This file imports
/// Foundation ONLY — it can never touch the app icon regardless of what
/// `AppSettings.shared.glucoseBadgeEnabled` is set to (including a restored settings backup that
/// still carries `glucoseBadgeEnabled: true`). See `FeatureSurfaceAbsenceGuardTests` for the raw-text
/// guard that keeps this file provably free of any badge I/O sink.
///
/// The stub matches EXACTLY the interface the 2 surviving call sites need (no `setBadge` injection
/// param — that existed only for the now-deleted `BadgePublisherTests`, preserved on
/// `dev/glucose-badge`):
///   - `WidgetPublisher.swift`'s `GlucoseBadge.apply(snap)` (the BLE-publish choke point)
///   - `AppModel.swift:1774`'s `GlucoseBadge.clear()` — the ONE byte-identity-protected call site
///     (`AppModel.swift` is `DOSE_PATHS`); it stays byte-identical, calling this stub's no-op `clear()`.
enum GlucoseBadge {
    /// Always `0` — the badge is permanently inert (FEAT-03). `snap`/`now` are accepted but unused so
    /// the call signature matches the real implementation's exactly.
    @MainActor
    static func value(for snap: WidgetSnapshot, now: Date) -> Int { 0 }

    /// No-op (FEAT-03) — the real I/O sink is removed entirely.
    @MainActor
    static func apply(_ snap: WidgetSnapshot, now: Date = Date()) {}

    /// No-op (FEAT-03).
    @MainActor
    static func clear() {}
}
