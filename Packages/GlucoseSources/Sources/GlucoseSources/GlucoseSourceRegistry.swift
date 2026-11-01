import DexcomBLE
import DexcomG6
import DexcomG7
import Foundation
import faBolusCore

/// The backup CGM sources this build can run, and the one selected in settings. One source runs at a
/// time (owner, 2026-10-31). Each Bluetooth source has its own central and restore identifier, never
/// the pump's (`com.fabolus.app.pump`).
public struct GlucoseSourceRegistry: Sendable {
    public static let shareID = DexcomShareSource.id
    public static let g6ID = "dexcom-g6"
    public static let g7ID = "dexcom-g7"

    /// Fixed strings, so CoreBluetooth can restore the source's central after a relaunch.
    public static let g6RestoreIdentifier = "com.fabolus.app.cgm.dexcom-g6"
    public static let g7RestoreIdentifier = "com.fabolus.app.cgm.dexcom-g7"

    public let settings: GlucoseSourceSettings
    public let account: ShareAccount

    public init(
        settings: GlucoseSourceSettings = GlucoseSourceSettings(),
        secrets: any SecretStore = KeychainSecretStore.cgmCredentials
    ) {
        self.settings = settings
        self.account = ShareAccount(settings: settings, secrets: secrets)
    }

    public var descriptors: [GlucoseSourceDescriptor] {
        let settings = settings
        let account = account
        return [
            GlucoseSourceDescriptor(id: Self.shareID, name: "Dexcom Share (cloud)", sensors: ["Dexcom G6", "Dexcom G7"])
            {
                _ in DexcomShareSource.make(account: account)
            },
            GlucoseSourceDescriptor(
                id: Self.g6ID, name: "Dexcom G6 (direct Bluetooth)", sensors: ["Dexcom G6", "Dexcom G5", "Dexcom ONE"]
            ) { restore in
                DexcomBLESource(
                    id: Self.g6ID,
                    observer: G6Observer(
                        transmitterID: settings.g6TransmitterID, peripheralID: settings.uuid(.g6Peripheral),
                        activationDate: settings.date(.g6Activation)),
                    makeTransport: {
                        DexcomCentral(restoreIdentifier: restore ? Self.g6RestoreIdentifier : nil, emit: $0)
                    },
                    remember: { memory in
                        settings.set(memory.peripheralID?.uuidString, .g6Peripheral)
                        settings.set(memory.activationDate, .g6Activation)
                    })
            },
            GlucoseSourceDescriptor(
                id: Self.g7ID, name: "Dexcom G7 (direct Bluetooth)", sensors: ["Dexcom G7", "Dexcom ONE+"]
            ) { restore in
                DexcomBLESource(
                    id: Self.g7ID,
                    observer: G7Observer(
                        sensorName: settings.string(.g7SensorName), peripheralID: settings.uuid(.g7Peripheral)),
                    makeTransport: {
                        DexcomCentral(restoreIdentifier: restore ? Self.g7RestoreIdentifier : nil, emit: $0)
                    },
                    remember: { memory in
                        settings.set(memory.sensorName, .g7SensorName)
                        settings.set(memory.peripheralID?.uuidString, .g7Peripheral)
                    })
            }
        ]
    }

    public func descriptor(id: String) -> GlucoseSourceDescriptor? { descriptors.first { $0.id == id } }

    /// The selected source's id, or `nil` for the pump's glucose only.
    public var selectedID: String? { settings.string(.selectedSource) }

    /// Selects a source (`nil` for none). A newly selected source starts fresh: the crash-loop
    /// bookkeeping belonged to the one before it.
    public func select(_ id: String?) {
        settings.set(id, .selectedSource)
        settings.set(false, .cleanShutdown)
        settings.set(nil as Data?, .recoveryState)
    }

    public var selected: GlucoseSourceDescriptor? { selectedID.flatMap(descriptor(id:)) }

    /// Builds the selected source: the one long-lived production instance, with state restoration.
    /// Build it once per process; a second Bluetooth central with the same restore identifier runs
    /// without restoration.
    public func makeSelected() -> (any GlucoseSource)? { selected?.make(true) }

    /// Builds a source without state restoration.
    public func make(id: String) -> (any GlucoseSource)? { descriptor(id: id)?.make(false) }

    /// Saves the G6 transmitter ID typed in settings, or clears it with `nil` or an empty string.
    /// Returns the saved ID, or throws when the text isn't a transmitter ID.
    @discardableResult
    public func setG6TransmitterID(_ text: String?) throws -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            settings.set(nil as String?, .g6TransmitterID)
            return nil
        }
        guard let id = G6TransmitterID.normalized(trimmed) else { throw TransmitterIDError.invalid }
        settings.set(id, .g6TransmitterID)
        return id
    }

    public enum TransmitterIDError: Error, Equatable {
        /// Not six letters and digits.
        case invalid
    }

    // MARK: - Crash-loop recovery

    /// Called once at launch, before starting the selected source: whether to start it this launch
    /// (see `GlucoseSourceRecoveryPolicy`). Clears the clean-shutdown marker for this run.
    public func shouldStartSelected(now: Date = Date()) -> Bool {
        let wasClean = settings.bool(.cleanShutdown)
        settings.set(false, .cleanShutdown)
        let (next, shouldStart) = GlucoseSourceRecoveryPolicy.decide(recoveryState, wasClean: wasClean, now: now)
        settings.set(try? JSONEncoder().encode(next), .recoveryState)
        return shouldStart
    }

    /// Called after an orderly stop of the selected source, so the next launch counts as clean.
    public func markCleanShutdown() {
        settings.set(true, .cleanShutdown)
    }

    /// Non-`nil` while the selected source is held off after repeated unclean starts.
    public var disabledUntil: Date? { recoveryState.disabledUntil }

    var recoveryState: GlucoseSourceRecoveryState {
        settings.data(.recoveryState).flatMap { try? JSONDecoder().decode(GlucoseSourceRecoveryState.self, from: $0) }
            ?? GlucoseSourceRecoveryState()
    }
}
