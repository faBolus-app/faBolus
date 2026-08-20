import WidgetKit
import SwiftUI
import faBolusCore
import faBolusDesign

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

struct GlucoseComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let snap: WidgetSnapshot
    /// Entry display date — staleness is evaluated against this, not wall-clock (see the iOS widgets).
    var now: Date = Date()

    /// Phase 04-03: resolve the active display unit from the snapshot (nil ⇒ mgdl). This
    /// complication shows a bare number with no unit label today; the VALUE still converts via the
    /// mirror so it matches the phone even though no suffix is shown.
    private var unit: WidgetGlucoseUnit { WidgetGlucoseUnit(wireToken: snap.displayUnit) }
    // P10 (group A): honor the published freshness policy at the entry date (grey once stale, "--" once
    // hidden), consistent with the iOS + Mac widgets — instead of the old 6-min wall-clock hardcode.
    private var value: String {
        if snap.isHidden(asOf: now) { return "--" }
        guard let g = snap.glucose, g > 0 else { return "--" }
        return unit.format(mgdl: g)
    }
    private var arrow: String { snap.isStale(asOf: now) ? "" : snap.trendArrow }

    /// Number color: gray when unknown/invalid/stale, else via faBolusDesign — byte-identical to the
    /// deleted local switch for every input.
    private var bandColor: Color {
        guard let g = snap.glucose, g > 0, !snap.isStale(asOf: now) else { return .gray }
        return AppTheme.glucoseColor(g)
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            // The single line the system places under the clock — only one leading glyph fits; a
            // neutral drop icon replaces the band glyph (no confusable good/bad symbol here).
            Label("\(value) \(arrow)", systemImage: "drop.fill")
        #if os(watchOS)
        case .accessoryCorner:
            // Extremely tight face (a single glyph in the ring's corner) — no room for a second
            // composed view; the number's own band color remains the sole cue here (UI-SPEC #4).
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(bandColor)
                .widgetLabel { Text("Glucose \(value) \(arrow)") }
        #endif
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(bandColor)
                VStack(alignment: .leading) {
                    Text(arrow.isEmpty ? "—" : arrow)
                    // Sample age (orange once stale), replacing a static "mg/dL" — so a stale relay is
                    // visible on the wrist, matching the iOS + Mac widgets (group A / C7).
                    if let d = snap.glucoseDate {
                        Text(d, style: .relative).font(.caption2)
                            .foregroundStyle(snap.isStale(asOf: now) ? .orange : .secondary)
                    } else if snap.showUnitLabel {
                        // Owner-requested toggle: this fallback caption (no reading yet, so no age to
                        // show) is the only persistent unit caption this complication renders.
                        Text(unit.unitLabel).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        default: // accessoryCircular
            VStack(spacing: 0) {
                Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(bandColor)
                HStack(spacing: 2) {
                    if !arrow.isEmpty { Text(arrow).font(.caption2) }
                }
            }
        }
    }
}
