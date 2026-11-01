/// The build's time-sensitive capability SIGNAL: whether THIS build carries the
/// `com.apple.developer.usernotifications.time-sensitive` entitlement, set by
/// `scripts/generate-project.sh`'s `TIME_SENSITIVE` path via the `FABOLUS_TIME_SENSITIVE` compile
/// condition (mirroring the `GARMIN` / `FABOLUS_TEMPRATE_CIQ_EXPERIMENTAL` compile-flag idiom).
///
/// OBSERVATION ONLY: this feeds the unified notification-rules resolver's
/// `timeSensitiveAvailable` input (the capability is never a gate — when absent, the resolver's
/// Urgent rung is hidden rather than silently degraded). No other app behavior reads it.
enum NotificationCapability {
    /// `true` only on a build carrying the time-sensitive entitlement (`FABOLUS_TIME_SENSITIVE=1`
    /// at generation time); `false` on the default main build, where the entitlement is stripped
    /// from the generated spec and iOS would silently downgrade `.timeSensitive` to `.active`
    /// anyway.
    static var timeSensitiveAvailable: Bool {
        #if FABOLUS_TIME_SENSITIVE
            return true
        #else
            return false
        #endif
    }
}
