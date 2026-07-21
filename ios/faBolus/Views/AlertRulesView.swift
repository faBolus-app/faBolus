import SwiftUI
import faBolusCore

/// Manage conditional auto-rules for pump alerts: auto-snooze or auto-dismiss matching alerts by
/// time-of-day, kind, specific ids, and/or a glucose condition. **Alarms are never auto-acted** — the
/// engine hard-excludes them — so the editor only offers the eligible kinds.
struct AlertRulesView: View {
    @Bindable var settings: AppSettings
    @State private var editing: AlertRule?

    var body: some View {
        Form {
            Section {
                if settings.alertRules.isEmpty {
                    Text("No rules yet. Add one to automatically snooze or clear alerts that meet conditions you choose (e.g. quiet CGM highs overnight).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(settings.alertRules) { rule in
                    Button { editing = rule } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.name).foregroundStyle(.primary)
                                Text(summary(rule)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !rule.enabled { Text("Off").font(.caption2).foregroundStyle(.secondary) }
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete { settings.alertRules.remove(atOffsets: $0) }
            } header: { Text("Rules") } footer: {
                Text("Rules are checked top to bottom; the first match wins. **Alarms and malfunctions are never auto-dismissed or auto-snoozed** for safety.")
            }
            Section {
                Button { editing = AlertRule() } label: { Label("Add rule", systemImage: "plus") }
            }
        }
        .navigationTitle("Alert rules")
        .sheet(item: $editing) { rule in
            AlertRuleEditorView(rule: rule) { updated in save(updated) }
        }
    }

    private func save(_ rule: AlertRule) {
        if let i = settings.alertRules.firstIndex(where: { $0.id == rule.id }) {
            settings.alertRules[i] = rule
        } else {
            settings.alertRules.append(rule)
        }
    }

    private func summary(_ r: AlertRule) -> String {
        var parts: [String] = [r.action.label]
        if r.kinds.isEmpty { parts.append("any kind") }
        else { parts.append(r.kinds.sorted { $0.rawValue < $1.rawValue }.map(\.label).joined(separator: "/")) }
        if r.startMinuteOfDay != r.endMinuteOfDay {
            parts.append("\(hhmm(r.startMinuteOfDay))–\(hhmm(r.endMinuteOfDay))")
        }
        if let b = r.glucoseBelow { parts.append("<\(b)") }
        if let a = r.glucoseAbove { parts.append(">\(a)") }
        return parts.joined(separator: " · ")
    }

    private func hhmm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
}

/// Add/edit a single alert rule.
private struct AlertRuleEditorView: View {
    @State var rule: AlertRule
    let onSave: (AlertRule) -> Void
    @Environment(\.dismiss) private var dismiss

    // Glucose gates edited as on/off + value so the UI can offer a stepper.
    @State private var useBelow = false
    @State private var useAbove = false
    @State private var belowValue = 70
    @State private var aboveValue = 250
    @State private var restrictTime = false

    private var eligibleKinds: [PumpAlertKind] { PumpAlertKind.allCases.filter { $0.isAutoRuleEligible } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $rule.name)
                    Toggle("Enabled", isOn: $rule.enabled)
                    Picker("Action", selection: $rule.action) {
                        ForEach(AlertAction.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text(rule.action == .autoDismiss
                         ? "Hides it here and, on pumps that allow remote dismiss (Tandem Mobi), clears it on the pump. Other pumps behave like auto-snooze."
                         : "Hides it here and stops re-notifying, like tapping Clear. Re-nags after 30 min if still active. Never touches the pump.")
                }

                Section("Match kinds") {
                    ForEach(eligibleKinds, id: \.self) { kind in
                        Toggle(kind.label, isOn: Binding(
                            get: { rule.kinds.contains(kind) },
                            set: { on in if on { rule.kinds.insert(kind) } else { rule.kinds.remove(kind) } }))
                    }
                    Text(rule.kinds.isEmpty ? "Matches any eligible kind." : "")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Only during a time window", isOn: $restrictTime)
                    if restrictTime {
                        DatePicker("From", selection: startBinding, displayedComponents: .hourAndMinute)
                        DatePicker("To", selection: endBinding, displayedComponents: .hourAndMinute)
                    }
                } header: { Text("Time of day") } footer: {
                    Text("A window like 22:00–07:00 wraps past midnight.")
                }

                Section("Glucose condition") {
                    Toggle("Only when glucose is below", isOn: $useBelow)
                    if useBelow { Stepper("Below \(belowValue) mg/dL", value: $belowValue, in: 40...400, step: 5) }
                    Toggle("Only when glucose is above", isOn: $useAbove)
                    if useAbove { Stepper("Above \(aboveValue) mg/dL", value: $aboveValue, in: 40...400, step: 5) }
                }
            }
            .navigationTitle("Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { commit() } }
            }
            .onAppear(perform: loadDerivedState)
        }
    }

    // DatePicker <-> minute-of-day plumbing (anchored to an arbitrary day; only H:M matter).
    private var startBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinute: rule.startMinuteOfDay) },
                set: { rule.startMinuteOfDay = Self.minute(from: $0) })
    }
    private var endBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinute: rule.endMinuteOfDay) },
                set: { rule.endMinuteOfDay = Self.minute(from: $0) })
    }
    private static func date(fromMinute m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    private static func minute(from d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func loadDerivedState() {
        restrictTime = rule.startMinuteOfDay != rule.endMinuteOfDay
        if let b = rule.glucoseBelow { useBelow = true; belowValue = b }
        if let a = rule.glucoseAbove { useAbove = true; aboveValue = a }
    }

    private func commit() {
        if !restrictTime { rule.startMinuteOfDay = 0; rule.endMinuteOfDay = 0 }   // full day
        rule.glucoseBelow = useBelow ? belowValue : nil
        rule.glucoseAbove = useAbove ? aboveValue : nil
        onSave(rule)
        dismiss()
    }
}
