import WidgetKit
import SwiftUI
import AppIntents

/// Home-Screen widget that delivers a bolus with the same flow as the Garmin remote: **choose an
/// amount** (− / +), tap **Bolus**, then a **1-2-3** sequential-tap confirm. Completing it delivers
/// **in place** — the widget shows Delivering… + Cancel, then Delivered — without opening the app.
/// The pump still enforces its max + signing. Bench/saline only.
struct QuickBolusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ControlX2QuickBolus", provider: ControlX2Provider()) { entry in
            QuickBolusView(snap: entry.snap)
        }
        .configurationDisplayName("Quick Bolus")
        .description("Set an amount and deliver a bolus with a 1-2-3 confirm (like the Garmin).")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuickBolusView: View {
    let snap: WidgetSnapshot
    private var stage: String { WidgetBolusStore.stage }
    private var draft: Double { WidgetBolusStore.draft }
    private var progress: Int { WidgetBolusStore.progress() }
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
            case .idle:
                if !snap.connected { notConnectedBody }
                else if stage == "confirm" { confirmBody }
                else { amountBody }
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

    // Stage 1 — choose the amount, then Bolus.
    @ViewBuilder private var amountBody: some View {
        Text("Bolus").font(.caption).foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 8) {
            stepper(delta: -1, symbol: "minus")
            Text(String(format: "%.2f U", draft))
                .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            stepper(delta: 1, symbol: "plus")
        }
        Button(intent: WidgetBolusBeginConfirmIntent()) {
            Text("Bolus").font(.subheadline.weight(.bold))
                .foregroundStyle(draft > 0 ? Color(red: 0.24, green: 0.28, blue: 0.75) : .white.opacity(0.5))
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(draft > 0 ? Color.white : Color.white.opacity(0.15), in: Capsule())
        }.buttonStyle(.plain)
    }

    // Stage 2 — 1-2-3 confirm for the chosen amount.
    @ViewBuilder private var confirmBody: some View {
        HStack(spacing: 4) {
            Button(intent: WidgetBolusBackIntent()) {
                Image(systemName: "chevron.left").foregroundStyle(.white.opacity(0.8))
            }.buttonStyle(.plain)
            Text(String(format: "%.2f U", draft)).font(.headline).foregroundStyle(.white)
            Spacer()
        }
        Text(progress == 0 ? "Tap 1 · 2 · 3" : "Confirming… \(progress)/3")
            .font(.caption2).foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 8) { stepButton(1); stepButton(2); stepButton(3) }
    }

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

    @ViewBuilder private func doneBody(icon: String, text: String) -> some View {
        Spacer(minLength: 0)
        Image(systemName: icon).font(.title2).foregroundStyle(.white)
        Text(text).font(.caption).foregroundStyle(.white)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        Spacer(minLength: 0)
    }

    @ViewBuilder private var notConnectedBody: some View {
        Spacer(minLength: 0)
        Link(destination: ControlX2DeepLink.open) {
            VStack(spacing: 4) {
                Image(systemName: "drop.fill").font(.title3)
                Text("Pump not connected — open app")
                    .font(.caption2).multilineTextAlignment(.center)
            }.foregroundStyle(.white.opacity(0.9)).frame(maxWidth: .infinity)
        }
        Spacer(minLength: 0)
    }

    // − / + amount buttons.
    @ViewBuilder private func stepper(delta: Int, symbol: String) -> some View {
        Button(intent: WidgetBolusAdjustIntent(delta: delta)) {
            Image(systemName: symbol).font(.headline.weight(.bold)).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.18), in: Circle())
        }.buttonStyle(.plain)
    }

    // Numbered confirm circle. 1 and 2 advance; 3 delivers.
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
