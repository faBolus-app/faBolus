import WidgetKit
import SwiftUI

/// Tap-to-bolus shortcut. This is intentionally a *link* into the app's bolus-entry + confirm
/// flow — never a one-tap dispense from the widget. Available on the Home Screen (small) and as
/// a Lock Screen circular button. Shows current glucose for context.
struct BolusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ControlX2Bolus", provider: ControlX2Provider()) { entry in
            BolusWidgetView(snap: entry.snap)
                .widgetURL(ControlX2DeepLink.bolus)
        }
        .configurationDisplayName("Bolus")
        .description("Open the bolus screen. Tapping never delivers directly — you confirm in the app.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct BolusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snap: WidgetSnapshot

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: "drop.fill").font(.system(size: 15))
                    Text("Bolus").font(.system(size: 11, weight: .semibold))
                }
            }
            .containerBackground(.clear, for: .widget)

        default: // .systemSmall
            VStack(spacing: 6) {
                Image(systemName: "drop.fill").font(.system(size: 30)).foregroundStyle(.white)
                Text("Bolus").font(.title3.weight(.bold)).foregroundStyle(.white)
                if let g = snap.glucose {
                    Text("\(g) \(snap.trendArrow)").font(.caption).foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(for: .widget) {
                LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.9),
                                        Color(red: 0.28, green: 0.32, blue: 0.8)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
}
