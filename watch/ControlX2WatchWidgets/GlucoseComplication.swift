import WidgetKit
import SwiftUI

/// Watch-face complication showing the latest glucose + trend, mirroring the Garmin complication.
/// Reads the snapshot the watch app publishes to the App Group (WatchConnectivity → WidgetStore);
/// the watch can't drive Bluetooth, so it shows the last value and hides anything older than 6 min.
@main
struct ControlX2WatchWidgetBundle: WidgetBundle {
    var body: some Widget { GlucoseComplication() }
}

struct GlucoseEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct GlucoseProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlucoseEntry { GlucoseEntry(date: Date(), snap: .placeholder) }
    func getSnapshot(in context: Context, completion: @escaping (GlucoseEntry) -> Void) {
        completion(GlucoseEntry(date: Date(), snap: WidgetStore.load() ?? .placeholder))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<GlucoseEntry>) -> Void) {
        let entry = GlucoseEntry(date: Date(), snap: WidgetStore.load() ?? .placeholder)
        // Re-render every 5 min so the reading ages out to "--" even if the app doesn't push.
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct GlucoseComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ControlX2Glucose", provider: GlucoseProvider()) { entry in
            GlucoseComplicationView(snap: entry.snap)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Glucose")
        .description("Current glucose + trend from ControlX2.")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryCorner, .accessoryRectangular])
    }
}

private func color(_ snap: WidgetSnapshot) -> Color {
    guard let g = snap.glucose, !snap.isGlucoseStale else { return .gray }
    switch g { case ..<70: return .red; case 70..<180: return .green; case 180..<250: return .yellow; default: return .orange }
}

struct GlucoseComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let snap: WidgetSnapshot

    private var value: String { snap.displayGlucose }
    private var arrow: String { snap.isGlucoseStale ? "" : snap.trendArrow }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("\(value) \(arrow)")
        case .accessoryCorner:
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color(snap))
                .widgetLabel { Text("Glucose \(value) \(arrow)") }
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(color(snap))
                VStack(alignment: .leading) {
                    Text(arrow.isEmpty ? "—" : arrow)
                    Text("mg/dL").font(.caption2).foregroundStyle(.secondary)
                }
            }
        default: // accessoryCircular
            VStack(spacing: 0) {
                Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(color(snap))
                if !arrow.isEmpty { Text(arrow).font(.caption2) }
            }
        }
    }
}
