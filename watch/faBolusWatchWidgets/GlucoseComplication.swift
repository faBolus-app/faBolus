import WidgetKit
import SwiftUI

/// Watch-face complication showing the latest glucose + trend, mirroring the Garmin complication.
/// Reads the snapshot the watch app publishes to the App Group (WatchConnectivity → WidgetStore);
/// the watch can't drive Bluetooth, so it shows the last value and hides anything older than 6 min.
@main
struct FaBolusWatchWidgetBundle: WidgetBundle {
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
        let snap = WidgetStore.load() ?? .placeholder
        let now = Date()
        // P10 (group A) — entries at the stale/hide crossings so the complication greys/hides at the
        // right moment; a complication renders ahead of time, so the view keys off each ENTRY's date,
        // not wall-clock. Mirrors the iOS + Mac providers. The 5-min fallback still ages it out if the
        // app never pushes.
        var dates: [Date] = [now]
        if let d = snap.glucoseDate {
            let stale = d.addingTimeInterval(snap.staleAfterSec ?? 6 * 60)
            if stale > now { dates.append(stale) }
            if let hide = snap.hideAfterSec {
                let hideAt = d.addingTimeInterval(max(hide, snap.staleAfterSec ?? 6 * 60))
                if hideAt > now { dates.append(hideAt) }
            }
        }
        let fallback = now.addingTimeInterval(5 * 60)
        dates.append(fallback)
        let entries = Set(dates).sorted().map { GlucoseEntry(date: $0, snap: snap) }
        completion(Timeline(entries: entries, policy: .after(fallback)))
    }
}

struct GlucoseComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FaBolusGlucose", provider: GlucoseProvider()) { entry in
            GlucoseComplicationView(snap: entry.snap, now: entry.date)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Glucose")
        .description("Current glucose + trend from faBolus.")
        .supportedFamilies(Self.supportedFamilies)
    }

    /// `.accessoryCorner` is watchOS-only; keep it out when this file is compiled against the iOS
    /// SDK (e.g. an `-sdk iphonesimulator` build of the whole scheme) so it still compiles.
    static var supportedFamilies: [WidgetFamily] {
        #if os(watchOS)
        [.accessoryCircular, .accessoryInline, .accessoryCorner, .accessoryRectangular]
        #else
        [.accessoryCircular, .accessoryInline, .accessoryRectangular]
        #endif
    }
}

private func color(_ snap: WidgetSnapshot, now: Date) -> Color {
    guard let g = snap.glucose, g > 0, !snap.isStale(asOf: now) else { return .gray }
    // Delegate the band split to the single WidgetSnapshot classifier (WidgetGlucoseThresholds bounds).
    switch WidgetSnapshot.rangeCategory(g) {
    case 0: return .red; case 1: return .green; case 2: return .yellow; default: return .orange
    }
}

struct GlucoseComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let snap: WidgetSnapshot
    /// Entry display date — staleness is evaluated against this, not wall-clock (see the iOS widgets).
    var now: Date = Date()

    // P10 (group A): honor the published freshness policy at the entry date (grey once stale, "--" once
    // hidden), consistent with the iOS + Mac widgets — instead of the old 6-min wall-clock hardcode.
    private var value: String {
        if snap.isHidden(asOf: now) { return "--" }
        guard let g = snap.glucose, g > 0 else { return "--" }
        return "\(g)"
    }
    private var arrow: String { snap.isStale(asOf: now) ? "" : snap.trendArrow }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("\(value) \(arrow)")
        #if os(watchOS)
        case .accessoryCorner:
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color(snap, now: now))
                .widgetLabel { Text("Glucose \(value) \(arrow)") }
        #endif
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(color(snap, now: now))
                VStack(alignment: .leading) {
                    Text(arrow.isEmpty ? "—" : arrow)
                    // Sample age (orange once stale), replacing a static "mg/dL" — so a stale relay is
                    // visible on the wrist, matching the iOS + Mac widgets (group A / C7).
                    if let d = snap.glucoseDate {
                        Text(d, style: .relative).font(.caption2)
                            .foregroundStyle(snap.isStale(asOf: now) ? .orange : .secondary)
                    } else {
                        Text("mg/dL").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        default: // accessoryCircular
            VStack(spacing: 0) {
                Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(color(snap, now: now))
                if !arrow.isEmpty { Text(arrow).font(.caption2) }
            }
        }
    }
}
