import WidgetKit
import SwiftUI
import faBolusCore
import faBolusDesign

// FaBolus widgets: Lock Screen (accessory) + Home Screen views of pump state read from the
// App Group, plus a tap-to-bolus shortcut that deep-links into the app's confirm flow. Widgets
// can't drive Bluetooth, so they show the last value the app published, with an age.
@main
struct FaBolusWidgetBundle: WidgetBundle {
    var body: some Widget {
        GlucoseWidget()   // BG + trend (Lock Screen + Home Screen small)
        StatusWidget()    // Overview (Home Screen medium)
        BolusWidget()     // Tap-to-bolus shortcut (deep-links into the app)
        QuickBolusWidget() // Preset bolus with a 1-2-3 confirm (delivers via the app)
    }
}

// MARK: - Timeline

struct FaBolusEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

/// Reads the latest published snapshot from the App Group. WidgetKit reloads when the app calls
/// `reloadAllTimelines()`; the `.after` policy is a fallback so a stale widget still ages out.
struct FaBolusProvider: TimelineProvider {
    func placeholder(in context: Context) -> FaBolusEntry {
        FaBolusEntry(date: Date(), snap: .placeholder)
    }
    func getSnapshot(in context: Context, completion: @escaping (FaBolusEntry) -> Void) {
        completion(current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FaBolusEntry>) -> Void) {
        let snap = WidgetStore.load() ?? .placeholder
        let now = Date()
        // Extra entries at the stale/hide crossings so the widgets grey/hide at the
        // right moment. A widget renders ahead of time, so each view keys off its ENTRY's date (not
        // wall-clock); without crossing entries a fresh entry never re-rendered into its stale/hidden
        // state until the next app reload.
        var dates: [Date] = [now]
        if let d = snap.glucoseDate {
            let stale = d.addingTimeInterval(snap.staleAfterSec ?? 6 * 60)
            if stale > now { dates.append(stale) }
            if let hide = snap.hideAfterSec {
                let hideAt = d.addingTimeInterval(max(hide, snap.staleAfterSec ?? 6 * 60))
                if hideAt > now { dates.append(hideAt) }
            }
        }
        let fallback = now.addingTimeInterval(15 * 60)
        dates.append(fallback)
        let entries = Set(dates).sorted().map { FaBolusEntry(date: $0, snap: snap) }
        completion(Timeline(entries: entries, policy: .after(fallback)))
    }
    private func current() -> FaBolusEntry {
        FaBolusEntry(date: Date(), snap: WidgetStore.load() ?? .placeholder)
    }
}

// MARK: - Shared UI helpers

enum WidgetUI {
    static func glucoseText(_ snap: WidgetSnapshot) -> String { snap.displayGlucose }
    /// True when the reading is older than 6 minutes (hide the number).
    static func isStale(_ snap: WidgetSnapshot) -> Bool { snap.isGlucoseStale }

    // `now`-parameterized variants honoring the phone's PUBLISHED freshness policy,
    // evaluated at the widget entry's date (a widget renders ahead of time, so wall-clock `Date()` is
    // prep time, not display time). Band-color derivation lives at the call sites
    // (`GlucoseWidgetView.color`, `StatusWidgetView.color`), which classify via
    // `faBolusCore.GlucoseRange.classify` and color via `faBolusDesign.AppTheme.glucoseColor(_:stale:)`
    // directly — no local `Int`-category switch remains in this file.
    /// Glucose number at `now`: the value while fresh/stale, "--" once hidden past the policy.
    static func glucoseText(_ snap: WidgetSnapshot, now: Date) -> String {
        if snap.isHidden(asOf: now) { return "--" }
        guard let g = snap.glucose, g > 0 else { return "--" }
        return "\(g)"
    }
    /// Stale at `now` (de-emphasize + drop the trend arrow), per the published policy.
    static func isStale(_ snap: WidgetSnapshot, now: Date) -> Bool { snap.isStale(asOf: now) }
}
