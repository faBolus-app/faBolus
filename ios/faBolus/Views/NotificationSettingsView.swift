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
    /// 09.25 WR-01: read-only handle used ONLY to reach `model.notificationWithdrawCategorySink` when the
    /// user disables a safety-trio category (`setSafetyEnabled`) — nothing else in this view reads
    /// `model`, so `let` (not `@Bindable`) mirrors `DisplaySettingsView`/`CgmSettingsView`'s convention for
    /// a model handle that's never bound into a control.
    let model: AppModel
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
    /// 09.25-01 (D-03/D-06): the never-suppressible safety trio is now user-disableable behind a
    /// confirm-on-disable warning — turning a trio row OFF is the safety-reducing direction, so it routes
    /// through this dialog; turning it back ON is immediate. Holds the trio category whose confirm dialog
    /// is currently showing (`nil` ⇒ no dialog).
    @State private var safetyDisableOffCategory: NotificationBroker.Category?

    init(model: AppModel, settings: AppSettings) {
        self.model = model
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

    /// 09.25-02 (D-01/D-02): the break-through row's computed effective-state caption — the direct fix
    /// for the D-01 override ambiguity (break-through used to silently override a disabled category).
    /// Pure so it's directly testable without driving the view.
    static func breakThroughCaption(enabled: Bool, allow: Bool) -> String {
        guard enabled else { return "Off — category is disabled, so break-through has no effect." }
        return allow
            ? "On — this category's urgent/critical alerts always break through quiet hours and limits."
            : "Off — this category's urgent/critical alerts follow the normal quiet-hours/limit rules below."
    }

    /// 09.25-02 (D-06): the silence-pump-alarms row's effective-state caption — non-nil ONLY when the
    /// pump section's master is off (the row has no effect while `pumpAlert` is disabled); `nil`
    /// otherwise, since the existing section footer already explains the row while it's live.
    static func silenceMirrorCaption(pumpEnabled: Bool) -> String? {
        pumpEnabled ? nil : "No effect — pump alerts are disabled."
    }

    // MARK: - Per-category bindings

    private func enabledBinding(for category: NotificationBroker.Category) -> Binding<Bool> {
        // 09.25 WR-02: this setter writes `cfg.enabled` WITHOUT touching `userAcknowledgedSafetyDisable`,
        // so a trio category routed through here would desync the pair `decide()`'s AND-gate depends on
        // (the caption/toggle would then show "Off" while `decide()` still correctly delivers). Every
        // trio category must go through `safetyEnabledBinding(for:)` instead, which writes both fields
        // together. Fail LOUDLY (not just in DEBUG — `precondition`, not `assert`) so a future call site
        // can never silently reintroduce the desync this file's own WR-02 fix closed.
        precondition(!category.neverSuppressible,
                     "enabledBinding(for:) must never be used for a never-suppressible trio category "
                     + "(\(category.rawValue)) — use safetyEnabledBinding(for:) instead, which keeps "
                     + "`enabled` and `userAcknowledgedSafetyDisable` paired (09.25 WR-02).")
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

    /// 09.25-01 (D-03/D-06/D-08): the never-suppressible safety trio's confirm-on-disable toggle — mirrors
    /// `breakThroughBinding`'s double-inversion exactly. Built by wrapping `guardedToggle` around the
    /// INVERTED ("disabled") boolean: turning the real toggle OFF drives `guardedToggle`'s "on" (confirm)
    /// path via `safetyDisableOffCategory`, and turning it back ON drives its "off" (immediate) path. The
    /// outer `Binding` always reads/writes the real `enabled` value — the inversion is purely internal
    /// plumbing. Deliberately the `guardedToggle` + `.confirmationDialog` idiom, NOT the dose-path-ack
    /// gate elsewhere in this app (D-08) — that pattern writes a therapy acknowledgment and would
    /// breach the no-dose-path boundary this phase must not cross.
    private func safetyEnabledBinding(for category: NotificationBroker.Category) -> Binding<Bool> {
        Self.safetyTrioToggleBinding(
            enabled: { categorySettings[category]?.enabled ?? true },
            setEnabled: { on in setSafetyEnabled(on, for: category) },
            requestConfirmDisable: { safetyDisableOffCategory = category }
        )
    }

    /// 09.25 IN-01: the safety-trio toggle's double-inversion wiring, extracted verbatim out of
    /// `safetyEnabledBinding` into a standalone (non-`private`) factory over plain closures — so its
    /// Cancel/snap-back contract (turning OFF requests confirm and does NOT write `enabled` until the
    /// confirm button fires) is directly unit-testable with spy closures, without a live view or
    /// `@State`. Mirrors `breakThroughBinding`'s same double-inversion shape.
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

    /// Write BOTH `enabled` and the paired `userAcknowledgedSafetyDisable` flag together, so `decide()`'s
    /// AND-gate (D-03/D-07) always sees a coherent pair: disabling sets both `enabled = false` and
    /// `userAcknowledgedSafetyDisable = true` (the explicit acknowledgment); re-enabling sets `enabled =
    /// true` and clears the ack back to `nil` (so a later disable requires a fresh acknowledgment).
    private func setSafetyEnabled(_ on: Bool, for category: NotificationBroker.Category) {
        var cfg = categorySettings[category] ?? .defaults(for: category)
        cfg.enabled = on
        cfg.userAcknowledgedSafetyDisable = on ? nil : true
        updateCategorySettings(cfg, for: category)
        // 09.25 WR-01: disabling doesn't just change future governance — an escalation step scheduled
        // BEFORE this write (or an already-delivered banner) is still sitting in `UNUserNotificationCenter`
        // and would otherwise fire/linger AFTER the user just confirmed "turn off protection", contradicting
        // the confirm dialog's own "faBolus will no longer alert you" promise. Withdraw everything
        // outstanding for this category right now so the promise is immediately true. Re-enabling needs no
        // symmetric action — there is nothing pending to reinstate; the NEXT event simply posts normally.
        if !on {
            model.notificationWithdrawCategorySink?(category)
        }
    }

    /// The confirm dialog's per-category title (D-06 UI-SPEC "Interaction Contract — Confirm Dialogs")
    /// — each trio category's "what you're giving up" warning is category-specific, unlike the
    /// break-through dialog's one generic templated sentence.
    private func safetyDisableDialogTitle(for category: NotificationBroker.Category?) -> Text {
        switch category {
        case .pumpDisconnect:      return Text("Turn off pump-disconnect alerts?")
        case .cgmDataLoss:         return Text("Turn off CGM-data-loss alerts?")
        case .bolusReconciliation: return Text("Turn off bolus-result alerts?")
        default:                  return Text("")
        }
    }

    /// The trio's computed effective-state caption text (D-06 UI-SPEC "Copy → Caption Mapping"). Pulled
    /// out as a plain `String` (rather than inlined in the `@ViewBuilder` below) so 09.25-02 Task 3 can
    /// feed the SAME value into `.accessibilityValue` on the governing Toggle — VoiceOver announces
    /// exactly what's on screen, never a separately-authored a11y string.
    private func safetyEffectiveStateCaptionText(for category: NotificationBroker.Category) -> String {
        Self.trioIsSuppressed(cfg: categorySettings[category])
            ? "⚠ Off — you turned off this safety protection."
            : "On — always delivered, even during quiet hours or Do Not Disturb."
    }

    /// 09.25 WR-02: mirrors `NotificationBroker.decide()`'s trio AND-gate EXACTLY (`!cfg.enabled &&
    /// cfg.userAcknowledgedSafetyDisable == true`) — the single source of truth this view's caption/toggle
    /// must read, never `cfg.enabled` alone. A nil `cfg` (category not yet in the local mirror) reads as
    /// "on"/not-suppressed, matching every other read site's `?? true`/`?? category.defaultEnabled`
    /// fallback in this file. Kept here (not in faBolusCore) since it's a UI-display mirror of `decide()`,
    /// not a second governance point — `decide()` alone still decides delivery.
    static func trioIsSuppressed(cfg: NotificationBroker.CategorySettings?) -> Bool {
        guard let cfg else { return false }
        return !cfg.enabled && cfg.userAcknowledgedSafetyDisable == true
    }

    /// The trio's computed effective-state caption (D-06 UI-SPEC "Copy → Caption Mapping"), rendered
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

    /// The one write-through seam every per-category mutation in this view uses: updates the local
    /// mirror for immediate UI feedback, then persists via the Plan 01 seam so a fresh
    /// `NotificationRuntime` (including an out-of-process poster) honors it.
    private func updateCategorySettings(_ cfg: NotificationBroker.CategorySettings,
                                        for category: NotificationBroker.Category) {
        categorySettings[category] = cfg
        runtime.updateSettings(cfg, for: category)
    }

    // MARK: - Body

    /// D3-05: visual-density tightening only (grouping/spacing, no toggle/key change) — every
    /// toggle-plus-caption pairing below uses a tighter `spacing: 2` (was 4) so the caption reads as
    /// visually attached to its control rather than as a separate row, without touching any binding,
    /// section boundary, or governance logic.
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
        // 09.25-01 (D-03/D-04/D-06): the trio's confirm-on-disable dialog. Each trio category has a
        // category-specific title AND message body — driven by `safetyDisableDialogTitle` rather than
        // the break-through dialog's fixed-title shape, since the "what you're giving up" warning
        // genuinely differs per category.
        .confirmationDialog(safetyDisableDialogTitle(for: safetyDisableOffCategory),
                             isPresented: Binding(get: { safetyDisableOffCategory != nil },
                                                  set: { if !$0 { safetyDisableOffCategory = nil } }),
                             titleVisibility: .visible) {
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
                Text("If your pump disconnects, faBolus will no longer alert you — including during quiet hours or Do Not Disturb. You may not notice a lost connection until you check the app yourself. You can turn this back on anytime.")
            case .cgmDataLoss:
                Text("If faBolus stops receiving CGM data, you will no longer be alerted — including during quiet hours or Do Not Disturb. You could miss a sensor failure or an extended gap in your glucose readings. You can turn this back on anytime.")
            case .bolusReconciliation:
                Text("faBolus will no longer alert you with the final, authoritative result of a bolus (including an indeterminate delivery that resolves later) — including during quiet hours or Do Not Disturb. You may not learn whether insulin was actually delivered until you check the app yourself. You can turn this back on anytime.")
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Sections

    /// (a) Pump-sourced section (D-03): the single `pumpAlert` category's enable/quiet-hours/
    /// break-through controls PLUS the relocated pump-alarm mirror opt-out. Exactly one bucket — no
    /// per-alarm-type enumeration.
    private var pumpSection: some View {
        // 09.25-02 (D-02): the section's `Enabled` master governs every member control below — greyed
        // via native `.disabled(true)` (never manual `.opacity()`) when off.
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
                    // 09.25-02 Task 3 (D-06 backstop): reuse the SAME on-screen caption for VoiceOver
                    // (mirrors GlucoseChartView.swift:239's `.accessibilityValue` idiom).
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
        } header: { Text("Pump alerts") } footer: {
            Text("Alerts and alarms relayed from your pump. Pump alarms (occlusion, low insulin, etc.) are always critical-severity and — like faBolus's own safety alerts — break through Focus/Do Not Disturb, where your phone and this build support it; an urgent protected alert (e.g. a CGM-loss alert) gets the same treatment even before it rises to alarm-level. \"Silence pump alarms in the app\" stops faBolus re-notifying you for pump alarms the pump already sounds itself — the pump keeps alarming, and faBolus's own safety alerts are unaffected.")
        }
    }

    /// 09.25-02 (D-02c): the relocated `criticalAlertsEnabled` control (D-07), honestly reframed as an
    /// interruption-STRENGTH descriptor — NOT a disable master. Apple's own control name (`Use Critical
    /// Alerts`) and the `criticalAlertsEnabled` binding stay verbatim (kept reachable for
    /// `SettingsReachabilityGuardTests`); only the section's FRAMING changes. This section must gate NO
    /// other row on screen — no `.disabled(...)` anywhere in this view may read `criticalAlertsEnabled`
    /// (pinned by `interruptionStrengthSectionGatesNoOtherRow`). Phase 8's conditional honest-status
    /// caption is preserved verbatim, unchanged, below the NEW always-visible caption.
    private var criticalAlertsSection: some View {
        Section {
            Toggle("Use Critical Alerts", isOn: $settings.criticalAlertsEnabled)
            Text("Makes safety alerts break through Silence and Do Not Disturb. Does not turn any alert "
                + "on or off — use Safety Alerts and the category sections above to control what's "
                + "delivered.")
                .font(.caption).foregroundStyle(.secondary)
            if Self.shouldShowHonestStatus(enabled: settings.criticalAlertsEnabled,
                                           grantActive: settings.criticalAlertGrantActive) {
                Text("Critical Alerts aren't active yet — pending Apple approval. Your safety alerts "
                    + "(pump disconnected, CGM data lost, unresolved bolus) currently use "
                    + "time-sensitive delivery.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Interruption Strength") } footer: {
            Text("Lets faBolus's safety alerts (pump disconnected, CGM data lost, unresolved bolus) alert even when your phone is on silent or Do Not Disturb, where your phone and this build support it. The per-category \"Allow critical break-through\" toggles below control whether an OTHER category's urgent/critical alerts also bypass your quiet hours and limits — the safety alerts above are never affected by those toggles.")
        }
    }

    /// (b) App-generated, non-trio: 09.25-01 (D-03/D-06) — the never-suppressible trio is now
    /// user-disableable behind a confirm-on-disable dialog (`safetyEnabledBinding`); the caption below
    /// each row discloses the current effective state either way (mirrors Phase 8's honest-status
    /// rationale — never hide the guarantee, or its absence).
    private var safetyAlertsSection: some View {
        Section {
            ForEach(trioCategories, id: \.self) { category in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(category.label, isOn: safetyEnabledBinding(for: category))
                        // 09.25-02 Task 3 (D-06 backstop): VoiceOver announces switch-state + the SAME
                        // on-screen effective-state caption as one utterance (mirrors
                        // GlucoseChartView.swift:239's `.accessibilityValue` idiom).
                        .accessibilityValue(Text(safetyEffectiveStateCaptionText(for: category)))
                    safetyEffectiveStateCaption(for: category)
                }
            }
        } header: { Text("Safety alerts") } footer: {
            Text("Pump disconnected, CGM data loss, and bolus result reach you even during quiet hours, Do Not Disturb, or a full daily budget — unless you explicitly turn one off above.")
        }
    }

    /// (b) App-generated, tunable: one Section per non-trio category — enable, quiet hours, and
    /// critical break-through (confirm-gated OFF).
    @ViewBuilder
    private func categorySection(for category: NotificationBroker.Category) -> some View {
        // 09.25-02 (D-02): the section's `Enabled` master governs every member control below — greyed
        // via native `.disabled(true)` (never manual `.opacity()`) when off.
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
                    // 09.25-02 Task 3 (D-06 backstop): reuse the SAME on-screen caption for VoiceOver
                    // (mirrors GlucoseChartView.swift:239's `.accessibilityValue` idiom).
                    .accessibilityValue(Text(breakThroughCaption))
                Text(breakThroughCaption).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(category.label)
        } footer: {
            Text("Turning off critical break-through means this category's urgent/critical alerts follow your normal enabled/quiet-hours/rate-limit settings instead of always breaking through.")
        }
    }
}
