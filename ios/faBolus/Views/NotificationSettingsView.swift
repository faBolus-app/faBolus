import SwiftUI
import faBolusCore

/// Phase 8.1 (D-06) — the dedicated notification-controls screen, reached from Settings as a normal
/// `.notifications` category. Splits [[NotificationBroker]].`Category` into a pump-sourced section
/// (the single relayed `pumpAlert` bucket, D-03) and an app-generated section (the other 7 categories,
/// D-02); each governed (non-trio) category is enable / quiet-hours / critical-break-through tunable
/// (D-04), while the never-suppressible trio (`pumpDisconnect` / `cgmDataLoss` / `bolusReconciliation`)
/// renders as always-on / non-interactive (D-05) — its governance guarantee lives structurally in
/// `NotificationBroker.decide()`, unchanged by this view. The two previously-standalone
/// `AlertRulesView` toggles (`criticalAlertsEnabled`, `suppressMirroredPumpAlarms`) are relocated here
/// verbatim (D-07), not duplicated. Every per-category edit writes through
/// [[NotificationRuntime]].`updateSettings(_:for:)` (Plan 01's persistence seam) so it survives a
/// relaunch and is honored by every out-of-process poster.
struct NotificationSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var runtime: NotificationRuntime
    /// Local mirror of `runtime.settings` for reactive rendering — `NotificationRuntime` is a plain
    /// `@MainActor` class, not `@Observable`, so a `@State` copy drives the UI and is refreshed after
    /// every write-through mutation (see `updateCategorySettings`).
    @State private var categorySettings: [NotificationBroker.Category: NotificationBroker.CategorySettings]
    /// §6/S8 B6 (relocated from `AlertRulesView`, D-07): enabling the pump-alarm opt-out is
    /// safety-reducing, so it's gated behind this warning + confirm; turning it off is immediate.
    @State private var showSuppressWarning = false
    /// D-04 / RESEARCH Open Question #2: turning a category's critical break-through OFF is the
    /// safety-reducing direction, so it's confirm-gated too. Holds the category whose confirm dialog
    /// is currently showing (`nil` ⇒ no dialog).
    @State private var breakThroughOffCategory: NotificationBroker.Category?

    init(settings: AppSettings) {
        self.settings = settings
        let rt = NotificationRuntime()
        _runtime = State(initialValue: rt)
        _categorySettings = State(initialValue: rt.settings)
    }

    // MARK: - Category groupings (D-02)

    private var trioCategories: [NotificationBroker.Category] {
        NotificationBroker.Category.allCases.filter { !$0.isPumpSourced && $0.neverSuppressible }
    }
    private var tunableAppCategories: [NotificationBroker.Category] {
        NotificationBroker.Category.allCases.filter { !$0.isPumpSourced && !$0.neverSuppressible }
    }

    // MARK: - Relocated bindings (D-07, verbatim from AlertRulesView)

    /// §6/S8 B6: enabling the pump-alarm opt-out routes through a warning + explicit confirm; turning it
    /// off is immediate. Cancel leaves the flag false, so the Toggle snaps back. Routed through the
    /// shared `guardedToggle` factory (09.3-01, D-05/SC3) — the one idiom every confirm-gated settings
    /// toggle uses.
    private var suppressBinding: Binding<Bool> {
        guardedToggle(
            get: { settings.suppressMirroredPumpAlarms },
            set: { settings.suppressMirroredPumpAlarms = $0 },
            requestConfirm: { showSuppressWarning = true }
        )
    }

    /// D-03/D-04: whether the honest "pending Apple approval" status should show — true only when the
    /// user opted into Critical Alerts AND the OS grant isn't active yet (nothing to disclose otherwise).
    /// Pure so it's directly testable without driving the view or a real notification center.
    static func shouldShowHonestStatus(enabled: Bool, grantActive: Bool) -> Bool { enabled && !grantActive }

    // MARK: - Per-category bindings

    private func enabledBinding(for category: NotificationBroker.Category) -> Binding<Bool> {
        Binding(
            get: { categorySettings[category]?.enabled ?? category.defaultEnabled },
            set: { on in
                var cfg = categorySettings[category] ?? .defaults(for: category)
                cfg.enabled = on
                updateCategorySettings(cfg, for: category)
            }
        )
    }

    /// Whether `category` has an active quiet-hours window (`start != end`, per
    /// `CategorySettings.inQuietHours`'s own "equal ⇒ no window" convention).
    private func quietHoursEnabledBinding(for category: NotificationBroker.Category) -> Binding<Bool> {
        Binding(
            get: {
                let cfg = categorySettings[category] ?? .defaults(for: category)
                return cfg.quietStartMinuteOfDay != cfg.quietEndMinuteOfDay
            },
            set: { on in
                var cfg = categorySettings[category] ?? .defaults(for: category)
                if on {
                    // Seed a sensible overnight default the first time this is turned on — leaving
                    // start==end would make the toggle a silent no-op (that's "no window" per
                    // `inQuietHours`).
                    if cfg.quietStartMinuteOfDay == cfg.quietEndMinuteOfDay {
                        cfg.quietStartMinuteOfDay = 22 * 60
                        cfg.quietEndMinuteOfDay = 7 * 60
                    }
                } else {
                    cfg.quietStartMinuteOfDay = 0
                    cfg.quietEndMinuteOfDay = 0
                }
                updateCategorySettings(cfg, for: category)
            }
        )
    }

    // DatePicker <-> minute-of-day plumbing (mirrors AlertRuleEditorView's startBinding/endBinding).
    private func quietStartBinding(for category: NotificationBroker.Category) -> Binding<Date> {
        Binding(
            get: { Self.date(fromMinute: categorySettings[category]?.quietStartMinuteOfDay ?? 0) },
            set: { date in
                var cfg = categorySettings[category] ?? .defaults(for: category)
                cfg.quietStartMinuteOfDay = Self.minute(from: date)
                updateCategorySettings(cfg, for: category)
            }
        )
    }
    private func quietEndBinding(for category: NotificationBroker.Category) -> Binding<Date> {
        Binding(
            get: { Self.date(fromMinute: categorySettings[category]?.quietEndMinuteOfDay ?? 0) },
            set: { date in
                var cfg = categorySettings[category] ?? .defaults(for: category)
                cfg.quietEndMinuteOfDay = Self.minute(from: date)
                updateCategorySettings(cfg, for: category)
            }
        )
    }
    private static func date(fromMinute m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    private static func minute(from d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// D-04 / RESEARCH Open Question #2: turning critical break-through OFF is the safety-reducing
    /// direction, so — unlike every other `guardedToggle` site in this app — the confirm is on the OFF
    /// transition, not the ON one. Built by wrapping `guardedToggle` around the INVERTED ("break-through
    /// is off") boolean: turning the real toggle off drives `guardedToggle`'s "on" (confirm) path, and
    /// turning it on drives its "off" (immediate) path. The outer `Binding` still always reads/writes the
    /// real `allowCriticalBreakthrough` value — the inversion is purely internal plumbing.
    private func breakThroughBinding(for category: NotificationBroker.Category) -> Binding<Bool> {
        let offToggle = guardedToggle(
            get: { !(categorySettings[category]?.allowCriticalBreakthrough ?? true) },
            set: { off in setBreakThrough(!off, for: category) },
            requestConfirm: { breakThroughOffCategory = category }
        )
        return Binding(
            get: { !offToggle.wrappedValue },
            set: { allow in offToggle.wrappedValue = !allow }
        )
    }

    private func setBreakThrough(_ allow: Bool, for category: NotificationBroker.Category) {
        var cfg = categorySettings[category] ?? .defaults(for: category)
        cfg.allowCriticalBreakthrough = allow
        updateCategorySettings(cfg, for: category)
    }

    /// The one write-through seam every per-category mutation in this view uses: updates the local
    /// mirror for immediate UI feedback, then persists via the Plan 01 seam so a fresh
    /// `NotificationRuntime` (including an out-of-process poster) honors it.
    private func updateCategorySettings(_ cfg: NotificationBroker.CategorySettings,
                                        for category: NotificationBroker.Category) {
        categorySettings[category] = cfg
        runtime.updateSettings(cfg, for: category)
    }

    // MARK: - Body

    var body: some View {
        Form {
            pumpSection
            criticalAlertsSection
            safetyAlertsSection
            ForEach(tunableAppCategories, id: \.self) { category in
                categorySection(for: category)
            }
        }
        .navigationTitle("Notifications")
        .confirmationDialog("Silence pump alarms in the app?", isPresented: $showSuppressWarning,
                             titleVisibility: .visible) {
            Button("Silence in the app", role: .destructive) { settings.suppressMirroredPumpAlarms = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("faBolus will stop showing a phone notification for pump alarms (like occlusion or low insulin) that your pump already alarms for. Make sure you'll notice the pump's own alarm. faBolus's own safety alerts — pump disconnected, CGM data lost, and unresolved bolus — are not affected.")
        }
        .confirmationDialog("Turn off critical break-through?",
                             isPresented: Binding(get: { breakThroughOffCategory != nil },
                                                  set: { if !$0 { breakThroughOffCategory = nil } }),
                             titleVisibility: .visible) {
            if let category = breakThroughOffCategory {
                Button("Turn off", role: .destructive) {
                    setBreakThrough(false, for: category)
                    breakThroughOffCategory = nil
                }
            }
            Button("Cancel", role: .cancel) { breakThroughOffCategory = nil }
        } message: {
            if let category = breakThroughOffCategory {
                Text("\(category.label)'s urgent/critical alerts will follow your normal enabled/quiet-hours/rate-limit settings instead of always breaking through. You can turn this back on anytime.")
            }
        }
    }

    // MARK: - Sections

    /// (a) Pump-sourced section (D-03): the single `pumpAlert` category's enable/quiet-hours/
    /// break-through controls PLUS the relocated pump-alarm mirror opt-out. Exactly one bucket — no
    /// per-alarm-type enumeration.
    private var pumpSection: some View {
        Section {
            Toggle(NotificationBroker.Category.pumpAlert.label, isOn: enabledBinding(for: .pumpAlert))
            Toggle("Quiet hours", isOn: quietHoursEnabledBinding(for: .pumpAlert))
            if quietHoursEnabledBinding(for: .pumpAlert).wrappedValue {
                DatePicker("From", selection: quietStartBinding(for: .pumpAlert), displayedComponents: .hourAndMinute)
                DatePicker("To", selection: quietEndBinding(for: .pumpAlert), displayedComponents: .hourAndMinute)
            }
            Toggle("Allow critical break-through", isOn: breakThroughBinding(for: .pumpAlert))
            Toggle("Silence pump alarms in the app", isOn: suppressBinding)
        } header: { Text("Pump alerts") } footer: {
            Text("Alerts and alarms relayed from your pump. Critical break-through covers pump alarms (occlusion, low insulin, etc. — always critical-severity). \"Silence pump alarms in the app\" stops faBolus re-notifying you for pump alarms the pump already sounds itself — the pump keeps alarming, and faBolus's own safety alerts are unaffected.")
        }
    }

    /// The relocated `criticalAlertsEnabled` control (D-07) with Phase 8's honest-status caption
    /// preserved verbatim, placed near the critical-tuning UI so the entitlement coupling reads
    /// coherently.
    private var criticalAlertsSection: some View {
        Section {
            Toggle("Use Critical Alerts", isOn: $settings.criticalAlertsEnabled)
            if Self.shouldShowHonestStatus(enabled: settings.criticalAlertsEnabled,
                                           grantActive: settings.criticalAlertGrantActive) {
                Text("Critical Alerts aren't active yet — pending Apple approval. Your safety alerts "
                    + "(pump disconnected, CGM data lost, unresolved bolus) currently use "
                    + "time-sensitive delivery.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Critical Alerts") } footer: {
            Text("Lets faBolus's safety alerts (pump disconnected, CGM data lost, unresolved bolus) alert even when your phone is on silent or Do Not Disturb, where your phone and this build support it. The per-category \"Allow critical break-through\" toggles below control whether an OTHER category's urgent/critical alerts also bypass your quiet hours and limits — the safety alerts above are never affected by those toggles.")
        }
    }

    /// (b) App-generated, non-trio: the never-suppressible trio rendered always-on / non-interactive
    /// (D-05) — its rows cannot be toggled from this screen, and the caption discloses the guarantee
    /// rather than hiding it (mirrors Phase 8's honest-status rationale).
    private var safetyAlertsSection: some View {
        Section {
            ForEach(trioCategories, id: \.self) { category in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(category.label, isOn: .constant(true))
                        .disabled(true)
                    Text("Always delivered — this is a safety alert and cannot be turned off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: { Text("Safety alerts") } footer: {
            Text("Pump disconnected, CGM data loss, and bolus result always reach you — no setting, quiet hours, or budget can suppress them.")
        }
    }

    /// (b) App-generated, tunable: one Section per non-trio category — enable, quiet hours, and
    /// critical break-through (confirm-gated OFF).
    @ViewBuilder
    private func categorySection(for category: NotificationBroker.Category) -> some View {
        Section {
            Toggle("Enabled", isOn: enabledBinding(for: category))
            Toggle("Quiet hours", isOn: quietHoursEnabledBinding(for: category))
            if quietHoursEnabledBinding(for: category).wrappedValue {
                DatePicker("From", selection: quietStartBinding(for: category), displayedComponents: .hourAndMinute)
                DatePicker("To", selection: quietEndBinding(for: category), displayedComponents: .hourAndMinute)
            }
            Toggle("Allow critical break-through", isOn: breakThroughBinding(for: category))
        } header: {
            Text(category.label)
        } footer: {
            Text("Turning off critical break-through means this category's urgent/critical alerts follow your normal enabled/quiet-hours/rate-limit settings instead of always breaking through.")
        }
    }
}
