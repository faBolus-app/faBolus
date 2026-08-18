import SwiftUI
import faBolusCore
import faBolusDesign
import Charts

/// modern chart: glucose (left axis, in-range band, range-colored points) plus an optional
/// **IOB line** and optional **vertical bolus bars** (height ∝ units) on a second (right) axis.
/// Glucose, IOB, and bolus bars each toggle independently. IOB/bolus values (units) share the
/// right-axis scale, which autoscales to whichever unit series are currently shown.
struct GlucoseChartView: View {
    let readings: [GlucoseReading]
    var iob: [IOBSample] = []
    var boluses: [BolusMarker] = []
    var windowHours: Int = 3
    var showGlucose: Bool = true
    var showIOB: Bool = true
    var showBolusBars: Bool = true
    /// Phase 09.18b (D-06): the pump's CURRENT known basal rate (units/hr) for the scrubber readout's
    /// basal row, or nil when unknown (→ "—"). faBolus has no per-timestamp basal history, so this is a
    /// single scalar handed in by the caller — never a synthesized schedule. Default nil so callers that
    /// don't surface basal (e.g. the slim remote chart) simply render "—".
    var basalUnitsPerHour: Double? = nil
    /// Phase 09.18b-02 (D-07/D-09): whether the HR chart-context toggle is ON. When off, no HealthKit HR
    /// query runs and the HR readout row is hidden entirely. Default false so callers that don't surface
    /// HR (e.g. the slim remote chart) never query Health.
    var heartRateContextEnabled: Bool = false
    /// Phase 09.18b-02 (D-07): the last Garmin ambient-HR sample (bpm + when), used as the HR value when
    /// Apple Health has no sample near the scrub point. Display-only chart context; nil hides the row.
    var latestGarminHeartRate: (bpm: Double, date: Date)? = nil

    // Phase 09.18b (D-05/D-06): the transient scrub x-position (in plot-area points) while the user
    // long-presses/drags the chart, or nil when idle. Read-only, never committed anywhere — cleared on
    // release. Each GlucoseChartView instance owns its own scrub state.
    @State private var scrubX: CGFloat? = nil
    /// The date of the glucose data point the scrub currently resolves to (nil when idle). Drives the
    /// haptic: a change fires `.selection` — on scrub start (nil → a point) and on crossing to a NEW
    /// data point while dragging (UI-SPEC §1 long-press-active + dragging states).
    @State private var scrubbedPointDate: Date? = nil
    /// VoiceOver scrub position: an index into `visible` moved by the `.accessibilityAdjustableAction`
    /// so VoiceOver users can step the scrub without the drag gesture (UI-SPEC §1 backstop). nil = not
    /// yet stepped.
    @State private var a11yIndex: Int? = nil
    /// Phase 09.18b-02 (D-07): the on-demand reader for the Apple-Health `.heartRate` sample nearest the
    /// scrub point. Owned per-chart; queried only while scrubbing with HR on (costs nothing otherwise).
    @State private var healthKitHR = HealthKitHeartRateSource()
    /// The Apple-Health HR (bpm) resolved for the current scrubbed data point, or nil. Refreshed by the
    /// `.task(id:)` below as the scrub crosses to a new point; cleared when HR is off or scrubbing ends.
    @State private var scrubbedHealthKitHR: Double? = nil

    /// Phase 04-02 (D-10): the display-unit funnel the Y-axis tick LABELS and the "mg/dL"/"mmol/L"
    /// caption route through. The chart domain, PointMark data, and AxisMarks tick VALUES stay
    /// mg/dL-scaled (Pitfall 4) — only the rendered text below changes.
    private var unit: GlucoseUnit { AppSettings.shared.glucoseDisplayUnit }

    /// True when any unit-scaled (right-axis) series is visible.
    private var showUnitsAxis: Bool { showIOB || showBolusBars }

    private var start: Date { Date().addingTimeInterval(-Double(windowHours) * 3600) }
    private var visible: [GlucoseReading] { readings.filter { $0.date >= start } }
    private var visibleIOB: [IOBSample] { iob.filter { $0.date >= start } }
    private var visibleBoluses: [BolusMarker] { boluses.filter { $0.date >= start } }

    // Glucose plot domain (left axis), Phase 09.13-01 (D-01): user-configurable via
    // AppSettings.shared.glucosePlotFloor/Ceiling, resolved through GlucosePlotScale at
    // AppSettings init so this is always a safe in-set pair — no hardcoded 40/300 literal remains
    // here. IOB/bolus (units) are scaled into this domain and labeled on the right axis via the
    // SAME shared math (D-09), so both bounds always drive both the scale and the label recovery.
    private var gLo: Double { Double(AppSettings.shared.glucosePlotFloor) }
    private var gHi: Double { Double(AppSettings.shared.glucosePlotCeiling) }
    private var iobMax: Double {
        // Autoscale the right axis to only the unit series that are actually shown.
        let iobPeak = showIOB ? (visibleIOB.map(\.iob).max() ?? 0) : 0
        let bolusPeak = showBolusBars ? (visibleBoluses.map(\.units).max() ?? 0) : 0
        return max(4, (max(iobPeak, bolusPeak) * 1.1).rounded(.up))
    }
    private func scaleUnits(_ u: Double) -> Double {
        GlucosePlotScale.scaleUnits(u, unitMax: iobMax, floor: AppSettings.shared.glucosePlotFloor,
                                     ceiling: AppSettings.shared.glucosePlotCeiling)
    }

    var body: some View {
        Chart {
            if showGlucose {
                RectangleMark(yStart: .value("Low", GlucoseThresholds.low), yEnd: .value("High", GlucoseThresholds.high))
                    .foregroundStyle(AppTheme.inRange.opacity(0.12))
                ForEach(visible) { r in
                    // D-08: symmetric clamp — an out-of-range reading pins to the visible top/bottom
                    // edge instead of being clipped out of the plot by chartYScale's domain. Display
                    // only: r.mgdl itself (used for the point's color below) is never altered.
                    let plottedY = GlucosePlotScale.clamp(r.mgdl, floor: AppSettings.shared.glucosePlotFloor,
                                                           ceiling: AppSettings.shared.glucosePlotCeiling)
                    PointMark(x: .value("Time", r.date), y: .value("Glucose", plottedY))
                        .foregroundStyle(AppTheme.glucoseColor(r.mgdl)).symbolSize(24)
                }
            }
            if showBolusBars {
                ForEach(visibleBoluses) { b in
                    RuleMark(x: .value("Time", b.date),
                             yStart: .value("Base", gLo), yEnd: .value("Bolus", scaleUnits(b.units)))
                        .foregroundStyle(AppTheme.insulin.opacity(0.55)).lineStyle(.init(lineWidth: 3))
                }
            }
            if showIOB {
                ForEach(visibleIOB) { s in
                    LineMark(x: .value("Time", s.date), y: .value("IOB", scaleUnits(s.iob)),
                             series: .value("Series", "IOB"))
                        .foregroundStyle(AppTheme.insulin).interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: start...Date())
        .chartYScale(domain: gLo...gHi)
        .chartYAxis {
            if showGlucose {
                AxisMarks(position: .leading, values: [GlucoseThresholds.low, 120, GlucoseThresholds.high, GlucoseThresholds.veryHigh]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Int.self) { Text(unit.format(mgdl: v)) } }
                }
            }
            if showUnitsAxis {
                AxisMarks(position: .trailing, values: [scaleUnits(0), scaleUnits(iobMax / 2), scaleUnits(iobMax)]) { value in
                    AxisValueLabel {
                        if let p = value.as(Double.self) {
                            // D-09: recovery reads BOTH bounds via the same shared math scaleUnits used,
                            // so the right-axis label stays correct at every floor/ceiling combo.
                            let recovered = GlucosePlotScale.recoverUnits(
                                p, unitMax: iobMax, floor: AppSettings.shared.glucosePlotFloor,
                                ceiling: AppSettings.shared.glucosePlotCeiling)
                            Text(String(format: "%.1f", recovered))
                        }
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: xStride)) { _ in
                AxisGridLine(); AxisValueLabel(format: .dateTime.hour())
            }
        }
        // Phase 09.18b (D-05/D-06) — the scrubbable readout, attached INSIDE this existing Chart via
        // `.chartOverlay` + `ChartProxy` (UI-SPEC §1 primary approach; NOT a bolted-on screen). Gated
        // behind `graphDetailEnabled` (default ON) — when off, nothing renders and the chart behaves
        // exactly as today. This plan (09.18b-01 tracer) shows the GLUCOSE row only.
        .chartOverlay(alignment: .top) { proxy in
            GeometryReader { geo in
                if AppSettings.shared.graphDetailEnabled {
                    scrubberLayer(proxy: proxy, size: geo.size)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: scrubbedPointDate)
        .overlay(alignment: .topLeading) {
            // Owner-requested toggle: this axis caption is the only persistent unit label the chart
            // draws — hidden entirely when off, never a bare fallback (the axis itself stays labeled
            // with numeric ticks either way).
            if showGlucose && AppSettings.shared.showGlucoseUnitLabels {
                Text(unit == .mmol ? String(localized: "mmol/L") : String(localized: "mg/dL"))
                    .font(.caption2).foregroundStyle(.secondary).padding(.leading, 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showUnitsAxis { Text("U").font(.caption2).foregroundStyle(AppTheme.insulin).padding(.trailing, 2) }
        }
        .frame(height: 160)
    }

    private var xStride: Int {
        switch windowHours {
        case ...3: return 1
        case ...6: return 1
        case ...12: return 2
        default: return 4
        }
    }

    // MARK: - GraphDetailView scrubber (Phase 09.18b, D-05/D-06)

    /// The ViewModel is rewritten over faBolus's OWN feed — the same `visible` glucose/IOB/bolus arrays
    /// this chart already renders (`model.glucoseHistory`/`iobHistory`/`bolusMarkers`) plus the current
    /// pump-snapshot basal scalar handed in — never Loop's stores (D-05).
    private var detailViewModel: GraphDetailViewModel {
        GraphDetailViewModel(glucose: visible, iob: visibleIOB, boluses: visibleBoluses,
                             currentBasalUnitsPerHour: basalUnitsPerHour)
    }

    /// The VoiceOver value string for the adjustable scrubber: the readout at the currently-stepped
    /// data point, or a prompt when the user hasn't stepped yet / there is nothing to scrub.
    private var a11yValue: String {
        guard let idx = a11yIndex, visible.indices.contains(idx) else {
            return visible.isEmpty ? "No readings to inspect" : "Not scrubbing"
        }
        return detailViewModel.readout(at: visible[idx].date)
            .accessibilityDescription(unit: AppSettings.shared.glucoseDisplayUnit)
    }

    /// The scrubber layer inside `.chartOverlay`: a full-plot transparent hit area carrying a
    /// `LongPressGesture` SEQUENCED with a `DragGesture(minimumDistance: 0)` so a plain tap/pan of the
    /// chart is NOT hijacked (only a deliberate ≥0.3s press begins a scrub). While scrubbing, the touch
    /// x maps through `ChartProxy.value(atX:)` to a `Date`, the ViewModel/`GraphDetailReadout` resolve
    /// the nearest values, and a vertical rule + grab handle + readout card render — the card offset to
    /// the side opposite the scrub point and clamped inside the 160px frame. Nothing is committed; the
    /// scrub clears on release.
    @ViewBuilder
    private func scrubberLayer(proxy: ChartProxy, size: CGSize) -> some View {
        let scrub = LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    let x = min(max(drag.location.x, 0), size.width)
                    scrubX = x
                    // Track which glucose data point the scrub resolves to, so the haptic fires only on
                    // crossing to a NEW point (and on scrub start), not on every sub-pixel move.
                    if let date: Date = proxy.value(atX: x) {
                        scrubbedPointDate = GraphDetailReadout.nearest(
                            to: date, in: visible, key: \.date,
                            within: GraphDetailViewModel.tolerance)?.date
                    }
                }
            }
            .onEnded { _ in scrubX = nil; scrubbedPointDate = nil }

        ZStack(alignment: .topLeading) {
            // Full-plot hit area (≥44px in both dimensions at 160px height) — the deliberate-press
            // gate lives in the gesture, not a small handle, so the whole chart is scrubbable.
            // VoiceOver: exposed as an adjustable element so increment/decrement steps the scrub
            // through glucose data points without the drag gesture (UI-SPEC §1 accessibility backstop).
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(scrub)
                .accessibilityElement()
                .accessibilityLabel("Glucose chart detail")
                .accessibilityHint("Swipe up or down to inspect glucose, insulin, bolus, and basal at each reading")
                .accessibilityValue(a11yValue)
                .accessibilityAdjustableAction { direction in
                    guard !visible.isEmpty else { return }
                    let current = a11yIndex ?? (visible.count - 1)
                    let next: Int
                    switch direction {
                    case .increment: next = min(current + 1, visible.count - 1)
                    case .decrement: next = max(current - 1, 0)
                    @unknown default: return
                    }
                    a11yIndex = next
                    let point = visible[next]
                    scrubbedPointDate = point.date
                    if let x = proxy.position(forX: point.date) { scrubX = min(max(x, 0), size.width) }
                }

            if let x = scrubX, let date: Date = proxy.value(atX: x) {
                let readout = detailViewModel.readout(at: date)
                let hr = resolvedHeartRate(at: date)
                let onLeftHalf = x < size.width / 2

                // Vertical rule + grab handle marking the active timestamp.
                Rectangle()
                    .fill(AppTheme.insulin)
                    .frame(width: 1.5, height: size.height)
                    .position(x: x, y: size.height / 2)
                Circle()
                    .fill(AppTheme.insulin)
                    .frame(width: 8, height: 8)
                    .position(x: x, y: 4)

                // Readout card, pinned to the plot edge OPPOSITE the scrub point (so it never sits
                // under the finger) and width-capped so it stays inside the chart bounds.
                HStack(spacing: 0) {
                    if !onLeftHalf {
                        GraphDetailCard(readout: readout, heartRate: hr.bpm,
                                        heartRateEnabled: heartRateContextEnabled, heartRateStale: hr.stale)
                        Spacer(minLength: 0)
                    }
                    if onLeftHalf {
                        Spacer(minLength: 0)
                        GraphDetailCard(readout: readout, heartRate: hr.bpm,
                                        heartRateEnabled: heartRateContextEnabled, heartRateStale: hr.stale)
                    }
                }
                .frame(maxWidth: .infinity, alignment: onLeftHalf ? .trailing : .leading)
                .padding(.horizontal, 4)
                .padding(.top, 2)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: scrubX == nil)
        // Phase 09.18b-02 (D-07/D-09): resolve the Apple-Health HR for the point the scrub lands on.
        // Keyed on `scrubbedPointDate` so it fires only when the scrub crosses to a NEW data point (or
        // ends), never on every sub-pixel move; a no-op (and no HealthKit query at all) when HR is off.
        .task(id: scrubbedPointDate) { await refreshScrubbedHealthKitHR() }
    }

    /// The HR value + staleness for the readout row (D-07). Prefers the Apple-Health sample nearest the
    /// scrub point (fresh by construction — queried within ±5 min); falls back to the last Garmin
    /// ambient-HR sample, tinted stale when that sample is more than ~15 min from the scrubbed time.
    /// Returns nil bpm when HR is off or no sample exists → the HR row hides entirely (D-09).
    private func resolvedHeartRate(at date: Date) -> (bpm: Double?, stale: Bool) {
        guard heartRateContextEnabled else { return (nil, false) }
        if let hk = scrubbedHealthKitHR { return (hk, false) }
        if let g = latestGarminHeartRate {
            return (g.bpm, abs(g.date.timeIntervalSince(date)) > 15 * 60)
        }
        return (nil, false)
    }

    /// On-demand Apple-Health HR read at the scrubbed data point (D-07). Only runs while scrubbing with
    /// HR ON — when HR is off or the scrub ends, it clears the value and issues NO HealthKit query (D-09).
    private func refreshScrubbedHealthKitHR() async {
        guard heartRateContextEnabled, let date = scrubbedPointDate else { scrubbedHealthKitHR = nil; return }
        await healthKitHR.requestAuthorizationIfNeeded()
        scrubbedHealthKitHR = await healthKitHR.heartRate(at: date)
    }
}
