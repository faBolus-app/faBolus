import SwiftUI
import faBolusCore

/// Notification controls, all on the unified Off/Quiet/Alert/Urgent ladder. Pump-mirror alerts
/// (`pumpAlert`) render grouped in `pumpMirrorSection`; the app's OWN alerts render in
/// `appOwnSafetyLadderSection` (the five-member safety set — `pumpDisconnect`, `bolusReconciliation`,
/// `pumpConnectionUnstable`, `urgentLowGlucose`; `cgmDataLoss` never notifies so it has no row) and
/// `governedAppOwnSection` (the governed rest, grouped together). Lowering any safety category below its Alert default —
/// aimed OR via the app-own source one-move control (an inherited rule that cascades to safety per
/// Amendment B) — fires the one-time safety-lowering warning. Governance lives in
/// `NotificationBroker.decide()` and `NotificationRules`, unchanged by this view.
struct NotificationSettingsView: View {
    /// Read-only handle for `model.notificationWithdrawCategorySink` when the user lowers a safety
    /// category to Off. Nothing else here binds `model`.
    let model: AppModel
    @Bindable var settings: AppSettings
    @State private var runtime: NotificationRuntime
    /// Local mirror of `runtime.settings`. `NotificationRuntime` isn't `@Observable`, so this
    /// `@State` copy drives the UI and refreshes after every write-through.
    @State private var categorySettings: [NotificationBroker.Category: NotificationBroker.CategorySettings]
    /// A ladder change that would lower a safety group/category below its default is held here
    /// pending confirmation (Decision 2) — nil ⇒ no dialog. The read always reflects the last-applied
    /// value until confirmed, so Cancel's snap-back is free.
    @State private var pendingSafetyLower: PendingSafetyLower?

    /// A pending, not-yet-applied ladder change that would lower a safety group/category below its default.
    enum PendingSafetyLower: Equatable {
        case group(NotificationRules.PumpMirrorGroup, NotificationRules.Intent)
        case source(NotificationRules.Intent)
        /// An app-own safety category lowered below its default — distinct from the
        /// pump-mirror cases above because the confirm message must not claim the pump alarms on its
        /// own screen for these (it does not; faBolus is their only annunciator).
        case appOwnCategory(NotificationBroker.Category, NotificationRules.Intent)
        /// The app-own SOURCE one-move control lowered below the safety default — an inherited rule
        /// that cascades to every app-own safety category (Amendment B), so it warns like an aimed one.
        case appOwnSource(NotificationRules.Intent)
    }

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        let rt = NotificationRuntime()
        _runtime = State(initialValue: rt)
        _categorySettings = State(initialValue: rt.settings)
    }

    // MARK: - Category groupings

    /// The app-own SAFETY categories that render a ladder row: the safety set minus any that never
    /// notify. `cgmDataLoss` is safety-set but `deliversAsNotification == false`, so it renders no row
    /// and no lowering dialog — offering controls for a condition that cannot notify is a false
    /// statement, so the filter drives off the same predicate `decide()` reads.
    private var appOwnSafetyCategories: [NotificationBroker.Category] {
        NotificationBroker.Category.allCases.filter {
            !$0.isPumpSourced && $0.isSafetySet && $0.deliversAsNotification
        }
    }
    /// The app-own GOVERNED (non-safety) categories — everything app-generated that is not on the
    /// safety set and does notify.
    private var tunableAppCategories: [NotificationBroker.Category] {
        NotificationBroker.Category.allCases.filter {
            !$0.isPumpSourced && !$0.isSafetySet && $0.deliversAsNotification
        }
    }

    // MARK: - Per-category bindings

    private func enabledBinding(for category: NotificationBroker.Category) -> Binding<Bool> {
        // Only GOVERNED (non-safety) categories use a plain enable toggle. A safety-set category
        // resolves through the ladder, never this flag — fail loudly (`precondition`, not `assert`) so a
        // future call site cannot route one here and desync it from what `decide()` actually reads.
        precondition(
            !category.isSafetySet,
            "enabledBinding(for:) must never be used for a safety-set category "
                + "(\(category.rawValue)) — safety categories are tuned through the ladder, not `enabled`.")
        return Binding(
            get: { categorySettings[category]?.enabled ?? category.defaultEnabled },
            set: { on in
                var cfg = categorySettings[category] ?? .defaults(for: category)
                cfg.enabled = on
                updateCategorySettings(cfg, for: category)
            }
        )
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
            appOwnSafetyLadderSection
            governedAppOwnSection
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
            case .appOwnCategory(let category, _):
                appOwnCategoryLowerMessage(for: category)
            case .appOwnSource:
                Text(
                    "faBolus is the only thing watching for these — your pump does not alarm for them. Lowering all of them at once makes faBolus quieter (or silent) about a dropped pump link, a bolus result, an unstable connection, and the backup urgent-low alarm. You can raise them back to their defaults anytime."
                )
            default:
                Text(
                    "Your pump keeps alarming on its own screen for this — faBolus will just be quieter (or silent) about it here. You can raise this back to its default anytime."
                )
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
        case .appOwnSource(let newValue): applyAppOwnSourceOverride(newValue)
        }
    }

    // MARK: - App-own safety ladder (the five-member safety set)

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
        // this" is immediately true.
        if newValue == .off {
            model.notificationWithdrawCategorySink?(category)
        }
    }

    /// The one-move app-own SOURCE override (Decision 1c / Amendment B): "follow each category below"
    /// (no override — the default) or a single rung that lowers/raises every app-own safety category at
    /// once. Because the source level cascades to safety categories that have no override of their own,
    /// a rung below the safety default here is gated by the same one-time warning as an aimed lowering.
    private var appOwnSourceOverrideChoiceBinding: Binding<SourceOverrideChoice> {
        Binding(
            get: {
                if let intent = settings.notificationRules.appOwnSourceOverride?.intent {
                    return .intent(intent)
                }
                return .followEachCategory
            },
            set: { choice in
                switch choice {
                case .followEachCategory:
                    applyAppOwnSourceOverride(nil)
                case .intent(let newValue):
                    if newValue < NotificationRules.appOwnSafetyDefaultIntent {
                        pendingSafetyLower = .appOwnSource(newValue)
                    } else {
                        applyAppOwnSourceOverride(newValue)
                    }
                }
            }
        )
    }

    private func applyAppOwnSourceOverride(_ newValue: NotificationRules.Intent?) {
        settings.notificationRules.appOwnSourceOverride = newValue.map { NotificationRules.Rule(intent: $0) }
    }

    /// Per-category wording for the one-time safety-lowering warning. Each safety category is specific —
    /// what faBolus alone watches for — so the user understands exactly what goes quiet. `cgmDataLoss`
    /// never renders a row, so it never reaches this dialog.
    private func appOwnCategoryLowerMessage(for category: NotificationBroker.Category) -> Text {
        switch category {
        case .pumpDisconnect:
            return Text(
                "faBolus is the only thing watching your phone's link to the pump — your pump does not alarm when that link drops. Lowering this makes faBolus quieter (or silent) when it can no longer reach your pump. You can raise it back to its default anytime."
            )
        case .bolusReconciliation:
            return Text(
                "faBolus is the only thing that tells you the final, authoritative result of a bolus (including an indeterminate delivery that resolves later). Lowering this makes it quieter (or silent) — you may not learn whether insulin was actually delivered until you check the app yourself. You can raise it back to its default anytime."
            )
        case .pumpConnectionUnstable:
            return Text(
                "faBolus is the only thing watching for a pump link that keeps flapping — your pump does not alarm for it. Lowering this makes faBolus quieter (or silent) about an unstable connection. You can raise it back to its default anytime."
            )
        case .urgentLowGlucose:
            return Text(
                "faBolus is the only thing that sounds this backup urgent-low-glucose alarm — the safety net that fires when your pump's CGM feed goes stale and a backup source reports a dangerously low reading. Lowering it means a low caught only by the backup feed may reach you quietly or not at all. You can raise it back to its default anytime."
            )
        default:
            return Text(
                "faBolus is the only thing watching for this — your pump does not alarm for it. Lowering this makes faBolus quieter (or silent) about it. You can raise it back to its default anytime."
            )
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

    /// The app-own "faBolus alerts" section (Decision 1c source grouping): faBolus is the ONLY
    /// annunciator for these categories, so they default to Alert and are tunable down to Off — a
    /// one-move source control at the top, then each safety category's own rung. `cgmDataLoss` is
    /// deliberately absent (it never notifies, so a row for it would be a false statement).
    private var appOwnSafetyLadderSection: some View {
        let sourceIntents = Self.availablePhoneIntents(
            timeSensitiveAvailable: NotificationCapability.timeSensitiveAvailable)
        return Section {
            Picker("All faBolus alerts", selection: appOwnSourceOverrideChoiceBinding) {
                Text("Follow each category below").tag(SourceOverrideChoice.followEachCategory)
                ForEach(sourceIntents, id: \.self) { intent in
                    Text(Self.intentLabel(intent)).tag(SourceOverrideChoice.intent(intent))
                }
            }
            ForEach(appOwnSafetyCategories, id: \.self) { category in
                appOwnSafetyCategoryRow(category)
            }
        } header: {
            Text("faBolus alerts")
        } footer: {
            Text(
                "Alerts faBolus raises itself — your pump does not alarm for these. They default to Alert and can be raised to break through Do Not Disturb (where allowed), or lowered, even to Off. Lowering one below its default asks you to confirm, because faBolus is your only annunciator for it."
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

    /// The governed (non-safety) app-own categories, grouped in ONE section under the same app-own source
    /// (Decision 1c) rather than a separate per-category section each. These are not safety-set: they keep
    /// their own enable governance (and, where they permit it, their snooze — `remoteBolusRejected`'s 2 h
    /// snooze), so they render an enable toggle rather than the ladder, whose resolver path would bypass
    /// that snooze and the daily budget. Lowering one never trips the safety-lowering warning.
    private var governedAppOwnSection: some View {
        Section {
            ForEach(tunableAppCategories, id: \.self) { category in
                Toggle(category.label, isOn: enabledBinding(for: category))
            }
        } header: {
            Text("Other faBolus notifications")
        } footer: {
            Text(
                "Other notifications faBolus raises itself, such as a rejected remote bolus or an unresolved dose. Turn any off here; these are not safety alarms and do not break through Do Not Disturb."
            )
        }
    }
}
