import ActivityKit
import SwiftUI
import WidgetContent
import WidgetKit
import faBolusCore
import faBolusDesign

/// The glucose Live Activity: the Lock Screen card in either style, the Dynamic Island, and a small layout
/// for CarPlay and the Apple Watch. A tap outside a button opens the app. Its buttons (the bolus, the
/// alerts, Cancel) send their taps to the app, which decides everything (`LiveActivityPanelView`). Once
/// the system marks the activity stale (its glucose passed the window, or the app stopped updating it),
/// everything greys.
struct GlucoseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GlucoseActivityAttributes.self) { context in
            ActivityCard(view: LAView(content: context.state, systemStale: context.isStale, now: Date()))
                .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
                .widgetURL(DeepLink.open)
        } dynamicIsland: { context in
            let v = LAView(content: context.state, systemStale: context.isStale, now: Date())
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 6) {
                        v.ageText.font(.caption2).foregroundStyle(v.stale ? .orange : .secondary)
                        if let chip = v.chips.first { ChipView(chip: chip) }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 6) {
                        if let corner = v.topRight {
                            Text(corner).font(.system(size: 15, weight: .bold, design: .rounded))
                        }
                        if let chip = v.chips.dropFirst().first { ChipView(chip: chip) }
                    }
                }
                DynamicIslandExpandedRegion(.center) { v.glucose(size: 34) }
                DynamicIslandExpandedRegion(.bottom) {
                    if let panel = v.activePanel {
                        PanelScreenView(panel: panel, glucose: v)
                    } else {
                        VStack(spacing: 6) {
                            GlucoseCurve(view: v).frame(height: 44)
                            v.idleRow
                        }
                    }
                }
            } compactLeading: {
                CompactLeading(view: v)
            } compactTrailing: {
                CompactTrailing(view: v)
            } minimal: {
                Text(v.glucoseValue).font(.system(.caption, design: .rounded).weight(.bold)).foregroundStyle(
                    v.glucoseColor)
            }
            .widgetURL(DeepLink.open)
        }
        .supplementalActivityFamilies([.small])
    }
}

/// The Lock Screen card (and the Mac menu bar's), or the small layout where buttons don't work.
struct ActivityCard: View {
    let view: LAView
    @Environment(\.activityFamily) private var family

    var body: some View {
        if family == .small { SmallActivityView(view: view) } else { LockScreenView(view: view) }
    }
}

/// The compact view's leading half, in the Dynamic Island and the left of the Mac's menu-bar pill: the
/// glucose, with ⚠ while a pump alert is open.
struct CompactLeading: View {
    let view: LAView

    var body: some View {
        HStack(spacing: 3) {
            if let alerts = view.content.alerts {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                    .foregroundStyle(alerts.topCritical ? AppTheme.low : AppTheme.high)
                    .accessibilityLabel("Pump alert")
            }
            Text(view.glucoseValue).font(.system(.body, design: .rounded).weight(.bold))
                .foregroundStyle(view.glucoseColor)
        }
    }
}

/// The compact view's trailing half: a Live Activity bolus going or just finished, else the user's choice.
struct CompactTrailing: View {
    let view: LAView

    var body: some View {
        if let status = view.compactStatus {
            // An icon says where the bolus stands, so a short dose never reads as cut-off text.
            HStack(spacing: 2) {
                Image(systemName: status.icon).font(.caption2)
                Text(status.text).font(.caption.weight(.semibold))
            }
            .foregroundStyle(status.color).lineLimit(1).fixedSize()
        } else {
            Text(view.compactChoice).foregroundStyle(view.glucoseColor).lineLimit(1)
        }
    }
}

/// One update as the views show it at `now`.
struct LAView {
    let content: LiveActivityContent
    let systemStale: Bool
    let now: Date
    /// Times count on by themselves, as the Live Activity shows them. Off, they read as of `now`, for
    /// snapshots that must render the same every run.
    var ticking = true

    var snapshot: WidgetSnapshot { content.snapshot }

    /// A bolus or alert screen, when one is open: it takes the card's place.
    var activePanel: LiveActivityPanel? {
        guard let panel = content.panel else { return nil }
        if case .idle = panel.view { return nil }
        return panel
    }

    /// A Live Activity bolus's result in a few characters, while it shows.
    var compactStatus: (text: String, icon: String, color: Color)? {
        guard case .result(let r)? = content.panel?.view, let text = r.compact else { return nil }
        switch r.tone {
        case .working: return (text, "drop.fill", AppTheme.insulin)
        case .good: return (text, "checkmark.circle.fill", AppTheme.inRange)
        case .caution: return (text, "exclamationmark.triangle.fill", AppTheme.high)
        case .bad: return (text, "xmark.circle.fill", AppTheme.low)
        }
    }

    /// What the user chose to show beside the glucose; nothing for a value past its window.
    var compactChoice: String {
        switch content.layout.compact ?? .arrow {
        case .arrow:
            return arrow.isEmpty ? (chips.first?.value ?? "") : arrow
        case .delta:
            guard !stale, let d = LiveActivityMetrics.delta(snapshot.recent, now: now) else { return "" }
            return "\(d > 0 ? "+" : d < 0 ? "−" : "±")\(snapshot.unit.format(mgdl: abs(d)))"
        case .iob:
            return snapshot.insulinOnBoardIfFresh(asOf: now).map { formatUnits($0) } ?? ""
        }
    }

    /// The card's bottom row, when the app sent controls.
    @ViewBuilder var idleRow: some View {
        if let panel = content.panel, case .idle(let button) = panel.view {
            // The span button changes the chart, so it shows only where there is one.
            IdleRow(
                screen: panel.screen, button: button, alerts: content.alerts,
                spanHours: content.layout.style == .slim ? nil : content.layout.plotRangeHours)
        }
    }

    private var presentation: WidgetSnapshot.GlucosePresentation { snapshot.glucosePresentation(asOf: now) }

    /// The system marked it stale, or the glucose has aged past the window since.
    var stale: Bool {
        if systemStale { return true }
        if case .current = presentation { return false }
        return true
    }

    var glucoseValue: String {
        switch presentation {
        case .current(let g), .stale(let g, _): return snapshot.unit.format(mgdl: g.mgdl)
        case .hidden, .none: return "--"
        }
    }

    var arrow: String {
        guard !stale, case .current(let g) = presentation else { return "" }
        return g.trend?.rawValue ?? ""
    }

    var glucoseColor: Color {
        switch presentation {
        case .current(let g): return stale ? AppTheme.stale : AppTheme.glucoseColor(g.mgdl)
        case .stale, .hidden, .none: return AppTheme.stale
        }
    }

    var ageText: Text {
        guard let at = snapshot.glucose?.measuredAt else { return Text("No reading") }
        guard ticking else { return Text(LiveActivityMetrics.shortAge(at, now: now)) }
        return Text(at, style: .relative)
    }

    func glucose(size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(glucoseValue).font(.system(size: size, weight: .bold, design: .rounded)).foregroundStyle(glucoseColor)
            if !arrow.isEmpty { Text(arrow).font(.title3).foregroundStyle(glucoseColor) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stale ? "Glucose \(glucoseValue), stale" : "Glucose \(glucoseValue)")
    }

    var topRight: String? {
        let iob = snapshot.insulinOnBoardIfFresh(asOf: now).map { formatUnits($0) }
        let delta = stale ? nil : LiveActivityMetrics.deltaText(snapshot.recent, unit: snapshot.unit, now: now)
        switch content.layout.topRight {
        case .iobDelta: return [iob, delta].compactMap { $0 }.joined(separator: " · ").nonEmpty
        case .iob: return iob
        case .delta: return delta
        case .tir: return LiveActivityMetrics.timeInRange(snapshot.recent).map { "\($0)% TIR" }
        case .battery: return snapshot.batteryIfFresh(asOf: now).map { "\($0.percent)%" }
        case .reservoir: return snapshot.reservoirIfFresh(asOf: now).map { String(format: "%.0f U", $0) }
        case .none: return nil
        }
    }

    /// The chosen fields besides glucose and what the corner already shows. A value past its window shows
    /// "—"; the connection field appears only while the pump is down.
    var chips: [Chip] {
        let corner: Set<LiveActivityField> =
            switch content.layout.topRight {
            case .iobDelta: [.iob, .delta]
            case .iob: [.iob]
            case .delta: [.delta]
            case .tir: [.tir]
            case .battery: [.battery]
            case .reservoir: [.reservoir]
            case .none: []
            }
        // The slim style has no corner, so it leaves nothing out.
        let inCorner = content.layout.style == .slim ? [] : corner
        return content.layout.fields.filter { $0 != .glucose && !inCorner.contains($0) }.compactMap(chip)
    }

    private func chip(_ field: LiveActivityField) -> Chip? {
        switch field {
        case .glucose: return nil
        case .iob:
            return Chip(
                icon: "drop.fill", value: snapshot.insulinOnBoardIfFresh(asOf: now).map { formatUnits($0) } ?? "—")
        case .reservoir:
            return Chip(
                icon: "cross.vial.fill",
                value: snapshot.reservoirIfFresh(asOf: now).map { String(format: "%.0f U", $0) } ?? "—")
        case .battery:
            let b = snapshot.batteryIfFresh(asOf: now)
            return Chip(
                icon: b?.isCharging == true ? "battery.100percent.bolt" : "battery.75percent",
                value: b.map { "\($0.percent)%" } ?? "—")
        case .basal:
            switch snapshot.basalIfFresh(asOf: now) {
            case .suspended: return Chip(icon: "pause.circle.fill", value: "Suspended")
            case .active(let rate): return Chip(icon: "waveform.path.ecg", value: String(format: "%.2f U/h", rate))
            case nil: return Chip(icon: "waveform.path.ecg", value: "—")
            }
        case .controlIQ:
            guard let c = snapshot.controlIQIfFresh(asOf: now) else {
                return Chip(icon: "checkmark.circle", value: "—")
            }
            let value =
                !c.isEnabled ? "Off" : c.activity == .sleep ? "Sleep" : c.activity == .exercise ? "Exercise" : "On"
            return Chip(icon: c.activity == .sleep ? "moon.zzz.fill" : "checkmark.circle.fill", value: value)
        case .lastAutoCorrection:
            guard let at = snapshot.lastAutoCorrection else { return nil }
            return Chip(icon: "bolt.circle.fill", value: LiveActivityMetrics.shortAge(at, now: now))
        case .connection:
            return snapshot.isConnected(asOf: now)
                ? nil : Chip(icon: "antenna.radiowaves.left.and.right.slash", value: "No pump")
        case .delta:
            return Chip(
                icon: "arrow.up.arrow.down",
                value: LiveActivityMetrics.deltaText(snapshot.recent, unit: snapshot.unit, now: now) ?? "—")
        case .tir:
            return Chip(
                icon: "chart.bar.fill", value: LiveActivityMetrics.timeInRange(snapshot.recent).map { "\($0)%" } ?? "—")
        case .lastBolus:
            // The watch's details show the last bolus whatever its age: it's history, not a live value.
            return Chip(icon: "syringe.fill", value: snapshot.lastBolus.map { formatUnits($0.value) } ?? "—")
        }
    }
}

struct Chip: Hashable {
    let icon: String
    let value: String
}

struct ChipView: View {
    let chip: Chip
    var body: some View {
        Label(chip.value, systemImage: chip.icon).font(.caption2.weight(.semibold)).labelStyle(.titleAndIcon).lineLimit(
            1)
    }
}

struct LockScreenView: View {
    let view: LAView

    var body: some View {
        if let panel = view.activePanel {
            PanelScreenView(panel: panel, glucose: view).padding(10)
        } else {
            switch view.content.layout.style {
            case .fullBleed: fullBleed
            case .classic: classic
            case .slim: slim
            }
        }
    }

    private var fullBleed: some View {
        ZStack(alignment: .topLeading) {
            // Above the bottom row, when there is one, so the curve doesn't run under its buttons.
            GlucoseCurve(view: view).padding(.top, 30).padding(.bottom, view.content.panel == nil ? 0 : 30)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    view.glucose(size: 34)
                    view.ageText.font(.caption2).foregroundStyle(view.stale ? .orange : .secondary)
                }
                Spacer()
                if let corner = view.topRight { Text(corner).font(.system(size: 15, weight: .bold, design: .rounded)) }
            }
            VStack {
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        ForEach(view.chips, id: \.self) { ChipView(chip: $0) }
                        Spacer()
                    }
                    view.idleRow
                }
            }
        }
        .padding(12)
        .frame(height: 156)
        .opacity(view.stale ? 0.7 : 1)
    }

    private var slim: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                view.glucose(size: 28)
                view.ageText.font(.caption2).foregroundStyle(view.stale ? .orange : .secondary)
                Spacer()
                ForEach(view.chips.prefix(2), id: \.self) { ChipView(chip: $0) }
            }
            view.idleRow
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .opacity(view.stale ? 0.7 : 1)
    }

    private var classic: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    view.glucose(size: 40)
                    view.ageText.font(.caption2).foregroundStyle(view.stale ? .orange : .secondary)
                }
                Spacer()
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    ForEach(view.chips, id: \.self) { ChipView(chip: $0) }
                }
                .frame(maxWidth: 190)
            }
            Sparkline(points: view.snapshot.recent).frame(height: 30)
            view.idleRow
        }
        .padding(12)
        .opacity(view.stale ? 0.7 : 1)
    }
}

/// The zone-coloured glucose curve over the layout's span, with the chosen axis lines, ticks and range lines.
struct GlucoseCurve: View {
    let view: LAView

    var body: some View {
        let layout = view.content.layout
        let points = view.snapshot.recent
        Canvas { context, size in
            let floor = Double(layout.plotFloorMgdl)
            let ceiling = Double(max(layout.plotCeilingMgdl, layout.plotFloorMgdl + 1))
            let end = view.now
            let start = end.addingTimeInterval(-Double(max(layout.plotRangeHours, 1)) * 3600)
            func x(_ t: Date) -> CGFloat {
                size.width * CGFloat(t.timeIntervalSince(start) / end.timeIntervalSince(start))
            }
            func y(_ mgdl: Double) -> CGFloat {
                size.height * CGFloat(1 - (min(max(mgdl, floor), ceiling) - floor) / (ceiling - floor))
            }
            if layout.showRangeLines {
                for v in [GlucoseThresholds.low, GlucoseThresholds.high] {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y(Double(v))))
                    line.addLine(to: CGPoint(x: size.width, y: y(Double(v))))
                    context.stroke(
                        line, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            if layout.showXAxisLine {
                context.stroke(
                    Path { $0.addLines([CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]) },
                    with: .color(.secondary))
            }
            if layout.showYAxisLine {
                context.stroke(Path { $0.addLines([.zero, CGPoint(x: 0, y: size.height)]) }, with: .color(.secondary))
            }
            if layout.showXAxisTicks {
                for h in 0...max(layout.plotRangeHours, 1) {
                    let tx = x(start.addingTimeInterval(Double(h) * 3600))
                    context.stroke(
                        Path { $0.addLines([CGPoint(x: tx, y: size.height - 4), CGPoint(x: tx, y: size.height)]) },
                        with: .color(.secondary))
                }
            }
            if layout.showYAxisTicks {
                for v in [GlucoseThresholds.low, GlucoseThresholds.high] {
                    context.stroke(
                        Path { $0.addLines([CGPoint(x: 0, y: y(Double(v))), CGPoint(x: 4, y: y(Double(v)))]) },
                        with: .color(.secondary))
                }
            }
            for (a, b) in zip(points, points.dropFirst()) {
                var segment = Path()
                segment.move(to: CGPoint(x: x(a.t), y: y(Double(a.mgdl))))
                segment.addLine(to: CGPoint(x: x(b.t), y: y(Double(b.mgdl))))
                let color = view.stale ? AppTheme.stale : AppTheme.glucoseColor(b.mgdl)
                context.stroke(segment, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The recent glucose as a line over the 70–180 band: the classic card's and the widgets'.
struct Sparkline: View {
    let points: [WidgetSnapshot.Point]
    var floor = GlucoseThresholds.low
    var ceiling = GlucoseThresholds.high

    var body: some View {
        GeometryReader { geo in
            let lo = min(points.map(\.mgdl).min() ?? floor, floor)
            let hi = max(points.map(\.mgdl).max() ?? ceiling, ceiling)
            let t0 = points.first?.t.timeIntervalSinceReferenceDate ?? 0
            let span = max(1, (points.last?.t.timeIntervalSinceReferenceDate ?? t0) - t0)
            let y = { (v: Int) in geo.size.height * (1 - CGFloat(v - lo) / CGFloat(max(hi - lo, 1))) }
            let x = { (p: WidgetSnapshot.Point) in
                geo.size.width * CGFloat((p.t.timeIntervalSinceReferenceDate - t0) / span)
            }
            ZStack {
                Rectangle().fill(AppTheme.inRange.opacity(0.12))
                    .frame(height: max(0, y(GlucoseThresholds.low) - y(GlucoseThresholds.high)))
                    .position(x: geo.size.width / 2, y: (y(GlucoseThresholds.low) + y(GlucoseThresholds.high)) / 2)
                if points.count > 1 {
                    Path { p in
                        for (i, pt) in points.enumerated() {
                            let point = CGPoint(x: x(pt), y: y(pt.mgdl))
                            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                        }
                    }
                    .stroke(.primary.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                } else {
                    Text("no recent data").font(.caption2).foregroundStyle(.secondary).frame(
                        maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
