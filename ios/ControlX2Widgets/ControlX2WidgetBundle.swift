import WidgetKit
import SwiftUI

// ControlX2 widgets: Lock Screen (accessory) + Home Screen views of pump state read from the
// App Group, plus a tap-to-bolus shortcut that deep-links into the app's confirm flow. Widgets
// can't drive Bluetooth, so they show the last value the app published, with an age.
@main
struct ControlX2WidgetBundle: WidgetBundle {
    var body: some Widget {
        GlucoseWidget()   // BG + trend (Lock Screen + Home Screen small)
        StatusWidget()    // Overview (Home Screen medium)
        BolusWidget()     // Tap-to-bolus shortcut
    }
}

// MARK: - Timeline

struct ControlX2Entry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

/// Reads the latest published snapshot from the App Group. WidgetKit reloads when the app calls
/// `reloadAllTimelines()`; the `.after` policy is a fallback so a stale widget still ages out.
struct ControlX2Provider: TimelineProvider {
    func placeholder(in context: Context) -> ControlX2Entry {
        ControlX2Entry(date: Date(), snap: .placeholder)
    }
    func getSnapshot(in context: Context, completion: @escaping (ControlX2Entry) -> Void) {
        completion(current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ControlX2Entry>) -> Void) {
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [current()], policy: .after(next)))
    }
    private func current() -> ControlX2Entry {
        ControlX2Entry(date: Date(), snap: WidgetStore.load() ?? .placeholder)
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
    static func glucoseText(_ snap: WidgetSnapshot) -> String {
        guard let g = snap.glucose else { return "--" }
        return "\(g)"
    }
    /// True when the reading is old enough to flag (CGM updates ~every 5 min).
    static func isStale(_ snap: WidgetSnapshot) -> Bool {
        Date().timeIntervalSince(snap.updatedAt) > 12 * 60
    }
}
