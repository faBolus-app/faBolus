import SwiftUI
import WidgetContent
import WidgetKit
import faBolusCore
import faBolusDesign

/// How a snapshot's glucose reads at an entry's date, for every widget.
struct GlucoseText {
    let value: String
    let arrow: String
    let color: Color
    let stale: Bool
    let measuredAt: Date?
    let spoken: String

    init(_ snapshot: WidgetSnapshot, now: Date) {
        switch snapshot.glucosePresentation(asOf: now) {
        case .current(let g):
            value = snapshot.unit.format(mgdl: g.mgdl)
            arrow = g.trend?.rawValue ?? ""
            color = AppTheme.glucoseColor(g.mgdl)
            stale = false
            measuredAt = snapshot.glucose?.measuredAt
            spoken = "Glucose \(value), \(GlucoseRange.classify(g.mgdl).shortLabel)"
        case .stale(let g, let at):
            value = snapshot.unit.format(mgdl: g.mgdl)
            arrow = ""
            color = AppTheme.stale
            stale = true
            measuredAt = at
            spoken = "Glucose \(value), stale"
        case .hidden, .none:
            value = "--"
            arrow = ""
            color = .gray
            stale = true
            measuredAt = snapshot.glucose?.measuredAt
            spoken = "No recent glucose"
        }
    }
}

struct GlucoseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FaBolusGlucose", provider: SnapshotProvider()) { entry in
            GlucoseWidgetView(snapshot: entry.snapshot, now: entry.date).widgetURL(DeepLink.open)
        }
        .configurationDisplayName("Glucose")
        .description("Glucose and trend, from the pump or the backup CGM.")
        .supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryRectangular, .systemSmall])
    }
}

struct GlucoseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        let g = GlucoseText(snapshot, now: now)
        let iob = snapshot.insulinOnBoardIfFresh(asOf: now).map { formatUnits($0) } ?? "—"
        switch family {
        case .accessoryInline:
            Label("\(g.value) \(g.arrow)", systemImage: "drop.fill").accessibilityLabel(g.spoken)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(g.value).font(.system(size: 22, weight: .bold, design: .rounded)).minimumScaleFactor(0.5)
                    Text(g.arrow.isEmpty ? (snapshot.showUnitLabel ? "mg/dL" : "") : g.arrow).font(.system(size: 11))
                }
                .accessibilityElement(children: .ignore).accessibilityLabel(g.spoken)
            }
            .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "drop.fill").font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(g.value) \(g.arrow)").font(.system(size: 22, weight: .semibold, design: .rounded))
                        .accessibilityLabel(g.spoken)
                    Text("IOB \(iob)").font(.caption2)
                }
            }
            .containerBackground(.clear, for: .widget)
        default:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(g.value).font(.system(size: 44, weight: .bold, design: .rounded)).foregroundStyle(g.color)
                    Text(g.arrow).font(.title2).foregroundStyle(g.color)
                    Spacer()
                }
                .accessibilityElement(children: .ignore).accessibilityLabel(g.spoken)
                if snapshot.showUnitLabel { Text("mg/dL").font(.caption).foregroundStyle(.secondary) }
                if let source = snapshot.glucoseSourceName {
                    Text("via \(source)").font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                HStack {
                    Label(iob, systemImage: "syringe").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if let at = g.measuredAt {
                        Text(at, style: .relative).font(.caption2).foregroundStyle(g.stale ? .orange : .secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FaBolusStatus", provider: SnapshotProvider()) { entry in
            StatusWidgetView(snapshot: entry.snapshot, now: entry.date).widgetURL(DeepLink.open)
        }
        .configurationDisplayName("Pump overview")
        .description("Glucose, active insulin, reservoir and battery.")
        .supportedFamilies([.systemMedium])
    }
}

struct StatusWidgetView: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        let g = GlucoseText(snapshot, now: now)
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(g.value).font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(g.color)
                    Text(g.arrow).font(.title3).foregroundStyle(g.color)
                }
                .accessibilityElement(children: .ignore).accessibilityLabel(g.spoken)
                if let at = g.measuredAt {
                    Text(at, style: .relative).font(.caption2).foregroundStyle(g.stale ? .orange : .secondary)
                }
                Sparkline(points: snapshot.recent).frame(height: 34).padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                metric("syringe", "Active insulin", snapshot.insulinOnBoardIfFresh(asOf: now).map { formatUnits($0) })
                metric("drop", "Reservoir", snapshot.reservoirIfFresh(asOf: now).map { String(format: "%.0f U", $0) })
                let battery = BatteryChargingPresentation.make(
                    percent: snapshot.batteryIfFresh(asOf: now)?.percent,
                    charging: snapshot.batteryIfFresh(asOf: now)?.isCharging == true)
                metric(battery.symbolName, "Battery", battery.isKnownValue)
                if !snapshot.isConnected(asOf: now) {
                    Label("Pump not connected", systemImage: "antenna.radiowaves.left.and.right.slash").font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func metric(_ icon: String, _ title: String, _ value: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value ?? "—").font(.caption).fontWeight(.semibold)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension BatteryPresentation {
    var isKnownValue: String? { valueText == "—" ? nil : valueText }
}
