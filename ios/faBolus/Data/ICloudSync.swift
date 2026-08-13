import Foundation
import faBolusCore

/// Optional automatic iCloud sync of the **app settings** across a user's devices, via their private
/// iCloud key-value store (never our servers).
///
/// **Compiled-in only on a paid build (default OFF).** iCloud needs a paid Apple Developer account + the
/// iCloud capability, which would break the free-account build the project is designed around. So it is
/// gated behind the `FABOLUS_ICLOUD` compile flag: `scripts/generate-project.sh` strips the entitlement
/// AND the flag unless `FABOLUS_ICLOUD=1`, so an unmodified clone signs and builds with the `#else` no-op
/// stub. There is **no runtime user toggle** (owner decision 2026-08-06): when compiled in, sync is
/// AUTOMATIC whenever iCloud is available and silently falls back to local-only when the user is signed
/// out of iCloud / the entitlement is absent (guarded on `ubiquityIdentityToken` — never crashes, never
/// blocks settings).
///
/// **Settings-only, off the command path (C5).** Only the iCloud-SAFE subset syncs —
/// `SettingsCatalog.iCloudSyncedKeys`, which EXCLUDES the five command-adjacent flags (phone/remotes
/// read-only, child mode, advanced-control opt-in, remote-approval), the three device-local
/// ambient-surface flags (`liveActivityEnabled`, `liveActivityFields`, `glucoseBadgeEnabled` — opting into
/// an always-on-screen surface is a per-device choice, not one to silently propagate), and every
/// non-backed / device-specific key. So a synced blob can never flip a safety/command decision on another
/// device. Pump settings + secrets are NEVER auto-synced (file-only). The mode selector (`appMode`) is not
/// a catalog row, so it never syncs either — a cloud pull cannot unlock a mode on another device.

#if FABOLUS_ICLOUD
@MainActor
final class ICloudSettingsSync {
    static let shared = ICloudSettingsSync()
    private let store = NSUbiquitousKeyValueStore.default
    private let key = "appSettingsBackup"

    /// iCloud reachable for this user right now (signed in + entitlement present). When false, every
    /// operation degrades to local-only, silently.
    private var iCloudAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

    /// Keep only the iCloud-safe keys (C5): backed-up app-settings keys that are not command-adjacent.
    private func safe(_ dict: [String: BackupValue]) -> [String: BackupValue] {
        dict.filter { SettingsCatalog.iCloudSyncedKeys.contains($0.key) }
    }

    func start() {
        guard iCloudAvailable else { return }   // signed out / no entitlement → local-only, silent
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { [weak self] _ in
            // The observer body is nonisolated; hop to the main actor explicitly (a settings pull isn't
            // latency-critical, and an explicit hop avoids an executor assertion the stricter CI
            // concurrency runtime traps on — the P9 lesson).
            Task { @MainActor in self?.pull() }
        }
        store.synchronize()
        pull()   // adopt any cloud values on launch
    }

    /// Push the current (iCloud-safe) app settings to iCloud (call when the app backgrounds).
    func push() {
        guard iCloudAvailable else { return }
        guard let data = try? JSONEncoder().encode(safe(SettingsBackup.appSettingsSnapshot())) else { return }
        store.set(data, forKey: key)
        store.synchronize()
    }

    private func pull() {
        guard iCloudAvailable else { return }
        guard let data = store.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: BackupValue].self, from: data) else { return }
        // Defense-in-depth: apply only the safe subset even if an older build pushed a wider blob, so a
        // stale cloud value can never flip a command-adjacent flag here.
        SettingsBackup.applyAppSettings(safe(dict))
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
