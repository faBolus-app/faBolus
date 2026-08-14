import SwiftUI
import faBolusCore

/// Manage conditional auto-rules for pump alerts: auto-snooze or auto-dismiss matching alerts by
/// time-of-day, kind, specific ids, and/or a glucose condition. **Alarms are never auto-acted** — the
/// engine hard-excludes them — so the editor only offers the eligible kinds.
struct AlertRulesView: View {
    @Bindable var settings: AppSettings
    @State private var editing: AlertRule?
    /// §6/S8 B6: the opt-out is safety-reducing, so enabling it is gated behind this warning + confirm.
    @State private var showSuppressWarning = false

    /// §6/S8 B6: enabling the pump-alarm opt-out routes through a warning + explicit confirm; turning it
    /// off is immediate. Cancel leaves the flag false, so the Toggle snaps back.
    private var suppressBinding: Binding<Bool> {
        Binding(get: { settings.suppressMirroredPumpAlarms },
                set: { on in if on { showSuppressWarning = true } else { settings.suppressMirroredPumpAlarms = false } })
    }

    /// D-03/D-04 (RED stub — flips to the real decision in the GREEN step of Task 1): whether the
    /// honest "pending Apple approval" status should show. Returning a constant `false` here is
    /// intentional for the RED commit — it makes the enabled+ungranted test case fail for real
    /// (expects `true`, gets `false`) rather than failing to compile.
    static func shouldShowHonestStatus(enabled: Bool, grantActive: Bool) -> Bool { false }

    var body: some View {
        Form {
            // §6/S8 B6: how faBolus's notifications are delivered — the Critical Alerts opt-in and the
            // pump-alarm re-notification opt-out. Distinct from the auto-RULES below (which snooze/clear
            // specific alerts by condition).
            Section {
                Toggle("Use Critical Alerts", isOn: $settings.criticalAlertsEnabled)
                Toggle("Silence pump alarms in the app", isOn: suppressBinding)
            } header: { Text("Notification delivery") } footer: {
                Text("Critical Alerts let faBolus's safety alerts (pump disconnected, CGM data lost, unresolved bolus) alert even when your phone is on silent or Do Not Disturb, where your phone and this build support it. \"Silence pump alarms in the app\" stops faBolus re-notifying you for pump alarms the pump already sounds itself — the pump keeps alarming, and faBolus's own safety alerts are unaffected.")
            }
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
        .alert("Silence pump alarms in the app?", isPresented: $showSuppressWarning) {
            Button("Silence in the app", role: .destructive) { settings.suppressMirroredPumpAlarms = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("faBolus will stop showing a phone notification for pump alarms (like occlusion or low insulin) that your pump already alarms for. Make sure you'll notice the pump's own alarm. faBolus's own safety alerts — pump disconnected, CGM data lost, and unresolved bolus — are not affected.")
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

    /// Phase 04-02 (D-10): the display-unit funnel these two Stepper LABELS route through. `belowValue`/
    /// `aboveValue` and the Stepper's `in:`/`step:` bounds stay mg/dL `Int` — unchanged, unconverted
    /// (Pitfall 3) — only the rendered title text below changes.
    private var unit: GlucoseUnit { AppSettings.shared.glucoseDisplayUnit }

    /// "<value> mg/dL"/"<value> mmol/L" — a whole-phrase catalog VARIANT selected by the active
    /// display unit (D-10; not a glued suffix). `Localizable.xcstrings` carries both as siblings.
    private func glucoseLabel(_ mgdl: Int) -> String {
        let value = unit.format(mgdl: mgdl)
        return unit == .mmol
            ? String(format: String(localized: "%@ mmol/L"), value)
            : String(format: String(localized: "%@ mg/dL"), value)
    }

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
                    if useBelow {
                        Stepper(value: $belowValue, in: 40...400, step: 5) { Text("Below \(glucoseLabel(belowValue))") }
                    }
                    Toggle("Only when glucose is above", isOn: $useAbove)
                    if useAbove {
                        Stepper(value: $aboveValue, in: 40...400, step: 5) { Text("Above \(glucoseLabel(aboveValue))") }
                    }
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
