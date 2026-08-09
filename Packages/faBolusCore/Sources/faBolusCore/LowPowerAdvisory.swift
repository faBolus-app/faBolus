import Foundation

/// P16 F3 — the shared, surface-agnostic decision for the iOS **Low Power Mode** advisory banner.
///
/// **ADVISORY / WARN-ONLY.** This type only decides whether to *tell* the user that iOS Low Power Mode
/// may delay background pump/CGM updates, and supplies the copy. It NEVER changes any poll/scan/timer
/// cadence, NEVER blocks/delays/changes a dose, NEVER gates any control, and NEVER touches delivery.
/// Nothing here reads or mutates cadence — it is a pure presentation predicate.
///
/// The rule is pulled out of the UI so "should the banner show" is unit-testable without SwiftUI.
public enum LowPowerAdvisory {

    /// Whether the phone Dashboard should show the Low Power Mode advisory. Shown only when ALL hold:
    ///   - `lpmActive` — iOS Low Power Mode is on, AND
    ///   - `sourceConnected` — there is a live source (a connected pump/CGM) whose *background* updates
    ///     Low Power Mode would delay; suppressed when idle so the banner isn't noise, AND
    ///   - `!dismissedEpisode` — the user hasn't dismissed the banner for the CURRENT Low Power Mode
    ///     episode (dismissal is per-episode; it re-shows if Low Power Mode toggles off→on again).
    ///
    /// Pure — no globals, no side effects, and it can never alter cadence or gate anything.
    public static func shouldWarn(lpmActive: Bool, sourceConnected: Bool, dismissedEpisode: Bool) -> Bool {
        lpmActive && sourceConnected && !dismissedEpisode
    }

    /// The advisory copy every surface shows — factual, and deliberately worded so it never implies a
    /// dosing action (it points the user at refreshing the app or turning Low Power Mode off).
    public static let message =
        "Low Power Mode is on — iOS may delay background pump/CGM updates. "
        + "Open faBolus to refresh, or turn off Low Power Mode."
}
