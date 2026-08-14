import SwiftUI
import faBolusCore
import faBolusDesign

/// Glance page: big glucose + trend (hidden when stale), a compact IOB/reservoir line, the
/// iPhone-reachability state, and the Bolus button. Swipe for Chart / Details / Alerts.
struct WatchGlanceView: View {
    @Bindable var model: WatchModel
    @Binding var showBolus: Bool
    // N12 (Dynamic Type): the big glucose number scales instead of a fixed 44 pt.
    @ScaledMetric(relativeTo: .largeTitle) private var glucoseFontSize: CGFloat = 44

    /// Phase 4 (mmol/L display-unit support) — the unit mirrored from the phone's statusRead reply
    /// (`WatchModel.glucoseDisplayUnit`). The watch links `faBolusCore` directly, so this renders
    /// through the canonical `GlucoseUnit` funnel (no widget-style mirror needed here).
    private var unit: GlucoseUnit { model.glucoseDisplayUnit }
    private var unitLabel: String { unit == .mmol ? "mmol/L" : "mg/dL" }
    private var displayGlucose: String { model.glucose.map { unit.format(mgdl: $0) } ?? "—" }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Re-evaluate age/staleness on a timer so a reading visibly ages, greys, then hides.
                TimelineView(.periodic(from: .now, by: 20)) { ctx in
                    let present = GlucoseFreshness.presentation(of: model.glucoseDate, now: ctx.date)
                    let stale = present == .stale
                    VStack(spacing: 8) {
                        if let g = model.glucose, present != .hidden {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(displayGlucose)
                                    .font(.system(size: glucoseFontSize, weight: .bold, design: .rounded))
                                    .lineLimit(1).minimumScaleFactor(0.5)
                                    .foregroundStyle(AppTheme.glucoseColor(g, stale: stale))
                                Text(model.trend).font(.title2)
                                    .foregroundStyle(stale ? .gray : .primary)
                            }
                            // Icon+word non-color band channel (WCAG 1.4.1), fresh readings only — the
                            // number is grey when stale, no band color to duplicate. Hidden from
                            // VoiceOver: glanceGlucoseLabel already speaks the band word (see below).
                            if present == .fresh {
                                BandIndicator(band: GlucoseRange.classify(g), announcesOwnLabel: false)
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.glucoseColor(g))
                            }
                            Text(model.glucoseDate.map { GlucoseFreshness.ageLabel(for: $0, now: ctx.date) } ?? unitLabel)
                                .font(.caption2)
                                .fontWeight(stale ? .semibold : .regular)
                                .foregroundStyle(stale ? .orange : .secondary)
                        } else {
                            Text("—").font(.system(size: glucoseFontSize, weight: .bold, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.5)
                            Text(model.glucose == nil ? unitLabel : "no recent CGM")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    // N12: read the glucose block as one element — "Glucose 124, ↑, 2 min ago", with
                    // "stale" injected when de-emphasized (grey is otherwise the only stale cue).
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(glanceGlucoseLabel(now: ctx.date))
                }

                HStack(spacing: 12) {
                    Label(String(format: "%.2f U", model.iobUnits), systemImage: "syringe")
                    Label("\(Int(model.reservoirUnits)) U", systemImage: "drop")
                }.font(.caption2).foregroundStyle(.secondary)
                    // N12: the two icon-only Labels read raw values; combine into a spoken row.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Active insulin \(String(format: "%.2f", model.iobUnits)) units, reservoir \(Int(model.reservoirUnits)) units")

                if !model.alerts.isEmpty {
                    Label("\(model.alerts.count) alert\(model.alerts.count == 1 ? "" : "s")",
                          systemImage: "bell.badge.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }

                Label(model.reachable ? "iPhone connected" : "iPhone out of range",
                      systemImage: model.reachable ? "iphone" : "iphone.slash")
                    .font(.caption2)
                    .foregroundStyle(model.reachable ? .green : .orange)
                    .accessibilityLabel(model.reachable ? "iPhone connected" : "iPhone out of range")

                if model.reachable && !model.pumpConnected {
                    Label("Pump not connected", systemImage: "wifi.slash")
                        .font(.caption2).foregroundStyle(.orange)
                }

                if model.watchBolusAllowed {   // §2.3: not read-only AND watch bolusing enabled on the phone
                    Button { showBolus = true } label: { Label("Bolus", systemImage: "drop.fill") }
                        .tint(.indigo)
                        // Needs both the phone link AND the pump actually connected.
                        .disabled(!model.reachable || !model.pumpConnected)
                        .accessibilityLabel("Bolus")
                }
            }
            .padding(.top, 4)
        }
    }

    /// N12: spoken description of the glance glucose block, including "stale" when de-emphasized.
    private func glanceGlucoseLabel(now: Date) -> String {
        let present = GlucoseFreshness.presentation(of: model.glucoseDate, now: now)
        guard let g = model.glucose, present != .hidden else {
            return model.glucose == nil ? "Glucose unavailable" : "No recent CGM"
        }
        var parts = ["Glucose \(displayGlucose) \(unitLabel)", model.trend]
        // F4 (A5): speak the band word too when it's a live (band-colored) reading — the spoken
        // parallel of the on-screen BandIndicator, so the band never depends on color alone (mirrors
        // StatusRingView.a11yLabel, 09.1-01).
        if present == .fresh { parts.append(GlucoseRange.classify(g).shortLabel) }
        if present == .stale { parts.append("stale") }
        if let d = model.glucoseDate { parts.append(GlucoseFreshness.ageLabel(for: d, now: now)) }
        return parts.joined(separator: ", ")
    }
}
