import WidgetKit
import SwiftUI
import AppIntents
import faBolusDesign

/// Home-Screen widget that delivers a bolus with the same flow as the Garmin remote: **choose an
/// amount** (− / +), tap **Bolus**, then a **1-2-3** sequential-tap confirm. Completing it delivers
/// **in place** — the widget shows Delivering… + Cancel, then Delivered — without opening the app.
/// The pump still enforces its max + signing.
struct QuickBolusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FaBolusQuickBolus", provider: FaBolusProvider()) { entry in
            QuickBolusView(snap: entry.snap, now: entry.date)
        }
        .configurationDisplayName("Quick Bolus")
        .description("Set an amount and deliver a bolus with a 1-2-3 confirm (like the Garmin).")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuickBolusView: View {
    let snap: WidgetSnapshot
    /// Entry display date — connection-freshness (WR-02) is evaluated against this, not wall-clock
    /// (mirrors `StatusWidgetView.now`), since in a widget `Date()` is prep time, not display time.
    var now: Date = Date()
    /// WR-02 (R2-09): treat a snapshot whose publish time (`updatedAt`) has aged past the TTL as
    /// not-connected — a killed host leaves the last snapshot persisted, so `snap.connected` alone would
    /// keep the pad interactive indefinitely. Keyed off `updatedAt` (publish time), not `glucoseDate`.
    private var isConnected: Bool { snap.connected && !snap.isConnectionStale(asOf: now) }
    private var stage: String { WidgetBolusStore.stage }
    private var mode: String { WidgetBolusStore.mode }
    private var draft: Double { WidgetBolusStore.draft }
    private var progress: Int { WidgetBolusStore.progress() }
    private var status: WidgetBolusStatus { WidgetBolusStore.status() }
    /// A-05: whether bolusing is locked (phone read-only, or child mode with .bolus disallowed). Computed
    /// app-side by the single AccessPolicy evaluator and mirrored to the App Group — the widget only reads
    /// it, never re-deriving the gate. When set, the entry + confirm pad is replaced by a locked notice.
    private var bolusLocked: Bool { WidgetBolusStore.bolusLocked }
    private var lockReason: String { WidgetBolusStore.bolusLockReason }
    /// The amount as text with its unit ("1.50 U" or "30 g").
    private var amountLabel: String {
        mode == "carbs" ? "\(Int(draft)) g" : String(format: "%.2f U", draft)
    }

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
                // A-05: a locked gate replaces the interactive pad entirely (takes precedence over the
                // not-connected notice — "locked" is the definitive reason bolusing is unavailable). The
                // in-flight cases above are untouched: a bolus already delivering keeps its Cancel, which
                // the evaluator never read-only-blocks.
                if bolusLocked { lockedBody }
                else if !isConnected { notConnectedBody }   // WR-02: not-connected OR stale-publish (host killed)
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

    // Stage 1 — choose units/carbs + the amount, then Bolus.
    @ViewBuilder private var amountBody: some View {
        Button(intent: WidgetBolusToggleModeIntent()) {
            HStack(spacing: 3) {
                Text(mode == "carbs" ? "Carbs" : "Units").font(.caption.weight(.semibold))
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 9, weight: .bold))
            }.foregroundStyle(.white.opacity(0.9))
        }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 6) {
            stepper(delta: -1, symbol: "minus")
            Text(amountLabel)
                .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                .minimumScaleFactor(0.5).lineLimit(1)
                .frame(maxWidth: .infinity)
            stepper(delta: 1, symbol: "plus")
        }
        Button(intent: WidgetBolusBeginConfirmIntent()) {
            Text("Bolus").font(.subheadline.weight(.bold))
                .foregroundStyle(draft > 0 ? AppTheme.insulin : .white.opacity(0.5))
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
            Text(amountLabel).font(.headline).foregroundStyle(.white)
                .minimumScaleFactor(0.5).lineLimit(1)
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
            // D2-10: this numeric dose readout has no lineLimit(1)/wrap fallback of its own — without
            // a scale factor it truncates (not wraps) at large Dynamic Type, silently hiding the
            // in-flight dose amount.
            Text(String(format: "Delivering %.2f U", status.units))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .minimumScaleFactor(0.6).lineLimit(1)
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
        // D2-10: carries the delivered/cancelled numeric dose amount — scale it down before it
        // truncates at large Dynamic Type (wrapping alone can still clip in the small widget family).
        Text(text).font(.caption).foregroundStyle(.white)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            .minimumScaleFactor(0.7).lineLimit(2)
        Spacer(minLength: 0)
    }

    @ViewBuilder private var notConnectedBody: some View {
        Spacer(minLength: 0)
        Link(destination: FaBolusDeepLink.open) {
            VStack(spacing: 4) {
                Image(systemName: "drop.fill").font(.title3)
                Text("Pump not connected — open app")
                    .font(.caption2).multilineTextAlignment(.center)
            }.foregroundStyle(.white.opacity(0.9)).frame(maxWidth: .infinity)
        }
        Spacer(minLength: 0)
    }

    // A-05: bolusing is locked host-side (read-only / child mode). No entry or confirm affordances — just
    // a dimmed lock notice that opens the app (where the setting lives). None of the bolus App Intents are
    // reachable from here, so a tap can't start a dose the host would refuse.
    @ViewBuilder private var lockedBody: some View {
        Spacer(minLength: 0)
        Link(destination: FaBolusDeepLink.open) {
            VStack(spacing: 3) {
                Image(systemName: "lock.fill").font(.title3)
                Text("Bolus locked").font(.caption.weight(.semibold))
                if !lockReason.isEmpty {
                    Text(lockReason).font(.caption2).opacity(0.85)
                }
                Text("Open faBolus").font(.caption2).opacity(0.7)
            }
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
        Spacer(minLength: 0)
    }

    // − / + amount buttons. D2-05: floored at WidgetA11y.minHitTarget (Apple's documented 44×44pt
    // minimum tappable size — was a below-minimum 34×34) and VoiceOver-labeled/hinted via the same
    // WidgetA11y builder the test suite asserts against, so the announced action always matches the
    // actual mode/step (e.g. "Increase bolus by 5 grams" in carbs mode, "…by 0.05 units" in units mode).
    @ViewBuilder private func stepper(delta: Int, symbol: String) -> some View {
        let carbs = mode == "carbs"
        let step = carbs ? WidgetBolusStore.carbIncrement : WidgetBolusStore.increment
        let unitLabel = carbs ? "grams" : "units"
        let label = WidgetA11y.stepperLabel(increasing: delta > 0, step: step, unitLabel: unitLabel)
        Button(intent: WidgetBolusAdjustIntent(delta: delta)) {
            Image(systemName: symbol).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                .frame(width: WidgetA11y.minHitTarget, height: WidgetA11y.minHitTarget)
                .background(Color.white.opacity(0.18), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint(WidgetA11y.stepperHint)
    }

    // Numbered confirm circle. 1 and 2 advance; 3 delivers. D2-05: each carries one grouped VoiceOver
    // element with a full-sentence label/hint (StatusPillsView idiom) instead of speaking the bare
    // digit — "1"/"2"/"3" alone would tell a VoiceOver user nothing about what the tap does.
    @ViewBuilder private func stepButton(_ n: Int) -> some View {
        let done = progress >= n
        let label = WidgetA11y.confirmStepLabel(step: n, done: done)
        let hint = WidgetA11y.confirmStepHint(step: n)
        Group {
            if n == 3 {
                Button(intent: WidgetBolusDeliverIntent()) { circle(n) }
            } else {
                Button(intent: WidgetBolusStepIntent(step: n)) { circle(n) }
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: WidgetA11y.minHitTarget, minHeight: WidgetA11y.minHitTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    @ViewBuilder private func circle(_ n: Int) -> some View {
        let done = progress >= n
        ZStack {
            Circle().fill(done ? Color.white : Color.white.opacity(0.18))
            Text("\(n)")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(done ? AppTheme.insulin : .white)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }
}
