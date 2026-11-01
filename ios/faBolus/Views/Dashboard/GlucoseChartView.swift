import Charts
import PhoneApp
import SwiftUI
import faBolusCore
import faBolusDesign

/// The glucose chart: readings coloured by range, IOB and boluses on a second scale. Press and drag (or
/// swipe up and down with VoiceOver) to read the glucose, IOB and any bolus at a time (the old
/// graph-detail branch's readout, without the basal row).
struct GlucoseChartView: View {
    let readings: [GlucoseReading]
    var iob: [IOBSample] = []
    var boluses: [BolusMarker] = []
    var windowHours = 3
    var showGlucose = true
    var showIOB = true
    var showBolusBars = true
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

    private func scaled(_ u: Double) -> Double {
        GlucosePlotScale.scaleUnits(u, unitMax: unitMax, floor: floor, ceiling: ceiling)
    }

    var body: some View {
        Chart {
            if showGlucose {
                RectangleMark(
                    yStart: .value("Low", GlucoseThresholds.low), yEnd: .value("High", GlucoseThresholds.high)
                )
                .foregroundStyle(AppTheme.inRange.opacity(0.12))
                ForEach(visible) { r in
                    PointMark(
                        x: .value("Time", r.date),
                        y: .value("Glucose", GlucosePlotScale.clamp(r.mgdl, floor: floor, ceiling: ceiling))
                    )
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
        .chartYScale(domain: Double(floor)...Double(ceiling))
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
            if showUnitsAxis {
                AxisMarks(position: .trailing, values: [scaled(0), scaled(unitMax / 2), scaled(unitMax)]) { value in
                    AxisValueLabel {
                        if let p = value.as(Double.self) {
                            let u = GlucosePlotScale.recoverUnits(p, unitMax: unitMax, floor: floor, ceiling: ceiling)
                            Text(String(format: "%.1f", u))
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
            GeometryReader { geo in scrubber(proxy: proxy, size: geo.size) }
        }
        .sensoryFeedback(.selection, trigger: scrubbedDate)
        .overlay(alignment: .topLeading) {
            if showGlucose && showUnitLabel {
                Text("mg/dL").font(.caption2).foregroundStyle(.secondary).padding(.leading, 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showUnitsAxis { Text("U").font(.caption2).foregroundStyle(AppTheme.insulin).padding(.trailing, 2) }
        }
        .frame(height: 160)
    }

    private func readout(at date: Date) -> ChartReadout {
        ChartReadout(at: date, glucose: visible, iob: visibleIOB, boluses: visibleBoluses)
    }

    @ViewBuilder private func scrubber(proxy: ChartProxy, size: CGSize) -> some View {
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
                .accessibilityValue(spokenValue)
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
                ReadoutCard(readout: readout(at: date), unit: unit)
                    .frame(maxWidth: .infinity, alignment: leftHalf ? .trailing : .leading)
                    .padding(.horizontal, 4).padding(.top, 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: scrubX == nil)
    }

    private var spokenValue: String {
        guard let i = voiceOverIndex, visible.indices.contains(i) else {
            return visible.isEmpty ? "No readings" : "Not inspecting"
        }
        return readout(at: visible[i].date).spoken(unit: unit)
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
