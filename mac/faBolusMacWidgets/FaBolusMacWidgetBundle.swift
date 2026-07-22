import WidgetKit
import SwiftUI
import AppIntents

// faBolus macOS widgets: desktop / Notification Center views of the pump state the Mac app relays
// from the iPhone into the App Group, plus an interactive quick-bolus (macOS 14+). Widgets read the
// last snapshot the Mac app published; the quick-bolus relays through the app to the phone.
@main
struct FaBolusMacWidgetBundle: WidgetBundle {
    var body: some Widget {
        MacGlucoseWidget()
        MacStatusWidget()
        MacQuickBolusWidget()
    }
}

// MARK: - Timeline

struct MacWidgetEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct MacWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacWidgetEntry { MacWidgetEntry(date: Date(), snap: .placeholder) }
    func getSnapshot(in context: Context, completion: @escaping (MacWidgetEntry) -> Void) { completion(current()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MacWidgetEntry>) -> Void) {
        let snap = WidgetStore.load() ?? .placeholder
        let now = Date()
        // Extra entries at the stale/hide crossings so the widget greys/hides at the right moment
        // (the view reads each entry's date, not wall-clock, since a widget renders ahead of time).
        var dates: [Date] = [now]
        if let d = snap.glucoseDate {
            let stale = d.addingTimeInterval(snap.staleAfterSec ?? 6 * 60)
            if stale > now { dates.append(stale) }
            if let hide = snap.hideAfterSec {
                let hideAt = d.addingTimeInterval(max(hide, snap.staleAfterSec ?? 6 * 60))
                if hideAt > now { dates.append(hideAt) }
            }
        }
        dates.append(now.addingTimeInterval(15 * 60))
        let entries = Set(dates).sorted().map { MacWidgetEntry(date: $0, snap: snap) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
    private func current() -> MacWidgetEntry { MacWidgetEntry(date: Date(), snap: WidgetStore.load() ?? .placeholder) }
}

private enum MacWidgetUI {
    static func glucoseColor(_ category: Int) -> Color {
        switch category {
        case 0: return .red; case 1: return .green; case 2: return .yellow; case 3: return .orange
        default: return .gray
        }
    }
    /// Color for the glucose number at `now`, honoring the phone's stale policy + "color by range".
    static func glucoseColor(_ snap: WidgetSnapshot, now: Date) -> Color {
        if snap.isStale(asOf: now) { return .secondary }
        return DisplaySettings.widgetColorByRange ? glucoseColor(snap.rangeCategory) : .primary
    }
    /// Glucose number to show at `now`: value while fresh/stale (greyed via color), "--" when hidden.
    static func glucoseText(_ snap: WidgetSnapshot, now: Date) -> String {
        if snap.isHidden(asOf: now) { return "--" }
        guard let g = snap.glucose, g > 0 else { return "--" }
        return "\(g)"
    }
}

// MARK: - Glucose

struct MacGlucoseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FaBolusMacGlucose", provider: MacWidgetProvider()) { entry in
            MacGlucoseView(snap: entry.snap, now: entry.date)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Glucose")
        .description("Current glucose + trend, relayed from your iPhone.")
        .supportedFamilies([.systemSmall])
    }
}

struct MacGlucoseView: View {
    let snap: WidgetSnapshot
    let now: Date
    var body: some View {
        let hidden = snap.isHidden(asOf: now)
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(MacWidgetUI.glucoseText(snap, now: now))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(MacWidgetUI.glucoseColor(snap, now: now))
                if !hidden {
                    Text(snap.trendArrow).font(.title).foregroundStyle(.secondary)
                }
            }
            if let d = snap.glucoseDate {
                Text(d, style: .relative).font(.caption2).foregroundStyle(.secondary)  // live "5 min" age
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Status (pills + sparkline)

struct MacStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FaBolusMacStatus", provider: MacWidgetProvider()) { entry in
            MacStatusWidgetView(snap: entry.snap, now: entry.date)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Status")
        .description("Glucose, IOB, reservoir, battery + a recent sparkline.")
        .supportedFamilies([.systemMedium])
    }
}

struct MacStatusWidgetView: View {
    let snap: WidgetSnapshot
    let now: Date
    /// Reservoir and/or battery on one line, per the user's toggles (nil if both are off).
    private var reservoirBatteryLine: String? {
        var parts: [String] = []
        if DisplaySettings.showReservoir { parts.append(String(format: "Reservoir %.0f U", snap.reservoirUnits)) }
        if DisplaySettings.showBattery { parts.append("\(snap.batteryPercent)%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(MacWidgetUI.glucoseText(snap, now: now)).font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(MacWidgetUI.glucoseColor(snap, now: now))
                    if !snap.isHidden(asOf: now) {
                        Text(snap.trendArrow).font(.title2).foregroundStyle(.secondary)
                    }
                }
                if let d = snap.glucoseDate {
                    Text(d, style: .relative).font(.caption2).foregroundStyle(.secondary)  // live age
                }
                if DisplaySettings.showIOB {
                    Text(String(format: "IOB %.2f U", snap.iobUnits)).font(.caption)
                }
                if let line = reservoirBatteryLine {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            Sparkline(points: snap.recentPoints)
                .frame(maxWidth: .infinity, maxHeight: 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Minimal glucose sparkline (oldest→newest).
struct Sparkline: View {
    let points: [WidgetSnapshot.Point]
    var body: some View {
        GeometryReader { geo in
            let values = points.map(\.mgdl)
            if values.count > 1 {
                let lo = Double(values.min() ?? 0), hi = Double(values.max() ?? 1)
                let span = max(hi - lo, 1)
                Path { p in
                    for (i, v) in values.enumerated() {
                        let x = geo.size.width * Double(i) / Double(values.count - 1)
                        let y = geo.size.height * (1 - (Double(v) - lo) / span)
                        let pt = CGPoint(x: x, y: y)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
        }
    }
}

// MARK: - Quick bolus (interactive; mirrors the iOS QuickBolusWidget flow)

struct MacQuickBolusWidget: Widget {
    var body: some WidgetConfiguration {
        // Kind matches the shared intents' reload target so taps refresh the widget in place.
        StaticConfiguration(kind: "FaBolusQuickBolus", provider: MacWidgetProvider()) { entry in
            MacQuickBolusView(snap: entry.snap)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(red: 0.30, green: 0.36, blue: 0.85),
                                            Color(red: 0.22, green: 0.26, blue: 0.72)],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("Quick Bolus")
        .description("Set an amount and deliver with a 1-2-3 confirm — relayed to your iPhone.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct MacQuickBolusView: View {
    let snap: WidgetSnapshot
    private var stage: String { WidgetBolusStore.stage }
    private var mode: String { WidgetBolusStore.mode }
    private var draft: Double { WidgetBolusStore.draft }
    private var progress: Int { WidgetBolusStore.progress() }
    private var status: WidgetBolusStatus { WidgetBolusStore.status() }
    private var amountLabel: String { mode == "carbs" ? "\(Int(draft)) g" : String(format: "%.2f U", draft) }

    var body: some View {
        VStack(spacing: 6) {
            switch status.phase {
            case .delivering: deliveringBody
            case .delivered:  doneBody(icon: "checkmark.circle.fill",
                                       text: String(format: "Delivered %.2f U", status.deliveredUnits))
            case .cancelled:  doneBody(icon: "xmark.circle.fill",
                                       text: String(format: "Cancelled · %.2f U", status.deliveredUnits))
            case .failed:     doneBody(icon: "exclamationmark.triangle.fill",
                                       text: status.message.isEmpty ? "Bolus failed" : status.message)
            case .idle:
                if !snap.connected { notConnectedBody }
                else if stage == "confirm" { confirmBody }
                else { amountBody }
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var amountBody: some View {
        Button(intent: WidgetBolusToggleModeIntent()) {
            HStack(spacing: 3) {
                Text(mode == "carbs" ? "Carbs" : "Units").font(.caption.weight(.semibold))
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 9, weight: .bold))
            }.foregroundStyle(.white.opacity(0.9))
        }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 6) {
            stepper(delta: -1, symbol: "minus")
            Text(amountLabel).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                .minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity)
            stepper(delta: 1, symbol: "plus")
        }
        Button(intent: WidgetBolusBeginConfirmIntent()) {
            Text("Bolus").font(.subheadline.weight(.bold))
                .foregroundStyle(draft > 0 ? Color(red: 0.24, green: 0.28, blue: 0.75) : .white.opacity(0.5))
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(draft > 0 ? Color.white : Color.white.opacity(0.15), in: Capsule())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var confirmBody: some View {
        HStack(spacing: 4) {
            Button(intent: WidgetBolusBackIntent()) {
                Image(systemName: "chevron.left").foregroundStyle(.white.opacity(0.8))
            }.buttonStyle(.plain)
            Text(amountLabel).font(.headline).foregroundStyle(.white).minimumScaleFactor(0.5).lineLimit(1)
            Spacer()
        }
        Text(progress == 0 ? "Tap 1 · 2 · 3" : "Confirming… \(progress)/3")
            .font(.caption2).foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 8) { stepButton(1); stepButton(2); stepButton(3) }
    }

    @ViewBuilder private var deliveringBody: some View {
        HStack(spacing: 5) {
            ProgressView().tint(.white).scaleEffect(0.8)
            Text(String(format: "Delivering %.2f U", status.units))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Spacer(minLength: 0)
        Button(intent: WidgetBolusCancelIntent()) {
            Text("Cancel").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(Color.red.opacity(0.9), in: Capsule())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func doneBody(icon: String, text: String) -> some View {
        Spacer(minLength: 0)
        Image(systemName: icon).font(.title2).foregroundStyle(.white)
        Text(text).font(.caption).foregroundStyle(.white).multilineTextAlignment(.center).frame(maxWidth: .infinity)
        Spacer(minLength: 0)
    }

    @ViewBuilder private var notConnectedBody: some View {
        Spacer(minLength: 0)
        VStack(spacing: 4) {
            Image(systemName: "drop.fill").font(.title3)
            Text("iPhone not connected").font(.caption2).multilineTextAlignment(.center)
        }.foregroundStyle(.white.opacity(0.9)).frame(maxWidth: .infinity)
        Spacer(minLength: 0)
    }

    @ViewBuilder private func stepper(delta: Int, symbol: String) -> some View {
        Button(intent: WidgetBolusAdjustIntent(delta: delta)) {
            Image(systemName: symbol).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(Color.white.opacity(0.18), in: Circle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func stepButton(_ n: Int) -> some View {
        if n == 3 {
            Button(intent: WidgetBolusDeliverIntent()) { circle(n) }.buttonStyle(.plain)
        } else {
            Button(intent: WidgetBolusStepIntent(step: n)) { circle(n) }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private func circle(_ n: Int) -> some View {
        let done = progress >= n
        ZStack {
            Circle().fill(done ? Color.white : Color.white.opacity(0.18))
            Text("\(n)").font(.system(size: 20, weight: .bold))
                .foregroundStyle(done ? Color(red: 0.24, green: 0.28, blue: 0.75) : .white)
        }
        .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
    }
}
