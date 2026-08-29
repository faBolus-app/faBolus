import Foundation

/// Inert replacement for the opt-in app-icon glucose badge. The real implementation (a pure
/// freshness function + a badge-count notification-center I/O sink) is preserved on `dev/glucose-badge`.
///
/// `apply(_:now:)`/`clear()` do nothing; `value(for:now:)` always returns `0`. This file imports
/// Foundation ONLY — it can never touch the app icon regardless of what
/// `AppSettings.shared.glucoseBadgeEnabled` is set to (including a restored settings backup that
/// still carries `glucoseBadgeEnabled: true`).
///
/// The stub matches the interface the surviving call sites need:
///   - `WidgetPublisher.swift`'s `GlucoseBadge.apply(snap)` (the BLE-publish choke point)
///   - `AppModel`'s `GlucoseBadge.clear()` — the call site stays, calling this stub's no-op `clear()`.
enum GlucoseBadge {
    /// Always `0` — the badge is permanently inert. `snap`/`now` are accepted but unused so
    /// the call signature matches the real implementation's exactly.
    @MainActor
    static func value(for snap: WidgetSnapshot, now: Date) -> Int { 0 }

    /// No-op — the real I/O sink is removed entirely.
    @MainActor
    static func apply(_ snap: WidgetSnapshot, now: Date = Date()) {}

    /// No-op.
    @MainActor
    static func clear() {}
}
