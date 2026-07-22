import Foundation
import faBolusCore

/// Optional automatic iCloud sync of the **app settings** across a user's devices, via their private
/// iCloud key-value store (never our servers). Off by default: iCloud needs a **paid** Apple Developer
/// account + the iCloud capability, which would break the free-account build the project is designed
/// around — so it's opt-in exactly like HealthKit. A self-compiler on the paid program uncomments the
/// `com.apple.developer.ubiquity-kvstore-identifier` entitlement (see project.yml) and adds `ICLOUD_SYNC`
/// to `SWIFT_ACTIVE_COMPILATION_CONDITIONS`. Pump settings + secrets are NOT auto-synced (file-only).

#if ICLOUD_SYNC
@MainActor
final class ICloudSettingsSync {
    static let shared = ICloudSettingsSync()
    private let store = NSUbiquitousKeyValueStore.default
    private let key = "appSettingsBackup"

    func start() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { [weak self] _ in self?.pull() }
        store.synchronize()
        pull()   // adopt any cloud values on launch
    }

    /// Push the current app settings to iCloud (call when the app backgrounds).
    func push() {
        guard let data = try? JSONEncoder().encode(SettingsBackup.appSettingsSnapshot()) else { return }
        store.set(data, forKey: key)
        store.synchronize()
    }

    private func pull() {
        guard let data = store.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: BackupValue].self, from: data) else { return }
        SettingsBackup.applyAppSettings(dict)
    }
}
#else
/// No-op when built without iCloud (the default, free-account build).
@MainActor
final class ICloudSettingsSync {
    static let shared = ICloudSettingsSync()
    func start() {}
    func push() {}
}
#endif
