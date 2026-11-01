import PhoneApp
import SwiftUI
import faBolusCore
import faBolusDesign

/// The glucose ring: the reading, its trend and age, and the pump link around it. A stale reading is shown
/// greyed with its age; past the hide window it isn't shown at all.
struct StatusRingView: View {
    let display: PumpDisplay
    var failoverSource: String?
    var bolusInProgress = false

    @ScaledMetric(relativeTo: .largeTitle) private var glucoseFontSize: CGFloat = 44
    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 180

    private var link: PumpLinkState { display.pump.link }

    var body: some View {
        ZStack {
            Circle().stroke(ringColor.opacity(0.25), lineWidth: 10)
            Circle()
                .trim(from: 0, to: link == .disconnected ? 0.05 : 1)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: link)
            content
        }
        .frame(width: ringSize, height: ringSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var ringColor: Color { AppTheme.ringColor(link: link, bolusInProgress: bolusInProgress) }

    @ViewBuilder private var content: some View {
        VStack(spacing: 2) {
            switch display.glucose {
            case .current(let mgdl, let trend, let at), .stale(let mgdl, let trend, let at):
                let stale = isStale
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(display.unit.format(mgdl: mgdl))
                        .font(.system(size: glucoseFontSize, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .foregroundStyle(AppTheme.glucoseColor(mgdl, stale: stale))
                    if let trend {
                        Text(trend.rawValue).font(.title2).foregroundStyle(stale ? AppTheme.stale : .primary)
                    }
                }
                if display.showUnitLabels { Text(display.unitLabel).font(.caption2).foregroundStyle(.secondary) }
                Text(display.age(at))
                    .font(.caption2).fontWeight(stale ? .semibold : .regular)
                    .foregroundStyle(stale ? AppTheme.low : .secondary)
            case .hidden:
                Text(PumpDisplay.unknown).font(.system(size: glucoseFontSize, weight: .bold, design: .rounded))
                Text("no recent CGM").font(.caption2).foregroundStyle(.secondary)
            case .none:
                Text(PumpDisplay.unknown).font(.system(size: glucoseFontSize, weight: .bold, design: .rounded))
                Text(display.showUnitLabels ? display.unitLabel : " ").font(.caption2).foregroundStyle(.secondary)
            }
            Text(linkText).font(.caption).foregroundStyle(.secondary)
            if let failoverSource {
                Label("via \(failoverSource)", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2).foregroundStyle(.orange)
                    .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.75)
                    .frame(maxWidth: 140)
            }
        }
    }

    private var isStale: Bool {
        if case .stale = display.glucose { return true }
        return false
    }

    private var linkText: String {
        switch link {
        case .disconnected: return "Disconnected"
        case .scanning: return "Searching"
        case .connecting: return "Connecting"
        case .authenticating: return "Authenticating"
        case .connected: return bolusInProgress ? "Bolusing" : "Connected"
        }
    }

    private var spoken: String {
        var parts: [String] = []
        switch display.glucose {
        case .current(let mgdl, _, let at):
            parts += ["Glucose \(display.unit.format(mgdl: mgdl)) \(display.unitLabel)", display.age(at)]
        case .stale(let mgdl, _, let at):
            parts += ["Glucose \(display.unit.format(mgdl: mgdl)) \(display.unitLabel), stale", display.age(at)]
        case .hidden: parts.append("No recent CGM")
        case .none: parts.append("Glucose unavailable")
        }
        parts.append(linkText)
        if let failoverSource { parts.append("via \(failoverSource)") }
        return parts.joined(separator: ", ")
    }
}
