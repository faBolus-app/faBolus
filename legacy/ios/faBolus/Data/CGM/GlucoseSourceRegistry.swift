import Foundation
import faBolusCore

/// The compile-time manifest of glucose **failover** sources in this build (iOS has no dynamic
/// plugins, so every source is compiled in and selected at runtime). Mirrors `BackendRegistry`.
/// Add a source by implementing `GlucoseSource` and appending a `GlucoseSourceDescriptor` to
/// `enabled`.
@MainActor
public enum GlucoseSourceRegistry {
    /// Sources compiled into this build. Empty selection = pump-relayed glucose only (no failover).
    /// Currently Dexcom Share (cloud fallback).
    public static let enabled: [GlucoseSourceDescriptor] = {
        var list: [GlucoseSourceDescriptor] = [
            GlucoseSourceDescriptor(
                id: "dexcom-share", name: "Dexcom Share (cloud)",
                sensors: ["Dexcom G6", "Dexcom G7"]
            ) { _ in DexcomShareSource() }
        ]
        return list
    }()

    /// Every descriptor — used for id lookups.
    private static var all: [GlucoseSourceDescriptor] { enabled }

    private static let key = "selectedGlucoseSourceId"

    /// The chosen source id, or nil for "none / pump only".
    public static func selectedId() -> String? { UserDefaults.standard.string(forKey: key) }

    /// Persist the chosen source id (nil clears it). Applied on next launch / re-init. Also clears the
    /// bounded-recovery bookkeeping (the clean-shutdown marker + the persisted
    /// `GlucoseSourceRecoveryState`) so a re-selected source is auto-started again on the next launch —
    /// any earlier unclean-start tally / disable window belonged to whichever source was selected
    /// before, and must never carry over onto a freshly (re-)selected one.
    public static func select(_ id: String?) {
        UserDefaults.standard.set(id, forKey: key)
        UserDefaults.standard.removeObject(forKey: AppModel.sourceCleanShutdownKey)
        clearRecoveryState()
    }

    /// The selected descriptor if it's still available, else nil.
    public static func selected() -> GlucoseSourceDescriptor? {
        guard let id = selectedId() else { return nil }
        return all.first { $0.id == id }
    }

    /// Build the selected source, or nil when none is configured/available. The ONE production
    /// instance — passes `restoreStateEnabled: true`.
    public static func makeSelected() -> GlucoseSource? { selected()?.make(true) }

    /// The descriptor for a specific source id (for the credentials "test all" diagnostic).
    public static func descriptor(id: String) -> GlucoseSourceDescriptor? { all.first { $0.id == id } }
    /// Build a specific source by id (for testing a not-necessarily-selected source). This is the
    /// ephemeral `CgmCredentialsView` "Test" path — always `restoreStateEnabled: false`, so it
    /// can never collide with the production instance's restore identifier.
    ///
    /// Zero remaining production call sites (the live Test flow observes the already-running
    /// `AppModel.glucoseSource` production instance via `glucoseSourceProbe`, never a second
    /// ephemeral central). Kept because tests pin that the by-id build path carries
    /// `restoreStateEnabled: false` — the sole guard against the dup-restore-id SIGABRT. Do NOT
    /// delete without migrating those test call sites in the same change.
    public static func make(id: String) -> GlucoseSource? { descriptor(id: id)?.make(false) }

    // MARK: - Bounded crash-loop recovery persistence

    private static let recoveryStateKey = "glucoseSourceRecoveryState.v1"

    /// The persisted bounded-recovery state, or a fresh (all-zero) one if never written / undecodable.
    public static func loadRecoveryState() -> GlucoseSourceRecoveryState {
        guard let data = UserDefaults.standard.data(forKey: recoveryStateKey),
            let decoded = try? JSONDecoder().decode(GlucoseSourceRecoveryState.self, from: data)
        else { return GlucoseSourceRecoveryState() }
        return decoded
    }

    public static func saveRecoveryState(_ state: GlucoseSourceRecoveryState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: recoveryStateKey)
    }

    public static func clearRecoveryState() {
        UserDefaults.standard.removeObject(forKey: recoveryStateKey)
    }
}

/// Pure, persisted state for the bounded crash-loop recovery policy below. Codable so
/// `GlucoseSourceRegistry` can round-trip it through `UserDefaults` (JSON) across launches.
public struct GlucoseSourceRecoveryState: Equatable, Codable {
    /// Consecutive unclean-start count observed within `GlucoseSourceRecoveryPolicy.uncleanStartWindow`.
    public var uncleanStartCount: Int
    public var lastUncleanStartAt: Date?
    /// Non-nil while failover is disabled; auto-re-probes once `now >= disabledUntil`.
    public var disabledUntil: Date?
    public init(uncleanStartCount: Int = 0, lastUncleanStartAt: Date? = nil, disabledUntil: Date? = nil) {
        self.uncleanStartCount = uncleanStartCount
        self.lastUncleanStartAt = lastUncleanStartAt
        self.disabledUntil = disabledUntil
    }
}

/// **Bounded crash-loop recovery — not a permanent-until-reselect crash guard.**
///
/// iOS cannot reliably tell a benign jetsam/watchdog/OOM background termination apart from a genuine
/// CGM-source crash, so this policy NEVER classifies a termination reason. `AppModel.init` tracks only
/// whether the PREVIOUS run left its clean-shutdown marker (`wasClean` — set on an orderly teardown of
/// the CGM source, cleared at the start of every run; its ABSENCE at the next launch means "ended
/// without cleanup", cause UNKNOWN) and feeds that, plus the persisted `GlucoseSourceRecoveryState`,
/// through this PURE decision function — no `UserDefaults`, no clock read — so the disable/re-probe
/// boundary is unit-testable directly. A SINGLE unclean start (the overwhelmingly common real-world
/// case: the app was simply suspended, then jetsam'd, in the background) NEVER disables failover; only
/// `maxUncleanStartsBeforeDisable` unclean starts within `uncleanStartWindow` do, and even that disable
/// is itself BOUNDED (`disableWindow`) — it auto-re-probes once the window elapses rather than requiring
/// the user to manually re-select the source in Settings forever.
public enum GlucoseSourceRecoveryPolicy {
    /// §13-adjacent starting points — owner-vetoable, NOT clinical constants (mirrors
    /// `DisconnectEscalation`'s own disclaimer for its ladder timings).
    public static let maxUncleanStartsBeforeDisable = 3
    public static let uncleanStartWindow: TimeInterval = 60 * 60
    public static let disableWindow: TimeInterval = 60 * 60

    /// Called at launch, BEFORE starting the source. Returns the next persisted state AND whether the
    /// source should start THIS launch.
    public static func decide(_ state: GlucoseSourceRecoveryState, wasClean: Bool, now: Date = Date())
        -> (next: GlucoseSourceRecoveryState, shouldStart: Bool)
    {
        var s = state
        if let until = s.disabledUntil, now >= until {
            // The bounded disable window elapsed — auto re-probe: clear the disable AND the tally so the
            // source gets a genuinely fresh bounded window, not one poisoned by the run that tripped it.
            s.disabledUntil = nil
            s.uncleanStartCount = 0
            s.lastUncleanStartAt = nil
        }
        if wasClean {
            // A clean prior shutdown always resets the unclean-run tally — an intermittent, benign
            // termination (a user-initiated quit, a source reselect) must never accumulate toward the
            // disable threshold alongside genuinely-back-to-back crashes.
            s.uncleanStartCount = 0
            s.lastUncleanStartAt = nil
            return (s, s.disabledUntil == nil)
        }
        // Unclean prior run (absence of the clean-shutdown marker) — cause UNKNOWN (jetsam / watchdog /
        // OOM / crash are all indistinguishable here), so this ONLY ever increments a bounded, windowed
        // tally; it never itself asserts that a crash occurred.
        if let last = s.lastUncleanStartAt, now.timeIntervalSince(last) > uncleanStartWindow {
            s.uncleanStartCount = 0  // an isolated unclean exit outside the window, not a loop
        }
        s.uncleanStartCount += 1
        s.lastUncleanStartAt = now
        if s.uncleanStartCount >= maxUncleanStartsBeforeDisable, s.disabledUntil == nil {
            s.disabledUntil = now.addingTimeInterval(disableWindow)
        }
        return (s, s.disabledUntil == nil)
    }
}
