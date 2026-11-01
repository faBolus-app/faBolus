import ActivityKit
import SwiftUI
import WidgetContent
import WidgetKit
import faBolusCore
import faBolusDesign

/// The glucose Live Activity: the Lock Screen card in either style, and the Dynamic Island. Read-only; a
/// tap opens the app, and the optional Bolus pill opens its bolus screen. Once the system marks the
/// activity stale (its glucose passed the window, or the app stopped updating it), everything greys.
struct GlucoseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GlucoseActivityAttributes.self) { context in
            LockScreenView(view: LAView(content: context.state, systemStale: context.isStale, now: Date()))
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
                    VStack(spacing: 6) {
                        GlucoseCurve(view: v).frame(height: 44)
                        if v.content.layout.showBolusShortcut { BolusPill() }
                    }
                }
            } compactLeading: {
                Text(v.glucoseValue).font(.system(.body, design: .rounded).weight(.bold)).foregroundStyle(
                    v.glucoseColor)
            } compactTrailing: {
                Text(v.arrow.isEmpty ? (v.chips.first?.value ?? "") : v.arrow).foregroundStyle(v.glucoseColor)
            } minimal: {
                Text(v.glucoseValue).font(.system(.caption, design: .rounded).weight(.bold)).foregroundStyle(
                    v.glucoseColor)
            }
            .widgetURL(DeepLink.open)
        }
    }
}

/// One update as the views show it at `now`.
struct LAView {
    let content: LiveActivityContent
    let systemStale: Bool
    let now: Date

    var snapshot: WidgetSnapshot { content.snapshot }

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
        let inCorner: Set<LiveActivityField> =
            switch content.layout.topRight {
            case .iobDelta: [.iob, .delta]
            case .iob: [.iob]
            case .delta: [.delta]
            case .tir: [.tir]
            case .battery: [.battery]
            case .reservoir: [.reservoir]
            case .none: []
            }
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
        switch view.content.layout.style {
        case .fullBleed: fullBleed
        case .classic: classic
        }
    }

    private var fullBleed: some View {
        ZStack(alignment: .topLeading) {
            GlucoseCurve(view: view).padding(.top, 30)
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
                HStack(spacing: 10) {
                    ForEach(view.chips, id: \.self) { ChipView(chip: $0) }
                    Spacer()
                    if view.content.layout.showBolusShortcut { BolusPill() }
                }
            }
        }
        .padding(12)
        .frame(height: 144)
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
            HStack {
                Sparkline(points: view.snapshot.recent).frame(height: 30)
                if view.content.layout.showBolusShortcut { BolusPill() }
            }
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

/// Opens the app's bolus screen. Nothing is sent from the Live Activity.
struct BolusPill: View {
    var body: some View {
        Link(destination: DeepLink.bolus) {
            Label("Bolus", systemImage: "drop.fill").font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(AppTheme.insulin.opacity(0.25), in: Capsule())
        }
        .accessibilityHint("Opens the bolus screen in faBolus")
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
