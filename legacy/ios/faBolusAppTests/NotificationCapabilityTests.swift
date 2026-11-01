import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// The time-sensitive capability SIGNAL source: `scripts/generate-project.sh`'s `TIME_SENSITIVE`
/// path sets the `FABOLUS_TIME_SENSITIVE` compile condition, and `NotificationCapability` exposes
/// it as a readable runtime flag. Observation only — no app behavior is gated on it beyond
/// feeding the unified resolver's `timeSensitiveAvailable` input.
@Suite struct NotificationCapabilityTests {
    @Test func theAccessorReflectsTheBuildsActiveConfigMarker() {
        #if FABOLUS_TIME_SENSITIVE
        #expect(NotificationCapability.timeSensitiveAvailable == true)
        #else
        #expect(
            NotificationCapability.timeSensitiveAvailable == false,
            "the default main build (capability absent) must read false and still compile/run")
        #endif
    }

    @Test func theResolverCallSiteIsWiredToTheRealAccessor_atBothExplicitStates() {
        let rules = NotificationRules.Cascade(category: .init(intent: .urgent))

        // Omitting the parameter picks up the accessor's CURRENT value — proving the call site
        // reads the real signal rather than a hardcoded literal.
        let wired = RemoteStatusComposer.pumpMirrorWatchIntent(rules: rules)
        let direct = NotificationRules.resolve(
            rules, timeSensitiveAvailable: NotificationCapability.timeSensitiveAvailable
        ).watch
        #expect(wired == direct)

        // The helper still honors an EXPLICIT override at both capability states (Decision 3: the
        // capability is never a gate — a caller may always supply either state deliberately).
        let entitled = RemoteStatusComposer.pumpMirrorWatchIntent(rules: rules, timeSensitiveAvailable: true)
        #expect(entitled == NotificationRules.resolve(rules, timeSensitiveAvailable: true).watch)
        let unentitled = RemoteStatusComposer.pumpMirrorWatchIntent(rules: rules, timeSensitiveAvailable: false)
        #expect(unentitled == NotificationRules.resolve(rules, timeSensitiveAvailable: false).watch)
    }
}
