import AppIntents
import SwiftUI
import WidgetContent
import faBolusDesign

// The Live Activity's bolus and alert screens. They draw what the app sent (`LiveActivityPanel`) and send
// taps back; every decision is the app's. The words and the order of the steps are the watch's.

/// A button that sends `action` from `screen`, through the intent that needs an unlocked device when the
/// action does.
struct PanelButton<Label: View>: View {
    let screen: String
    let action: LiveActivityAction
    @ViewBuilder let label: () -> Label

    var body: some View {
        let tap = LiveActivityTap(screen: screen, action: action)
        if action.needsUnlock {
            Button(intent: LiveActivityActionIntent(tap), label: label).buttonStyle(.plain)
        } else {
            Button(intent: LiveActivityStopIntent(tap), label: label).buttonStyle(.plain)
        }
    }
}

/// A filled capsule, the panel's buttons' look.
struct Pill: View {
    let text: String
    var color: Color = AppTheme.insulin
    var enabled = true
    var prominent = false

    var body: some View {
        Text(text)
            .font((prominent ? Font.subheadline : .caption).weight(.semibold))
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(enabled ? (prominent ? Color.white : color) : Color.secondary)
            .padding(.horizontal, 12).padding(.vertical, prominent ? 8 : 5)
            .frame(maxWidth: prominent ? .infinity : nil)
            .background(
                enabled ? (prominent ? color : color.opacity(0.22)) : Color.secondary.opacity(0.15), in: Capsule())
    }
}

/// A screen of the flow, filling the Lock Screen card or the Dynamic Island's expanded bottom.
struct PanelScreenView: View {
    let panel: LiveActivityPanel
    let glucose: LAView

    var body: some View {
        Group {
            switch panel.view {
            case .idle: EmptyView()
            case .entry(let e): EntryScreen(screen: panel.screen, entry: e, glucose: glucose)
            case .question(let q): QuestionScreen(screen: panel.screen, question: q)
            case .review(let r):
                ReviewScreen(screen: panel.screen, review: r, now: glucose.ticking ? nil : glucose.now)
            case .confirm(let c): ConfirmScreen(screen: panel.screen, confirm: c)
            case .result(let r): ResultScreen(screen: panel.screen, result: r)
            case .alert(let a): AlertScreen(screen: panel.screen, alert: a)
            }
        }
        // From a tap until the app's answer arrives (slower from the Mac), the screen shows as pending, so a
        // tap that seems to do nothing isn't repeated.
        .invalidatableContent()
    }
}

/// The Dynamic Island's expanded bottom is too short for the bolus screens, so it shows where the bolus
/// stands in one row: a result with its Cancel or Done, an alert with ✕, or that the bolus is open on the
/// Lock Screen card, which the Mac shows too.
struct IslandPanelView: View {
    let panel: LiveActivityPanel

    var body: some View {
        HStack(spacing: 8) {
            switch panel.view {
            case .result(let r):
                VStack(alignment: .leading, spacing: 0) {
                    Text(r.headline).font(.subheadline.weight(.bold)).foregroundStyle(color(r.tone))
                    if let line = r.line { Text(line).font(.caption).lineLimit(1) }
                }
                Spacer()
                switch r.button {
                case .cancel:
                    PanelButton(screen: panel.screen, action: .cancelBolus) {
                        Pill(text: "Cancel", color: AppTheme.low)
                    }
                case .cancelling: Pill(text: "Cancelling", color: AppTheme.low, enabled: false)
                case .done: PanelButton(screen: panel.screen, action: .close) { Pill(text: "Done") }
                }
            case .alert(let a):
                Label(a.title, systemImage: "exclamationmark.triangle.fill").font(.subheadline.weight(.semibold))
                    .foregroundStyle(a.critical ? AppTheme.low : AppTheme.high).lineLimit(1)
                Spacer()
                CloseButton(screen: panel.screen)
            default:
                Text("Bolus open on the Lock Screen").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                CloseButton(screen: panel.screen)
            }
        }
        .invalidatableContent()
    }

    private func color(_ tone: LiveActivityPanel.Result.Tone) -> Color {
        switch tone {
        case .working: AppTheme.insulin
        case .good: AppTheme.inRange
        case .caution: AppTheme.high
        case .bad: AppTheme.low
        }
    }
}

/// ✕ in a screen's corner: back to the card. Sends no insulin, so it needs no unlocked device.
struct CloseButton: View {
    let screen: String
    var body: some View {
        PanelButton(screen: screen, action: .close) {
            Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                .frame(width: 28, height: 28).background(Color.secondary.opacity(0.15), in: Circle())
        }
        .accessibilityLabel("Close")
    }
}

struct EntryScreen: View {
    let screen: String
    let entry: LiveActivityPanel.Entry
    let glucose: LAView

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                PanelButton(screen: screen, action: .switchMode) { Pill(text: modeLabel, color: AppTheme.insulin) }
                    .accessibilityHint("Switches between units and the calculator")
                Spacer()
                glucose.glucose(size: 17)
                Spacer()
                CloseButton(screen: screen)
            }
            HStack(spacing: 8) {
                step("−\(coarse)", up: false, coarse: true, enabled: entry.canDecrease)
                step("−", up: false, coarse: false, enabled: entry.canDecrease)
                Text(entry.value).font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(entry.mode == .carbs ? AppTheme.carbs : AppTheme.insulin)
                    .frame(minWidth: 96).lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                step("+", up: true, coarse: false, enabled: entry.canIncrease)
                step("+\(coarse)", up: true, coarse: true, enabled: entry.canIncrease)
            }
            HStack(spacing: 6) {
                if let preview = entry.preview {
                    Text(preview).font(.caption.weight(.semibold))
                }
                if let message = entry.message {
                    Text(message).font(.caption).foregroundStyle(AppTheme.high)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            PanelButton(screen: screen, action: .review) {
                Pill(text: "Review", enabled: entry.canReview, prominent: true)
            }
            .disabled(!entry.canReview)
        }
    }

    private var modeLabel: String {
        switch entry.mode {
        case .units: "Units"
        case .carbs: "Carbs"
        case .food: "Food"
        }
    }

    private var coarse: String { entry.mode == .carbs ? "10" : "1" }

    private func step(_ label: String, up: Bool, coarse: Bool, enabled: Bool) -> some View {
        PanelButton(screen: screen, action: .adjust(up: up, coarse: coarse)) {
            Text(label).font((coarse ? Font.caption : .title3).weight(.bold))
                .foregroundStyle(enabled ? AppTheme.insulin : .secondary)
                .frame(width: coarse ? 38 : 40, height: 40)
                .background((enabled ? AppTheme.insulin : .secondary).opacity(0.18), in: Circle())
        }
        .disabled(!enabled)
        .accessibilityLabel(
            "\(up ? "More" : "Less")\(coarse ? (entry.mode == .carbs ? ", 10 grams" : ", 1 unit") : "")")
    }
}

struct QuestionScreen: View {
    let screen: String
    let question: LiveActivityPanel.Question

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(question.title).font(.subheadline.weight(.bold))
                Text(question.detail).font(.caption).foregroundStyle(.secondary)
                Spacer()
                CloseButton(screen: screen)
            }
            Text(question.ask).font(.headline)
            HStack(spacing: 8) {
                choice(question.yes, question.yesUnits, yes: true)
                choice(question.no, question.noUnits, yes: false)
            }
            PanelButton(screen: screen, action: .back) {
                Text("Back").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The watch's two halves: the answer that corrects (or includes the reading) filled blue, the one
    /// without grey, each naming its whole dose.
    private func choice(_ label: String, _ units: String, yes: Bool) -> some View {
        PanelButton(screen: screen, action: .answer(yes: yes)) {
            VStack(spacing: 2) {
                Text(label).font(.caption.weight(.semibold))
                Text(units).font(.system(.title3, design: .rounded).weight(.bold))
            }
            .foregroundStyle(yes ? Color.white : Color.primary)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(yes ? AppTheme.insulin : Color.secondary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        }
    }

}

struct ReviewScreen: View {
    let screen: String
    let review: LiveActivityPanel.Review
    /// Set, the countdown reads as of this time instead of counting.
    var now: Date?

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                PanelButton(screen: screen, action: .back) {
                    Text("Change").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                if !review.expired {
                    Group {
                        if let now {
                            let left = max(0, Int(review.expiresAt.timeIntervalSince(now)))
                            Text(String(format: "%d:%02d", left / 60, left % 60))
                        } else {
                            Text(timerInterval: Date.distantPast...review.expiresAt, countsDown: true)
                        }
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(maxWidth: 44)
                }
                CloseButton(screen: screen)
            }
            Text(review.units).font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.insulin)
            if let split = review.split {
                Text(split).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
            if review.expired {
                Text("Expired: start over").font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.low)
            } else {
                HStack(spacing: 18) {
                    ForEach(1...3, id: \.self) { n in
                        PanelButton(screen: screen, action: .tap(n)) {
                            Text("\(n)").font(.title3.weight(.bold))
                                .foregroundStyle(n <= review.taps ? Color.white : AppTheme.insulin)
                                .frame(width: 44, height: 44)
                                .background(
                                    n <= review.taps ? AppTheme.inRange : AppTheme.insulin.opacity(0.18), in: Circle())
                        }
                        .accessibilityLabel("Confirm step \(n) of 3")
                    }
                }
                Text("Tap 1 - 2 - 3 in order").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct ConfirmScreen: View {
    let screen: String
    let confirm: LiveActivityPanel.Confirm

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(confirm.title).font(.headline).foregroundStyle(AppTheme.high)
                Spacer()
                CloseButton(screen: screen)
            }
            Text(confirm.message).font(.caption).multilineTextAlignment(.center).lineLimit(3)
                .minimumScaleFactor(0.8)
            PanelButton(screen: screen, action: .goOn) {
                Pill(text: confirm.goOn, color: AppTheme.inRange, prominent: true)
            }
            PanelButton(screen: screen, action: .back) {
                Text("Back").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ResultScreen: View {
    let screen: String
    let result: LiveActivityPanel.Result

    var body: some View {
        VStack(spacing: 6) {
            Text(result.headline).font(.title2.weight(.bold)).foregroundStyle(color)
            if let line = result.line {
                Text(line).font(.subheadline).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.8)
            }
            if let note = result.note {
                Text(note).font(.caption).foregroundStyle(AppTheme.high).multilineTextAlignment(.center)
            }
            switch result.button {
            case .cancel:
                PanelButton(screen: screen, action: .cancelBolus) {
                    Pill(text: "Cancel", color: AppTheme.low, prominent: true)
                }
            case .cancelling:
                Pill(text: "Cancelling", color: AppTheme.low, enabled: false, prominent: true)
            case .done:
                PanelButton(screen: screen, action: .close) { Pill(text: "Done", prominent: true) }
            }
        }
    }

    private var color: Color {
        switch result.tone {
        case .working: AppTheme.insulin
        case .good: AppTheme.inRange
        case .caution: AppTheme.high
        case .bad: AppTheme.low
        }
    }
}

struct AlertScreen: View {
    let screen: String
    let alert: LiveActivityPanel.AlertCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(alert.title).font(.headline).foregroundStyle(alert.critical ? AppTheme.low : AppTheme.high)
                    .lineLimit(2)
                Spacer()
                if let position = alert.position {
                    Text(position).font(.caption2).foregroundStyle(.secondary)
                }
                CloseButton(screen: screen)
            }
            Text(alert.body).font(.caption).lineLimit(3).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            HStack {
                if alert.canClear {
                    PanelButton(screen: screen, action: .clearAlert) { Pill(text: "Clear on pump") }
                }
                if let note = alert.note {
                    Text(note).font(.caption).foregroundStyle(AppTheme.urgentHigh).lineLimit(1)
                }
                Spacer()
                if alert.position != nil {
                    PanelButton(screen: screen, action: .nextAlert) {
                        Pill(text: "Next", color: .secondary)
                    }
                }
            }
        }
    }
}

/// The card's bottom row: the bolus button (or why there's none), the top alert, and the chart's span.
struct IdleRow: View {
    let screen: String
    let button: LiveActivityPanel.IdleButton
    let alerts: LiveActivityAlerts?
    let spanHours: Int?

    var body: some View {
        HStack(spacing: 8) {
            if let alerts {
                PanelButton(screen: screen, action: .showAlerts) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(alerts.topTitle).lineLimit(1)
                        if alerts.count > 1 { Text("+\(alerts.count - 1)").foregroundStyle(.secondary) }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(alerts.topCritical ? AppTheme.low : AppTheme.high)
                }
                .accessibilityLabel("\(alerts.count) pump alert\(alerts.count == 1 ? "" : "s"): \(alerts.topTitle)")
            }
            Spacer(minLength: 0)
            if let spanHours {
                PanelButton(screen: screen, action: .cycleSpan) {
                    Label("\(spanHours) h", systemImage: "chart.xyaxis.line").font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                .accessibilityLabel("Chart span \(spanHours) hours")
            }
            switch button {
            case .none: EmptyView()
            case .bolus:
                PanelButton(screen: screen, action: .startBolus) {
                    Label("Bolus", systemImage: "drop.fill").font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(AppTheme.insulin.opacity(0.25), in: Capsule())
                }
            case .unavailable(let reason):
                Pill(text: reason, enabled: false)
            case .cancel:
                PanelButton(screen: screen, action: .cancelBolus) { Pill(text: "Cancel bolus", color: AppTheme.low) }
            case .cancelling:
                Pill(text: "Cancelling", color: AppTheme.low, enabled: false)
            }
        }
        .invalidatableContent()
    }
}

/// CarPlay and the Apple Watch Smart Stack: glucose, the recent curve, an ongoing bolus's headline and the
/// top alert. No buttons: CarPlay turns them off while driving, and the two can't be told apart. The curve
/// takes what height the lines leave it, and gives way to a bolus's headline and an alert together: there
/// isn't room for all four, and those two matter more.
struct SmallActivityView: View {
    let view: LAView

    private var headline: (text: String, color: Color)? {
        guard case .result(let r)? = view.content.panel?.view else { return nil }
        return (r.headline, LAView.look(r.tone).color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                view.glucose(size: 26)
                Spacer()
                view.ageText.font(.caption2).foregroundStyle(view.stale ? .orange : .secondary)
            }
            if view.snapshot.recent.count > 1 && (headline == nil || view.content.alerts == nil) {
                Sparkline(
                    points: view.snapshot.recent, stale: view.stale, floor: view.snapshot.plotBounds.floor,
                    ceiling: view.snapshot.plotBounds.ceiling
                )
                .frame(minHeight: 10, maxHeight: .infinity).layoutPriority(-1)
            }
            if let headline {
                Text(headline.text).font(.caption.weight(.bold)).foregroundStyle(headline.color).lineLimit(1)
            }
            if let alerts = view.content.alerts {
                Label(alerts.topTitle, systemImage: "exclamationmark.triangle.fill").font(.caption2)
                    .foregroundStyle(alerts.topCritical ? AppTheme.low : AppTheme.high).lineLimit(1)
            }
        }
        .padding(8)
    }
}
