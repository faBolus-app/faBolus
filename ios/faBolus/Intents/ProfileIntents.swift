import AppIntents
import faBolusCore
import Foundation

/// Write App Intent for a headless profile-activation Shortcuts action (999.2, D-02). Mirrors
/// `SetTempRateIntent` (`TempRateIntents.swift`) exactly: `openAppWhenRun = false` keeps it silent, and
/// it calls through the same `*Automation`-shaped gated orchestrator (`ProfileAutomation`) rather than
/// talking to `AppModel`/the backend directly.
///
/// `isDiscoverable` is left at its Apple-default `true` — the intent is discoverable as a Shortcuts
/// **action** with no `AppShortcutsProvider` entry required (06-RESEARCH Pattern 3). It is deliberately
/// **NOT** added to `FaBolusShortcuts.appShortcuts` (`StatusIntents.swift`) — no Siri voice phrase, per
/// D-02/D-07/§8-L7. That exclusion is regression-guarded by `ShortcutsL7BoundaryTests`.
///
/// **This intent's headless success rate is structurally different from `SetTempRateIntent`'s (D-02,
/// §13):** `ProfileAutomation.request` routes through `AppModel.setActiveProfile`, which is gated
/// `.unverifiedAck` — a headless run can NEVER supply the required live in-app acknowledgment, so this
/// intent HONESTLY REFUSES on every unattended macro invocation. It only ever completes when a fresh
/// acknowledgment is already on record (e.g. a Shortcut that opens the app first and lets the user
/// confirm interactively). The `description` below says so explicitly — never advertise this as
/// equivalent to the silent temp-rate/mode write intents.
struct ActivateProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Activate Profile"
    static let description = IntentDescription(
        """
        Switch your Tandem pump's active Personal Profile. This ALWAYS needs a fresh in-app \
        confirmation first — it can't complete silently in an unattended macro. Use it in a Shortcut \
        that opens faBolus and lets you confirm, not as a standalone automation trigger.
        """)
    static let openAppWhenRun = false

    @Parameter(title: "Profile")
    var profile: ProfileEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Activate profile \(\.$profile)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await ProfileAutomation.request(idpId: profile.id)
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}

/// `AppEntity` wrapping `PumpProfileInfo` (`Models.swift:488-499`) for the `ActivateProfileIntent`
/// picker. Adapted from Apple's official `EntityQuery` docs example (06-RESEARCH Pattern 2) — faBolus
/// has no other `AppEntity` to mirror.
struct ProfileEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Insulin Profile")
    }
    static let defaultQuery = ProfileEntityQuery()

    /// `PumpProfileInfo.idpId` — the value `AppModel.setActiveProfile(idpId:)` takes.
    let id: Int
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// Reads the App-Group-backed `AppModel.shared.snapshot.profiles` — the SAME data the in-app profile
/// switcher UI already consumes (`Models.swift:198`). No BLE read at picker-render time.
struct ProfileEntityQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [ProfileEntity] {
        let profiles = await AppModel.shared?.snapshot.profiles ?? []
        return profiles.filter { identifiers.contains($0.idpId) }
            .map { ProfileEntity(id: $0.idpId, name: $0.name) }
    }

    func suggestedEntities() async throws -> [ProfileEntity] {
        let profiles = await AppModel.shared?.snapshot.profiles ?? []
        return profiles.map { ProfileEntity(id: $0.idpId, name: $0.name) }
    }
}
