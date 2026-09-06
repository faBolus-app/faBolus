import SwiftUI
import faBolusCore

/// Notification controls. Pump-sourced (`pumpAlert`) vs app-generated categories. `pumpDisconnect` is
/// wired onto the unified Off/Quiet/Alert/Urgent ladder (the app-own "safety set") and
/// rendered in `appOwnSafetyLadderSection`; the remaining never-suppressible categories
/// (`bolusReconciliation` / `urgentLowGlucose` / `cgmDataLoss`) still render through the older
/// always-on-unless-acknowledged toggle in `safetyAlertsSection`. Governance lives in
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
    /// Safety trio is disableable behind confirm-on-disable. Nil ⇒ no dialog.
    @State private var safetyDisableOffCategory: NotificationBroker.Category?
    /// A pump-mirror ladder change that would lower a safety group below its default is held here
    /// pending confirmation (Decision 2) — nil ⇒ no dialog. The read always reflects the last-applied
    /// value until confirmed, so Cancel's snap-back is free.
    @State private var pendingSafetyLower: PendingSafetyLower?

    /// A pending, not-yet-applied ladder change that would lower a safety group below its default.
    enum PendingSafetyLower: Equatable {
        case group(NotificationRules.PumpMirrorGroup, NotificationRules.Intent)
        case source(NotificationRules.Intent)
        /// An app-own safety category lowered below its default — distinct from the
        /// pump-mirror cases above because the confirm message must not claim the pump alarms on its
        /// own screen for these (it does not; faBolus is their only annunciator).
        case appOwnCategory(NotificationBroker.Category, NotificationRules.Intent)
    }

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        let rt = NotificationRuntime()
        _runtime = State(initialValue: rt)
        _categorySettings = State(initialValue: rt.settings)
    }

    // MARK: - Category groupings

    private var trioCategories: [NotificationBroker.Category] {
        // `pumpConnectionUnstable` is never-suppressible and has no user toggle. `deliversAsNotification`
        // excludes any category that never notifies (currently `cgmDataLoss`): rendering a
        // toggle/caption/dialog for a condition that cannot notify is a false statement, so the filter
        // drives off the same predicate `decide()` reads rather than a hard-coded exclusion. `isSafetySet`
        // excludes a category migrated onto the unified ladder (currently `pumpDisconnect`, rendered by
        // `appOwnSafetyLadderSection` instead) — its old enable/ack toggle no longer drives `decide()`.
        NotificationBroker.Category.allCases.filter {
            !$0.isPumpSourced && $0.neverSuppressible && $0.isUserConfigurable && $0.deliversAsNotification
                && !$0.isSafetySet
        }
    }
    private var tunableAppCategories: [NotificationBroker.Category] {
        NotificationBroker.Category.allCases.filter {
            !$0.isPumpSourced && !$0.neverSuppressible && $0.isUserConfigurable
        }
    }

    // MARK: - Relocated bindings

    /// Show "pending Apple approval" only when the user opted in and the OS grant isn't active yet.
    static func shouldShowHonestStatus(enabled: Bool, grantActive: Bool) -> Bool { enabled && !grantActive }

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

    /// Trio confirm-on-disable — same inversion as the trio's own toggle. Uses `guardedToggle`,
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
        case .bolusReconciliation: return Text("Turn off bolus-result alerts?")
        case .urgentLowGlucose: return Text("Turn off urgent-low backup alarm?")
        default: return Text("")
        }
    }

    /// Effective-state caption as a String so the same value feeds `.accessibilityValue`.
    private func safetyEffectiveStateCaptionText(for category: NotificationBroker.Category) -> String {
        Self.trioIsSuppressed(cfg: categorySettings[category])
            ? "⚠ Off — you turned off this safety protection."
            : "On — always delivered, even during Do Not Disturb."
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
            pumpMirrorSection
            criticalAlertsSection
            appOwnSafetyLadderSection
            safetyAlertsSection
            ForEach(tunableAppCategories, id: \.self) { category in
                categorySection(for: category)
            }
        }
        .navigationTitle("Notifications")
        .confirmationDialog(
            "Lower this safety alert?",
            isPresented: Binding(
                get: { pendingSafetyLower != nil },
                set: { if !$0 { pendingSafetyLower = nil } }),
            titleVisibility: .visible
        ) {
            if let pending = pendingSafetyLower {
                Button("Lower it", role: .destructive) {
                    applyPendingSafetyLower(pending)
                    pendingSafetyLower = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingSafetyLower = nil }
        } message: {
            switch pendingSafetyLower {
            case .appOwnCategory:
                Text(
                    "faBolus is the only thing watching for this — your pump does not alarm for it. Lowering this makes faBolus quieter (or silent) about it. You can raise this back to its default anytime."
                )
            default:
                Text(
                    "Your pump keeps alarming on its own screen for this — faBolus will just be quieter (or silent) about it here. You can raise this back to its default anytime."
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
            case .bolusReconciliation:
                Text(
                    "faBolus will no longer alert you with the final, authoritative result of a bolus (including an indeterminate delivery that resolves later) — including during Do Not Disturb. You may not learn whether insulin was actually delivered until you check the app yourself. You can turn this back on anytime."
                )
            case .urgentLowGlucose:
                Text(
                    "faBolus will no longer sound its backup urgent-low-glucose alarm — the safety net that fires when your pump's CGM feed goes stale and a backup source (e.g. Dexcom Share) reports a dangerously low reading — including during Do Not Disturb. This is separate from the \"CGM data loss\" alert; turning it off means a low caught only by the backup feed may reach you silently or not at all. You can turn this back on anytime."
                )
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Sections

    // MARK: - Pump-mirror ladder (Off/Quiet/Alert/Urgent), source-labeled, capability-gated

    /// The phone-side rungs a build can offer: the top (Urgent / break-through-Focus) rung is ABSENT
    /// — never disabled/greyed — when this build lacks the time-sensitive capability, so the ladder
    /// simply tops out at Alert (Decision 3).
    static func availablePhoneIntents(timeSensitiveAvailable: Bool) -> [NotificationRules.Intent] {
        timeSensitiveAvailable ? [.off, .quiet, .alert, .urgent] : [.off, .quiet, .alert]
    }

    /// The watch-side rungs, independent of the phone's capability: the Garmin ladder has no
    /// Urgent/breakthrough rung at all (§1a/§1d), so this list never includes it either way.
    static let availableWatchIntents: [NotificationRules.Intent] = [.off, .quiet, .alert]

    /// A safety group is one whose fatigue-averse default is `Alert` — exactly
    /// `NotificationRules.defaultIntent(for:)`'s own grouping, kept as a separate accessor here so the
    /// UI's "lower than default" check names the safety set explicitly rather than re-deriving it.
    static func isSafetyGroup(_ group: NotificationRules.PumpMirrorGroup) -> Bool {
        NotificationRules.defaultIntent(for: group) == .alert
    }

    static func pumpMirrorGroupLabel(_ group: NotificationRules.PumpMirrorGroup) -> String {
        switch group {
        case .deliveryStopped: return "Delivery stopped / pump alarm"
        case .runningLow: return "Running low (insulin or power)"
        case .urgentLowGlucose: return "Urgent low glucose"
        case .glucoseAndControlIQ: return "Glucose level and Control-IQ"
        case .cgmSensorAndTransmitter: return "CGM sensor and transmitter"
        case .pumpRoutine: return "Pump reminders and routine"
        }
    }

    static func intentLabel(_ intent: NotificationRules.Intent) -> String {
        switch intent {
        case .off: return "Off"
        case .quiet: return "Quiet"
        case .alert: return "Alert"
        case .urgent: return "Urgent"
        }
    }

    /// Read/write one group's phone-side ladder rung. Reading always returns the real resolved value
    /// (the user's override, or the group's fatigue-averse default); writing a value BELOW a safety
    /// group's default holds it pending confirmation instead of applying it immediately.
    private func pumpMirrorGroupIntentBinding(
        _ group: NotificationRules.PumpMirrorGroup
    ) -> Binding<NotificationRules.Intent> {
        Binding(
            get: {
                settings.notificationRules.groupOverrides[group.rawValue]?.intent
                    ?? NotificationRules.defaultIntent(for: group)
            },
            set: { newValue in
                if Self.isSafetyGroup(group), newValue < NotificationRules.defaultIntent(for: group) {
                    pendingSafetyLower = .group(group, newValue)
                } else {
                    applyGroupIntent(newValue, for: group)
                }
            }
        )
    }

    private func applyGroupIntent(_ newValue: NotificationRules.Intent, for group: NotificationRules.PumpMirrorGroup) {
        var rule = settings.notificationRules.groupOverrides[group.rawValue] ?? NotificationRules.Rule()
        rule.intent = newValue
        settings.notificationRules.groupOverrides[group.rawValue] = rule
    }

    /// One optional per-group watch override (§1d) — `nil` ⇒ "follow phone" (the default); an explicit
    /// choice pins the watch to its own rung on the no-Urgent watch ladder, independent of the phone.
    private enum WatchOverrideChoice: Hashable {
        case followPhone
        case intent(NotificationRules.Intent)
    }

    private func pumpMirrorGroupWatchOverrideBinding(
        _ group: NotificationRules.PumpMirrorGroup
    ) -> Binding<WatchOverrideChoice> {
        Binding(
            get: {
                if let watch = settings.notificationRules.groupOverrides[group.rawValue]?.watchOverride {
                    return .intent(watch)
                }
                return .followPhone
            },
            set: { choice in
                var rule = settings.notificationRules.groupOverrides[group.rawValue] ?? NotificationRules.Rule()
                switch choice {
                case .followPhone: rule.watchOverride = nil
                case .intent(let value): rule.watchOverride = value
                }
                settings.notificationRules.groupOverrides[group.rawValue] = rule
            }
        )
    }

    /// The one-move pump-mirror SOURCE override (Decision 1c): "follow each category below" (no
    /// override — the default) or a single rung that silences/quiets/raises every group at once,
    /// unless a group has its own category-level override (which still wins).
    private enum SourceOverrideChoice: Hashable {
        case followEachCategory
        case intent(NotificationRules.Intent)
    }

    private var sourceOverrideChoiceBinding: Binding<SourceOverrideChoice> {
        Binding(
            get: {
                if let intent = settings.notificationRules.sourceOverride?.intent {
                    return .intent(intent)
                }
                return .followEachCategory
            },
            set: { choice in
                switch choice {
                case .followEachCategory:
                    applySourceOverride(nil)
                case .intent(let newValue):
                    // Amendment B: a source-level rule cascades to safety groups too, so a rung below
                    // the safety default here can silence/quiet a group that has no category override
                    // of its own — conservatively gate on it the same way a direct group edit is.
                    if newValue < .alert {
                        pendingSafetyLower = .source(newValue)
                    } else {
                        applySourceOverride(newValue)
                    }
                }
            }
        )
    }

    private func applySourceOverride(_ newValue: NotificationRules.Intent?) {
        settings.notificationRules.sourceOverride = newValue.map { NotificationRules.Rule(intent: $0) }
    }

    private func applyPendingSafetyLower(_ pending: PendingSafetyLower) {
        switch pending {
        case .group(let group, let newValue): applyGroupIntent(newValue, for: group)
        case .source(let newValue): applySourceOverride(newValue)
        case .appOwnCategory(let category, let newValue): applyAppOwnCategoryIntent(newValue, for: category)
        }
    }

    // MARK: - App-own safety ladder — one wired category so far (`.pumpDisconnect`)

    /// Read/write one app-own safety category's phone-side ladder rung. Reading always returns the
    /// real resolved value (the user's override, or `appOwnSafetyDefaultIntent`); writing a value
    /// BELOW the default holds it pending confirmation instead of applying it immediately.
    private func appOwnCategoryIntentBinding(
        _ category: NotificationBroker.Category
    ) -> Binding<NotificationRules.Intent> {
        Binding(
            get: {
                settings.notificationRules.appOwnCategoryOverrides[category.rawValue]?.intent
                    ?? NotificationRules.appOwnSafetyDefaultIntent
            },
            set: { newValue in
                if newValue < NotificationRules.appOwnSafetyDefaultIntent {
                    pendingSafetyLower = .appOwnCategory(category, newValue)
                } else {
                    applyAppOwnCategoryIntent(newValue, for: category)
                }
            }
        )
    }

    private func applyAppOwnCategoryIntent(
        _ newValue: NotificationRules.Intent, for category: NotificationBroker.Category
    ) {
        var rule = settings.notificationRules.appOwnCategoryOverrides[category.rawValue] ?? NotificationRules.Rule()
        rule.intent = newValue
        settings.notificationRules.appOwnCategoryOverrides[category.rawValue] = rule
        // Withdraw any already-outstanding banner for this category so "faBolus will be quieter about
        // this" is immediately true, mirroring `setSafetyEnabled`'s withdraw-on-disable behavior above.
        if newValue == .off {
            model.notificationWithdrawCategorySink?(category)
        }
    }

    /// One row per app-own SAFETY category wired onto the unified ladder: the phone-side
    /// Off/Quiet/Alert/Urgent picker. No watch row — zero app-own categories reach the watch relay yet,
    /// so there is nothing to override here.
    @ViewBuilder
    private func appOwnSafetyCategoryRow(_ category: NotificationBroker.Category) -> some View {
        let phoneIntents = Self.availablePhoneIntents(
            timeSensitiveAvailable: NotificationCapability.timeSensitiveAvailable)
        Picker(category.label, selection: appOwnCategoryIntentBinding(category)) {
            ForEach(phoneIntents, id: \.self) { intent in
                Text(Self.intentLabel(intent)).tag(intent)
            }
        }
    }

    /// The app-own safety-set section: faBolus is the ONLY annunciator for these
    /// categories, so they default to Alert and are individually tunable down to Off, unlike the
    /// pump-mirror ladder's "your pump alarms too" framing.
    private var appOwnSafetyLadderSection: some View {
        Section {
            ForEach(NotificationBroker.Category.allCases.filter { $0.isSafetySet }, id: \.self) { category in
                appOwnSafetyCategoryRow(category)
            }
        } header: {
            Text("App safety alerts")
        } footer: {
            Text(
                "faBolus is the only thing watching for these — your pump does not alarm for them. They default to Alert and can be raised to break through Do Not Disturb (where allowed), or lowered, even to Off."
            )
        }
    }

    /// One row per pump-mirror group: the phone-side ladder Picker plus its optional watch override.
    @ViewBuilder
    private func pumpMirrorGroupRow(_ group: NotificationRules.PumpMirrorGroup) -> some View {
        let phoneIntents = Self.availablePhoneIntents(
            timeSensitiveAvailable: NotificationCapability.timeSensitiveAvailable)
        VStack(alignment: .leading, spacing: 2) {
            Picker(Self.pumpMirrorGroupLabel(group), selection: pumpMirrorGroupIntentBinding(group)) {
                ForEach(phoneIntents, id: \.self) { intent in
                    Text(Self.intentLabel(intent)).tag(intent)
                }
            }
            Picker("Watch", selection: pumpMirrorGroupWatchOverrideBinding(group)) {
                Text("Follow phone").tag(WatchOverrideChoice.followPhone)
                ForEach(Self.availableWatchIntents, id: \.self) { intent in
                    Text(Self.intentLabel(intent)).tag(WatchOverrideChoice.intent(intent))
                }
            }
            .font(.caption)
        }
    }

    /// Pump-mirror categories, grouped and labeled as coming from the pump (Decision 1c): a per-group
    /// Off/Quiet/Alert/(Urgent) ladder driven by the persisted rules store plus a one-move source-level
    /// override. The old standalone "silence pump alarms" opt-out is subsumed by this ladder — setting
    /// the `deliveryStopped` group to `Off` is the equivalent, unified move.
    private var pumpMirrorSection: some View {
        let sourceIntents = Self.availablePhoneIntents(
            timeSensitiveAvailable: NotificationCapability.timeSensitiveAvailable)
        return Section {
            Picker("All pump alerts", selection: sourceOverrideChoiceBinding) {
                Text("Follow each category below").tag(SourceOverrideChoice.followEachCategory)
                ForEach(sourceIntents, id: \.self) { intent in
                    Text(Self.intentLabel(intent)).tag(SourceOverrideChoice.intent(intent))
                }
            }
            ForEach(NotificationRules.PumpMirrorGroup.allCases, id: \.self) { group in
                pumpMirrorGroupRow(group)
            }
        } header: {
            Text("Pump alerts (mirrored from your pump's own alarms)")
        } footer: {
            Text(
                "Alerts and alarms relayed from your pump, grouped the way your pump groups them. Set each group's rung for how faBolus notifies you here on your phone and watch — the top rung, when available and allowed by iOS, breaks through Focus/Do Not Disturb. Your pump keeps alarming on its own screen no matter what you choose here. Set a group to \"Off\" to stop faBolus re-notifying you for alerts the pump already sounds itself."
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
                        + "(pump disconnected, urgent-low backup alarm, unresolved bolus) currently use "
                        + "time-sensitive delivery."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Interruption Strength")
        } footer: {
            Text(
                "Lets faBolus's safety alerts (pump disconnected, urgent-low backup alarm, unresolved bolus) alert even when your phone is on silent or Do Not Disturb, where your phone and this build support it. It does not turn any alert on or off by itself."
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
                "Urgent-low backup alarm and bolus result reach you even during Do Not Disturb or a full daily budget — unless you explicitly turn one off above. Pump-disconnect alerts moved to their own tunable rung below."
            )
        }
    }

    /// One section per tunable (non-trio, non-pump) category — enable only. The old per-category
    /// "Allow critical break-through" toggle is retired with the force-protection axis it tuned.
    @ViewBuilder
    private func categorySection(for category: NotificationBroker.Category) -> some View {
        Section {
            Toggle("Enabled", isOn: enabledBinding(for: category))
        } header: {
            Text(category.label)
        }
    }
}
