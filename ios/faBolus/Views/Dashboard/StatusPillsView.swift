import PhoneApp
import SwiftUI
import faBolusCore
import faBolusDesign

/// The dashboard's status pills, in the order chosen in settings. Each value comes from `PumpDisplay`,
/// so a value past its window shows "—", the same as everywhere else.
struct StatusPillsView: View {
    let display: PumpDisplay
    let order: [String]
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(order.compactMap(StatusPill.init(rawValue:)), id: \.self) { pill($0) }
        }
    }

    @ViewBuilder private func pill(_ id: StatusPill) -> some View {
        switch id {
        case .iob:
            let v = display.insulinOnBoard
            Pill(
                icon: "drop.fill", tint: v.isKnown ? AppTheme.insulin : .gray, value: v.text, label: "Active insulin",
                stale: v.isStale)
        case .reservoir:
            let v = display.reservoir
            Pill(
                icon: "cross.vial.fill", tint: v.isKnown ? .teal : .gray, value: v.text, label: "Reservoir",
                stale: v.isStale)
        case .battery:
            let b = BatteryChargingPresentation.make(
                percent: display.battery?.percent, charging: display.battery?.isCharging == true)
            Pill(
                icon: b.symbolName, tint: b.usesLowTint ? AppTheme.low : .green, value: b.valueText, label: "Pump",
                stale: display.batteryIsStale)
        case .cgm:
            cgm
        case .basal:
            let v = display.basal
            Pill(
                icon: display.isSuspended ? "pause.circle.fill" : "waveform.path.ecg",
                tint: display.isSuspended ? AppTheme.low : (v.isKnown ? AppTheme.insulin : .gray), value: v.text,
                label: display.isSuspended ? "Delivery" : "Basal", stale: v.isStale)
        case .controlIQ:
            let v = display.controlIQText
            Pill(
                icon: controlIQIcon, tint: display.controlIQ?.isEnabled == true ? AppTheme.inRange : .gray,
                value: v.text,
                label: "Control-IQ", stale: v.isStale)
        case .lastBolus:
            Pill(icon: "drop.triangle.fill", tint: AppTheme.insulin, value: display.lastBolus.text, label: "Last bolus")
        case .carbRatio:
            let v = display.carbRatio
            Pill(
                icon: "fork.knife", tint: v.isKnown ? .orange : .gray, value: v.text, label: "Carb ratio",
                stale: v.isStale)
        case .isf:
            let v = display.correctionFactor
            Pill(
                icon: "arrow.down.right.circle", tint: v.isKnown ? .purple : .gray, value: v.text, label: "ISF",
                stale: v.isStale)
        case .target:
            let v = display.target
            Pill(
                icon: "target", tint: v.isKnown ? AppTheme.inRange : .gray, value: v.text, label: "Target",
                stale: v.isStale)
        case .maxBolus:
            Pill(
                icon: "gauge.with.dots.needle.67percent", tint: .teal, value: display.maxBolus.text, label: "Max bolus")
        }
    }

    private var controlIQIcon: String {
        switch display.controlIQ?.activity {
        case .sleep: return "moon.zzz.fill"
        case .exercise: return "figure.run"
        default: return "checkmark.circle.fill"
        }
    }

    @ViewBuilder private var cgm: some View {
        switch display.glucose {
        case .current(_, _, let at):
            Pill(
                icon: "sensor.tag.radiowaves.forward.fill", tint: AppTheme.inRange, value: display.age(at), label: "CGM"
            )
        case .stale(_, _, let at):
            Pill(
                icon: "sensor.tag.radiowaves.forward.fill", tint: AppTheme.low, value: display.age(at), label: "CGM",
                stale: true)
        case .hidden, .none:
            let active = display.cgmSessionActive == true
            Pill(
                icon: active ? "sensor.tag.radiowaves.forward.fill" : "sensor.tag.radiowaves.forward",
                tint: active ? AppTheme.inRange : .gray, value: active ? "OK" : PumpDisplay.unknown, label: "CGM")
        }
    }
}

struct Pill: View {
    let icon: String
    let tint: Color
    let value: String
    let label: String
    var stale = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.subheadline.weight(.semibold))
                Text(stale ? "\(label) · stale" : label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stale ? "\(label), \(value), stale" : "\(label), \(value)")
    }
}

/// Everything from the pump, one row each, in the order chosen in settings. A row with nothing known (the
/// last auto-correction before history shows one) is left out.
struct PumpDetailsCard: View {
    let display: PumpDisplay
    let order: [String]

    var body: some View {
        let rows = order.compactMap(DetailsField.init(rawValue:)).compactMap { f in display.detail(f).map { (f, $0) } }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.0) { index, row in
                HStack {
                    Text(row.0.label).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1).fontWeight(.medium)
                }
                .font(.subheadline).padding(.horizontal, 14).padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                if index < rows.count - 1 { Divider().padding(.leading, 14) }
            }
        }
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }
}
