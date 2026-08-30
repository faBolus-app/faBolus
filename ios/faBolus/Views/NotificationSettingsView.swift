import SwiftUI
import faBolusCore

/// Notification controls. Pump-sourced (`pumpAlert`) vs app-generated categories; the never-suppressible
/// trio (`pumpDisconnect` / `cgmDataLoss` / `bolusReconciliation`) is always-on. Governance lives in
/// `NotificationBroker.decide()`, unchanged by this view.
struct NotificationSettingsView: View {
    /// Read-only handle for `model.notificationWithdrawCategorySink` when the user disables a
    /// safety-trio category. Nothing else here binds `model`.
    let model: AppModel
    @Bindable var settings: AppSettings
    @State private var runtime: NotificationRuntime
    /// Local mirror of `runtime.settings`. `NotificationRuntime` isn't `@Observable`, so this
    /// `@State` copy drives the UI and refreshes after every write-through.
    @State private var categorySettings: [NotificationBroker.Category: NotificationBroker.CategorySettings]
    /// Pump-alarm opt-out is safety-reducing — confirm to enable; turning off is immediate.
    @State private var showSuppressWarning = false
    /// Turning critical break-through OFF is safety-reducing — confirm-gated. Nil ⇒ no dialog.
    @State private var breakThroughOffCategory: NotificationBroker.Category?
    /// Safety trio is disableable behind confirm-on-disable. Nil ⇒ no dialog.
    @State private var safetyDisableOffCategory: NotificationBroker.Category?

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        let rt = NotificationRuntime()
        _runtime = State(initialValue: rt)
        _categorySettings = State(initialValue: rt.settings)
    }

    // MARK: - Category groupings

    private var trioCategories: [NotificationBroker.Category] {
        // `pumpConnectionUnstable` is never-suppressible and has no user toggle.
        NotificationBroker.Category.allCases.filter {
            !$0.isPumpSourced && $0.neverSuppressible && $0.isUserConfigurable
        }
    }
    private var tunableAppCategories: [NotificationBroker.Category] {
        NotificationBroker.Category.allCases.filter {
            !$0.isPumpSourced && !$0.neverSuppressible && $0.isUserConfigurable
        }
    }

    // MARK: - Relocated bindings

    /// Pump-alarm opt-out: confirm to enable; off is immediate. Cancel leaves the flag false.
    private var suppressBinding: Binding<Bool> {
        guardedToggle(
            get: { settings.suppressMirroredPumpAlarms },
            set: { settings.suppressMirroredPumpAlarms = $0 },
            requestConfirm: { showSuppressWarning = true }
        )
    }

    /// Show "pending Apple approval" only when the user opted in and the OS grant isn't active yet.
    static func shouldShowHonestStatus(enabled: Bool, grantActive: Bool) -> Bool { enabled && !grantActive }

    /// Effective-state caption so break-through cannot silently override a disabled category.
    static func breakThroughCaption(enabled: Bool, allow: Bool) -> String {
        guard enabled else { return "Off — category is disabled, so break-through has no effect." }
        return allow
            ? "On — this category's urgent/critical alerts always break through quiet hours and limits."
            : "Off — this category's urgent/critical alerts follow the normal quiet-hours/limit rules below."
    }

    /// Silence-pump-alarms caption: non-nil only when the pump master is off (row has no effect).
    static func silenceMirrorCaption(pumpEnabled: Bool) -> String? {
        pumpEnabled ? nil : "No effect — pump alerts are disabled."
    }

    // MARK: - Per-category bindings

    private func enabledBinding(for category: NotificationBroker.Category) -> Binding<Bool> {
        // Writes `enabled` without `userAcknowledgedSafetyDisable` — a trio routed here would
        // desync `decide()`'s AND-gate (toggle "Off" while delivery still happens). Trio categories
        // must use `safetyEnabledBinding`, which writes both. Fail loudly (`precondition`, not
        // `assert`) so a future call site cannot reintroduce that desync.
        precondition(
            !category.neverSuppressible,
            "enabledBinding(for:) must never be used for a never-suppressible trio category "
                + "(\(category.rawValue)) — use safetyEnabledBinding(for:) instead, which keeps "
                + "`enabled` and `userAcknowledgedSafetyDisable` paired.")
        return Binding(
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
                    // start==end is "no window"; seed overnight so the toggle isn't a silent no-op.
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

    /// Confirm on turning break-through OFF (safety-reducing), unlike other `guardedToggle` sites
    /// that confirm ON. Built by inverting the boolean around `guardedToggle`; the outer Binding
    /// still reads/writes the real `allowCriticalBreakthrough`.
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

    /// Trio confirm-on-disable — same inversion as `breakThroughBinding`. Uses `guardedToggle`,
    /// not the dose-path ack gate (that would write a therapy acknowledgment on this screen).
    private func safetyEnabledBinding(for category: NotificationBroker.Category) -> Binding<Bool> {
        Self.safetyTrioToggleBinding(
            enabled: { categorySettings[category]?.enabled ?? true },
            setEnabled: { on in setSafetyEnabled(on, for: category) },
            requestConfirmDisable: { safetyDisableOffCategory = category }
        )
    }

    /// Trio toggle inversion as a factory over closures so Cancel/snap-back (OFF requests confirm
    /// and does not write `enabled` until confirm) is unit-testable without a live view.
    static func safetyTrioToggleBinding(
        enabled: @escaping () -> Bool,
        setEnabled: @escaping (Bool) -> Void,
        requestConfirmDisable: @escaping () -> Void
    ) -> Binding<Bool> {
        let offToggle = guardedToggle(
            get: { !enabled() },
            set: { off in setEnabled(!off) },
            requestConfirm: requestConfirmDisable
        )
        return Binding(
            get: { !offToggle.wrappedValue },
            set: { on in offToggle.wrappedValue = !on }
        )
    }

    /// Write `enabled` and `userAcknowledgedSafetyDisable` together so `decide()`'s AND-gate sees a
    /// coherent pair: disable sets both; re-enable clears the ack so the next disable needs a fresh confirm.
    private func setSafetyEnabled(_ on: Bool, for category: NotificationBroker.Category) {
        var cfg = categorySettings[category] ?? .defaults(for: category)
        cfg.enabled = on
        cfg.userAcknowledgedSafetyDisable = on ? nil : true
        updateCategorySettings(cfg, for: category)
        // Withdraw already-scheduled banners for this category so "faBolus will no longer alert
        // you" is immediately true. Re-enable needs no symmetric restore — the next event posts normally.
        if !on {
            model.notificationWithdrawCategorySink?(category)
        }
    }

    /// Per-category disable title — each trio warning is specific, not one generic sentence.
    private func safetyDisableDialogTitle(for category: NotificationBroker.Category?) -> Text {
        switch category {
        case .pumpDisconnect: return Text("Turn off pump-disconnect alerts?")
        case .cgmDataLoss: return Text("Turn off CGM-data-loss alerts?")
        case .bolusReconciliation: return Text("Turn off bolus-result alerts?")
        case .urgentLowGlucose: return Text("Turn off urgent-low backup alarm?")
        default: return Text("")
        }
    }

    /// Effective-state caption as a String so the same value feeds `.accessibilityValue`.
    private func safetyEffectiveStateCaptionText(for category: NotificationBroker.Category) -> String {
        Self.trioIsSuppressed(cfg: categorySettings[category])
            ? "⚠ Off — you turned off this safety protection."
            : "On — always delivered, even during quiet hours or Do Not Disturb."
    }

    /// Mirrors `NotificationBroker.decide()`'s trio AND-gate (`!enabled && ack == true`) so the
    /// caption never reads `enabled` alone. Display only — `decide()` still decides delivery.
    static func trioIsSuppressed(cfg: NotificationBroker.CategorySettings?) -> Bool {
        guard let cfg else { return false }
        return !cfg.enabled && cfg.userAcknowledgedSafetyDisable == true
    }

    /// The trio's computed effective-state caption, rendered
    /// below each trio row.
    @ViewBuilder
    private func safetyEffectiveStateCaption(for category: NotificationBroker.Category) -> some View {
        if !Self.trioIsSuppressed(cfg: categorySettings[category]) {
            Text(safetyEffectiveStateCaptionText(for: category))
                .font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(safetyEffectiveStateCaptionText(for: category))
            }
            .foregroundStyle(.red)
        }
    }

    /// One write-through: local mirror for UI, then `runtime.updateSettings` for out-of-process posters.
    private func updateCategorySettings(
        _ cfg: NotificationBroker.CategorySettings,
        for category: NotificationBroker.Category
    ) {
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
        .confirmationDialog(
            "Silence pump alarms in the app?", isPresented: $showSuppressWarning,
            titleVisibility: .visible
        ) {
            Button("Silence in the app", role: .destructive) { settings.suppressMirroredPumpAlarms = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "faBolus will stop showing a phone notification for pump alarms (like occlusion or low insulin) that your pump already alarms for. Make sure you'll notice the pump's own alarm. faBolus's own safety alerts — pump disconnected, CGM data lost, and unresolved bolus — are not affected."
            )
        }
        .confirmationDialog(
            "Turn off critical break-through?",
            isPresented: Binding(
                get: { breakThroughOffCategory != nil },
                set: { if !$0 { breakThroughOffCategory = nil } }),
            titleVisibility: .visible
        ) {
            if let category = breakThroughOffCategory {
                Button("Turn off", role: .destructive) {
                    setBreakThrough(false, for: category)
                    breakThroughOffCategory = nil
                }
            }
            Button("Cancel", role: .cancel) { breakThroughOffCategory = nil }
        } message: {
            if let category = breakThroughOffCategory {
                Text(
                    "\(category.label)'s urgent/critical alerts will follow your normal enabled/quiet-hours/rate-limit settings instead of always breaking through. You can turn this back on anytime."
                )
            }
        }
        // Trio confirm-on-disable: category-specific title and body.
        .confirmationDialog(
            safetyDisableDialogTitle(for: safetyDisableOffCategory),
            isPresented: Binding(
                get: { safetyDisableOffCategory != nil },
                set: { if !$0 { safetyDisableOffCategory = nil } }),
            titleVisibility: .visible
        ) {
            if let category = safetyDisableOffCategory {
                Button("Turn off protection", role: .destructive) {
                    setSafetyEnabled(false, for: category)
                    safetyDisableOffCategory = nil
                }
            }
            Button("Cancel", role: .cancel) { safetyDisableOffCategory = nil }
        } message: {
            switch safetyDisableOffCategory {
            case .pumpDisconnect:
                Text(
                    "If your pump disconnects, faBolus will no longer alert you — including during quiet hours or Do Not Disturb. You may not notice a lost connection until you check the app yourself. You can turn this back on anytime."
                )
            case .cgmDataLoss:
                Text(
                    "If faBolus stops receiving CGM data, you will no longer be alerted — including during quiet hours or Do Not Disturb. You could miss a sensor failure or an extended gap in your glucose readings. You can turn this back on anytime."
                )
            case .bolusReconciliation:
                Text(
                    "faBolus will no longer alert you with the final, authoritative result of a bolus (including an indeterminate delivery that resolves later) — including during quiet hours or Do Not Disturb. You may not learn whether insulin was actually delivered until you check the app yourself. You can turn this back on anytime."
                )
            case .urgentLowGlucose:
                Text(
                    "faBolus will no longer sound its backup urgent-low-glucose alarm — the safety net that fires when your pump's CGM feed goes stale and a backup source (e.g. Dexcom Share) reports a dangerously low reading — including during quiet hours or Do Not Disturb. This is separate from the \"CGM data loss\" alert; turning it off means a low caught only by the backup feed may reach you silently or not at all. You can turn this back on anytime."
                )
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Sections

    /// Pump-sourced `pumpAlert` plus the mirror opt-out. One bucket — no per-alarm-type list.
    private var pumpSection: some View {
        // Master enable greys every member via native `.disabled` (never manual opacity).
        let masterOn = enabledBinding(for: .pumpAlert).wrappedValue
        let breakThroughCaption = Self.breakThroughCaption(
            enabled: masterOn, allow: categorySettings[.pumpAlert]?.allowCriticalBreakthrough ?? true)
        return Section {
            Toggle(NotificationBroker.Category.pumpAlert.label, isOn: enabledBinding(for: .pumpAlert))
            Toggle("Quiet hours", isOn: quietHoursEnabledBinding(for: .pumpAlert))
                .disabled(!masterOn)
            if quietHoursEnabledBinding(for: .pumpAlert).wrappedValue {
                DatePicker("From", selection: quietStartBinding(for: .pumpAlert), displayedComponents: .hourAndMinute)
                    .disabled(!masterOn)
                DatePicker("To", selection: quietEndBinding(for: .pumpAlert), displayedComponents: .hourAndMinute)
                    .disabled(!masterOn)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Allow critical break-through", isOn: breakThroughBinding(for: .pumpAlert))
                    .disabled(!masterOn)
                    // Same on-screen caption for VoiceOver.
                    .accessibilityValue(Text(breakThroughCaption))
                Text(breakThroughCaption).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Silence pump alarms in the app", isOn: suppressBinding)
                    .disabled(!masterOn)
                if let silenceCaption = Self.silenceMirrorCaption(pumpEnabled: masterOn) {
                    Text(silenceCaption).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Pump alerts")
        } footer: {
            Text(
                "Alerts and alarms relayed from your pump. Pump alarms (occlusion, low insulin, etc.) are always critical-severity and — like faBolus's own safety alerts — break through Focus/Do Not Disturb, where your phone and this build support it; an urgent protected alert (e.g. a CGM-loss alert) gets the same treatment even before it rises to alarm-level. \"Silence pump alarms in the app\" stops faBolus re-notifying you for pump alarms the pump already sounds itself — the pump keeps alarming, and faBolus's own safety alerts are unaffected."
            )
        }
    }

    /// Interruption-strength, not a disable master. `criticalAlertsEnabled` stays reachable for
    /// `SettingsReachabilityGuardTests`. No other row may `.disabled` off this flag.
    private var criticalAlertsSection: some View {
        Section {
            Toggle("Use Critical Alerts", isOn: $settings.criticalAlertsEnabled)
            Text(
                "Makes safety alerts break through Silence and Do Not Disturb. Does not turn any alert "
                    + "on or off — use Safety Alerts and the category sections above to control what's "
                    + "delivered."
            )
            .font(.caption).foregroundStyle(.secondary)
            if Self.shouldShowHonestStatus(
                enabled: settings.criticalAlertsEnabled,
                grantActive: settings.criticalAlertGrantActive)
            {
                Text(
                    "Critical Alerts aren't active yet — pending Apple approval. Your safety alerts "
                        + "(pump disconnected, CGM data lost, unresolved bolus) currently use "
                        + "time-sensitive delivery."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Interruption Strength")
        } footer: {
            Text(
                "Lets faBolus's safety alerts (pump disconnected, CGM data lost, unresolved bolus) alert even when your phone is on silent or Do Not Disturb, where your phone and this build support it. The per-category \"Allow critical break-through\" toggles below control whether an OTHER category's urgent/critical alerts also bypass your quiet hours and limits — the safety alerts above are never affected by those toggles."
            )
        }
    }

    /// Never-suppressible trio, disableable behind confirm. Caption always discloses effective state.
    private var safetyAlertsSection: some View {
        Section {
            ForEach(trioCategories, id: \.self) { category in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(category.label, isOn: safetyEnabledBinding(for: category))
                        // VoiceOver: switch state + the same on-screen caption.
                        .accessibilityValue(Text(safetyEffectiveStateCaptionText(for: category)))
                    safetyEffectiveStateCaption(for: category)
                }
            }
        } header: {
            Text("Safety alerts")
        } footer: {
            Text(
                "Pump disconnected, CGM data loss, and bolus result reach you even during quiet hours, Do Not Disturb, or a full daily budget — unless you explicitly turn one off above."
            )
        }
    }

    /// One section per tunable (non-trio) category — enable, quiet hours, confirm-gated OFF break-through.
    @ViewBuilder
    private func categorySection(for category: NotificationBroker.Category) -> some View {
        // Master enable greys every member via native `.disabled` (never manual opacity).
        let masterOn = enabledBinding(for: category).wrappedValue
        let breakThroughCaption = Self.breakThroughCaption(
            enabled: masterOn, allow: categorySettings[category]?.allowCriticalBreakthrough ?? true)
        Section {
            Toggle("Enabled", isOn: enabledBinding(for: category))
            Toggle("Quiet hours", isOn: quietHoursEnabledBinding(for: category))
                .disabled(!masterOn)
            if quietHoursEnabledBinding(for: category).wrappedValue {
                DatePicker("From", selection: quietStartBinding(for: category), displayedComponents: .hourAndMinute)
                    .disabled(!masterOn)
                DatePicker("To", selection: quietEndBinding(for: category), displayedComponents: .hourAndMinute)
                    .disabled(!masterOn)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Allow critical break-through", isOn: breakThroughBinding(for: category))
                    .disabled(!masterOn)
                    // Same on-screen caption for VoiceOver.
                    .accessibilityValue(Text(breakThroughCaption))
                Text(breakThroughCaption).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(category.label)
        } footer: {
            Text(
                "Turning off critical break-through means this category's urgent/critical alerts follow your normal enabled/quiet-hours/rate-limit settings instead of always breaking through."
            )
        }
    }
}
