import WidgetKit
import SwiftUI
import AppIntents

/// Home-Screen widget that delivers a **preset** bolus, gated by the same **1-2-3** sequential-tap
/// confirmation the Garmin uses. Tapping 1 → 2 → 3 in order confirms; a wrong or late tap resets.
/// The widget never dispenses on its own: the final tap opens the app, which delivers through the
/// validated signed path (with progress + cancel). Bench/saline only.
struct QuickBolusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ControlX2QuickBolus", provider: ControlX2Provider()) { entry in
            QuickBolusView(snap: entry.snap)
        }
        .configurationDisplayName("Quick Bolus")
        .description("Deliver a preset bolus with a 1-2-3 confirm (like the Garmin). Tap 1→2→3 in order.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuickBolusView: View {
    let snap: WidgetSnapshot
    // Read live confirm progress + delivery status from the App Group (re-read on every re-render).
    private var progress: Int { WidgetBolusStore.progress() }
    private var preset: Double { WidgetBolusStore.presetUnits }
    private var status: WidgetBolusStatus { WidgetBolusStore.status() }

    var body: some View {
        VStack(spacing: 6) {
            switch status.phase {
            case .delivering: deliveringBody
            case .delivered:  doneBody(icon: "checkmark.circle.fill",
                                       text: String(format: "Delivered %.2f U", status.deliveredUnits))
            case .cancelled:  doneBody(icon: "xmark.circle.fill",
                                       text: String(format: "Cancelled · %.2f U", status.deliveredUnits))
            case .failed:     doneBody(icon: "exclamationmark.triangle.fill",
                                       text: status.message.isEmpty ? "Bolus failed" : status.message)
            case .idle:       idleBody
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.30, green: 0.36, blue: 0.85),
                                    Color(red: 0.22, green: 0.26, blue: 0.72)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    // Idle: the 1-2-3 confirm (or a prompt to open the app if the pump isn't connected).
    @ViewBuilder private var idleBody: some View {
        HStack(spacing: 4) {
            Image(systemName: "drop.fill").font(.caption)
            Text(String(format: "%.2f U", preset)).font(.headline)
            Spacer()
            if progress > 0 {
                Button(intent: WidgetBolusResetIntent()) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7))
                }.buttonStyle(.plain)
            }
        }
        if snap.connected {
            Text(progress == 0 ? "Tap 1 · 2 · 3 to bolus" : "Confirming… \(progress)/3")
                .font(.caption2).foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { stepButton(1); stepButton(2); stepButton(3) }
        } else {
            Spacer(minLength: 0)
            Link(destination: ControlX2DeepLink.open) {
                Text("Pump not connected — open app")
                    .font(.caption2).foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
    }

    // Delivering: progress + a cancel button, in place.
    @ViewBuilder private var deliveringBody: some View {
        HStack(spacing: 5) {
            ProgressView().tint(.white).scaleEffect(0.8)
            Text(String(format: "Delivering %.2f U", status.units))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Spacer(minLength: 0)
        Button(intent: WidgetBolusCancelIntent()) {
            Text("Cancel").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(Color.red.opacity(0.9), in: Capsule())
        }.buttonStyle(.plain)
    }

    // Terminal result — auto-reverts to idle after a few seconds (status TTL).
    @ViewBuilder private func doneBody(icon: String, text: String) -> some View {
        Spacer(minLength: 0)
        Image(systemName: icon).font(.title2).foregroundStyle(.white)
        Text(text).font(.caption).foregroundStyle(.white)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        Spacer(minLength: 0)
    }

    /// A numbered confirm circle. 1 and 2 advance the sequence; 3 opens the app to deliver.
    @ViewBuilder private func stepButton(_ n: Int) -> some View {
        if n == 3 {
            Button(intent: WidgetBolusDeliverIntent()) { circle(n) }.buttonStyle(.plain)
        } else {
            Button(intent: WidgetBolusStepIntent(step: n)) { circle(n) }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private func circle(_ n: Int) -> some View {
        let done = progress >= n
        ZStack {
            Circle().fill(done ? Color.white : Color.white.opacity(0.18))
            Text("\(n)")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(done ? Color(red: 0.24, green: 0.28, blue: 0.75) : .white)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }
}
