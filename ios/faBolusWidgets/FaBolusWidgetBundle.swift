import WidgetKit
import SwiftUI

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
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [current()], policy: .after(next)))
    }
    private func current() -> FaBolusEntry {
        FaBolusEntry(date: Date(), snap: WidgetStore.load() ?? .placeholder)
    }
}

// MARK: - Shared UI helpers

enum WidgetUI {
    static func glucoseColor(_ category: Int) -> Color {
        switch category {
        case 0: return .red        // low
        case 1: return .green      // in range
        case 2: return .yellow     // high
        case 3: return .orange     // urgent high
        default: return .gray      // unknown
        }
    }
    static func glucoseText(_ snap: WidgetSnapshot) -> String { snap.displayGlucose }
    /// True when the reading is older than 6 minutes (hide the number).
    static func isStale(_ snap: WidgetSnapshot) -> Bool { snap.isGlucoseStale }
}
