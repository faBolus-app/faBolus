import Charts
import PhoneApp
import SwiftUI
import faBolusCore
import faBolusDesign

/// The glucose chart: readings coloured by range, IOB and boluses on a second scale, and below them the
/// basal rate in a lane of its own, with suspended spans shaded across both, as t:connect draws them.
/// Press and drag (or swipe up and down with VoiceOver) to read the glucose, IOB and any bolus at a time.
struct GlucoseChartView: View {
    let readings: [GlucoseReading]
    var iob: [IOBSample] = []
    var boluses: [BolusMarker] = []
    var deliveryChanges: [DeliveryChange] = []
    var windowHours = 3
    var showGlucose = true
    var showIOB = true
    var showBolusBars = true
    var showBasal = true
    var floor = GlucosePlotScale.defaultFloor
    var ceiling = GlucosePlotScale.defaultCeiling
    var unit: GlucoseUnit = .mgdl
    var showUnitLabel = false
    var now: Date

    @State private var scrubX: CGFloat?
    @State private var scrubbedDate: Date?
    @State private var voiceOverIndex: Int?

    private var start: Date { now.addingTimeInterval(-Double(windowHours) * 3600) }
    private var visible: [GlucoseReading] { readings.filter { $0.date >= start && $0.date <= now } }
    private var visibleIOB: [IOBSample] { iob.filter { $0.date >= start } }
    private var visibleBoluses: [BolusMarker] { boluses.filter { $0.date >= start } }
    private var showUnitsAxis: Bool { showIOB || showBolusBars }

    private var unitMax: Double {
        let iobPeak = showIOB ? (visibleIOB.map(\.iob).max() ?? 0) : 0
        let bolusPeak = showBolusBars ? (visibleBoluses.map(\.units).max() ?? 0) : 0
        return max(4, (max(iobPeak, bolusPeak) * 1.1).rounded(.up))
    }

    /// The basal lane below the glucose area, worked out once per drawing.
    private struct BasalLane {
        let chart: BasalChart
        /// In the glucose scale's units: a fifth of the glucose area, or 0 when the lane isn't drawn. The
        /// chart grows by as much, so the glucose area keeps its size.
        let height: Double
        let bottom: Double
        /// The lane's own scale: the window's highest rate, at least 1 U/h.
        let peak: Double
        var isDrawn: Bool { height > 0 }
        /// A rate's height in the lane: the peak fills most of it, leaving a gap below the glucose area.
        func top(_ rate: Double) -> Double { bottom + height * 0.8 * rate / peak }
    }

    /// Drawn only when shown and there is something to draw: an empty lane would label a scale with no data.
    private var basalLane: BasalLane {
        let chart = BasalChart(changes: deliveryChanges, from: start, to: now)
        let drawn = showBasal && !(chart.steps.isEmpty && chart.suspensions.isEmpty)
        let height = drawn ? Double(ceiling - floor) * 0.2 : 0
        return BasalLane(
            chart: chart, height: height, bottom: Double(floor) - height,
            peak: max(1, chart.steps.map(\.unitsPerHour).max() ?? 0))
    }

    private func scaled(_ u: Double) -> Double {
        GlucosePlotScale.scaleUnits(u, unitMax: unitMax, floor: floor, ceiling: ceiling)
    }

    var body: some View {
        let lane = basalLane
        let basal = lane.chart
        Chart {
            if lane.isDrawn {
                // The rate as a step line over a light fill. A suspension drops it to 0 and is marked in the
                // lane only, so nothing covers the glucose readings.
                ForEach(Array(basal.suspensions.enumerated()), id: \.offset) { _, span in
                    RectangleMark(
                        xStart: .value("Suspended", span.lowerBound), xEnd: .value("Resumed", span.upperBound),
                        yStart: .value("Base", lane.bottom), yEnd: .value("Top", Double(floor))
                    )
                    .foregroundStyle(Color.secondary.opacity(0.22))
                    .annotation(position: .overlay) {
                        Image(systemName: "pause.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(basal.steps.enumerated()), id: \.offset) { i, step in
                    let top = lane.top(step.unitsPerHour)
                    RectangleMark(
                        xStart: .value("From", step.start), xEnd: .value("To", step.end),
                        yStart: .value("Base", lane.bottom), yEnd: .value("Basal", top)
                    )
                    .foregroundStyle(AppTheme.basal.opacity(0.15))
                    RuleMark(xStart: .value("From", step.start), xEnd: .value("To", step.end), y: .value("Rate", top))
                        .foregroundStyle(AppTheme.basal).lineStyle(.init(lineWidth: 1.5))
                        // The rate now, at the line's right end, where now is: below the line when it is high
                        // in the lane, above it when low. None while suspended: the pause mark says so.
                        .annotation(
                            position: step.unitsPerHour > lane.peak / 2 ? .bottom : .top, alignment: .trailing,
                            spacing: 1
                        ) {
                            if i == basal.steps.count - 1, step.end == now, step.unitsPerHour > 0 {
                                Text(String(format: "%.2f U/hr", step.unitsPerHour)).font(.caption2)
                                    .foregroundStyle(AppTheme.basal)
                                    // Clear of the plot's right edge.
                                    .padding(.trailing, 4)
                            }
                        }
                    if i > 0 {
                        RuleMark(
                            x: .value("At", step.start),
                            yStart: .value("Was", lane.top(basal.steps[i - 1].unitsPerHour)),
                            yEnd: .value("Now", top)
                        )
                        .foregroundStyle(AppTheme.basal).lineStyle(.init(lineWidth: 1.5))
                    }
                }
                // The lane's top edge, between it and the glucose area.
                RuleMark(y: .value("Lane", Double(floor))).foregroundStyle(Color.secondary.opacity(0.7))
                    .lineStyle(.init(lineWidth: 1))
            }
            if showGlucose {
                RectangleMark(
                    yStart: .value("Low", GlucoseThresholds.low), yEnd: .value("High", GlucoseThresholds.high)
                )
                .foregroundStyle(AppTheme.inRange.opacity(0.12))
                // A reading off the plot isn't drawn, never pinned to its edge.
                ForEach(visible.filter { GlucosePlotScale.isOnChart($0.mgdl, floor: floor, ceiling: ceiling) }) { r in
                    PointMark(x: .value("Time", r.date), y: .value("Glucose", r.mgdl))
                        .foregroundStyle(AppTheme.glucoseColor(r.mgdl)).symbolSize(24)
                }
            }
            if showBolusBars {
                ForEach(visibleBoluses) { b in
                    RuleMark(
                        x: .value("Time", b.date), yStart: .value("Base", Double(floor)),
                        yEnd: .value("Bolus", scaled(b.units))
                    )
                    .foregroundStyle(AppTheme.insulin.opacity(0.55)).lineStyle(.init(lineWidth: 3))
                }
            }
            if showIOB {
                ForEach(visibleIOB) { s in
                    LineMark(
                        x: .value("Time", s.date), y: .value("IOB", scaled(s.iob)), series: .value("Series", "IOB")
                    )
                    .foregroundStyle(AppTheme.insulin).interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: start...now)
        .chartYScale(domain: lane.bottom...Double(ceiling))
        .chartYAxis {
            if showGlucose {
                AxisMarks(
                    position: .leading,
                    values: [GlucoseThresholds.low, 120, GlucoseThresholds.high, GlucoseThresholds.veryHigh]
                ) {
                    value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Int.self) { Text(unit.format(mgdl: v)) } }
                }
            }
            if lane.isDrawn {
                // The lane's name; its rate now is written at the line's right end, and any rate at a time in
                // the press-and-drag readout.
                AxisMarks(position: .leading, values: [lane.bottom + lane.height * 0.4]) { _ in
                    AxisValueLabel { Text("Basal") }
                }
            }
            if showUnitsAxis {
                // Zero at the glucose area's floor, the basal lane's top edge.
                AxisMarks(position: .trailing, values: [scaled(0), scaled(unitMax / 2), scaled(unitMax)]) { value in
                    AxisValueLabel {
                        if let p = value.as(Double.self) {
                            let u = GlucosePlotScale.recoverUnits(p, unitMax: unitMax, floor: floor, ceiling: ceiling)
                            // The top value carries the unit, in the insulin colour, as the scale's title. The scale
                            // tops out at a whole number, so "4 U" takes no more width than "4.0" did.
                            if abs(u - unitMax) < 0.001 {
                                Text(String(format: "%.0f U", u)).foregroundStyle(AppTheme.insulin)
                            } else {
                                Text(String(format: "%.1f", u))
                            }
                        }
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: windowHours <= 6 ? 1 : windowHours <= 12 ? 2 : 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartOverlay(alignment: .top) { proxy in
            GeometryReader { geo in scrubber(proxy: proxy, size: geo.size, lane: lane) }
        }
        .sensoryFeedback(.selection, trigger: scrubbedDate)
        .overlay(alignment: .topLeading) {
            if showGlucose && showUnitLabel {
                Text("mg/dL").font(.caption2).foregroundStyle(.secondary).padding(.leading, 2)
            }
        }
        .frame(height: lane.isDrawn ? 192 : 160)
    }

    private func readout(at date: Date, lane: BasalLane) -> ChartReadout {
        ChartReadout(
            at: date, glucose: visible, iob: visibleIOB, boluses: visibleBoluses,
            basal: lane.isDrawn ? lane.chart : nil)
    }

    @ViewBuilder private func scrubber(proxy: ChartProxy, size: CGSize, lane: BasalLane) -> some View {
        let scrub = LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                let x = min(max(drag.location.x, 0), size.width)
                scrubX = x
                if let date: Date = proxy.value(atX: x) {
                    scrubbedDate =
                        ChartReadout.nearest(to: date, in: visible, key: \.date, within: ChartReadout.tolerance)?.date
                }
            }
            .onEnded { _ in
                scrubX = nil
                scrubbedDate = nil
            }
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.clear).contentShape(Rectangle()).gesture(scrub)
                .accessibilityElement()
                .accessibilityLabel("Glucose chart")
                .accessibilityHint("Swipe up or down to hear glucose, active insulin and boluses at each reading")
                .accessibilityValue(spokenValue(lane: lane))
                .accessibilityAdjustableAction { direction in
                    guard !visible.isEmpty else { return }
                    let current = voiceOverIndex ?? visible.count - 1
                    switch direction {
                    case .increment: voiceOverIndex = min(current + 1, visible.count - 1)
                    case .decrement: voiceOverIndex = max(current - 1, 0)
                    @unknown default: return
                    }
                }
            if let x = scrubX, let date: Date = proxy.value(atX: x) {
                let leftHalf = x < size.width / 2
                Rectangle().fill(AppTheme.insulin).frame(width: 1.5, height: size.height).position(
                    x: x, y: size.height / 2)
                ReadoutCard(readout: readout(at: date, lane: lane), unit: unit)
                    .frame(maxWidth: .infinity, alignment: leftHalf ? .trailing : .leading)
                    .padding(.horizontal, 4).padding(.top, 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: scrubX == nil)
    }

    private func spokenValue(lane: BasalLane) -> String {
        guard let i = voiceOverIndex, visible.indices.contains(i) else {
            return visible.isEmpty ? "No readings" : "Not inspecting"
        }
        return readout(at: visible[i].date, lane: lane).spoken(unit: unit)
    }
}

/// The scrub readout: the time, then glucose, IOB and bolus, "—" where nothing is close enough.
struct ReadoutCard: View {
    let readout: ChartReadout
    let unit: GlucoseUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(readout.date.formatted(date: .omitted, time: .shortened))
                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            row(
                "drop.fill", "Glucose", readout.glucoseMgdl.map { unit.format(mgdl: $0) },
                readout.glucoseMgdl.map { AppTheme.glucoseColor($0) })
            row("syringe", "IOB", readout.iob.map { formatUnits($0) }, readout.iob.map { _ in AppTheme.insulin })
            row(
                "chart.bar.fill", "Bolus", readout.bolusUnits.map { formatUnits($0) },
                readout.bolusUnits.map { _ in AppTheme.insulin })
            if let basal = readout.basal {
                switch basal {
                case .rate(let u): row("waveform.path.ecg", "Basal", String(format: "%.2f U/hr", u), AppTheme.basal)
                case .suspended: row("pause.circle.fill", "Basal", "Suspended", AppTheme.low)
                case .unknown: row("waveform.path.ecg", "Basal", nil, nil)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator).opacity(0.3), lineWidth: 0.5))
        .frame(maxWidth: 220, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(readout.spoken(unit: unit))
    }

    private func row(_ icon: String, _ label: String, _ value: String?, _ tint: Color?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(tint ?? .secondary).frame(width: 16)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value ?? PumpDisplay.unknown).font(.body).monospacedDigit().foregroundStyle(tint ?? .secondary)
        }
    }
}
