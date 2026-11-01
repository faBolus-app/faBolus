import Foundation
import Security
import os

let appLog = Logger(subsystem: "com.fabolus.app", category: "app")

/// The new app's first launch over the old one (D3). The bundle ID is the old app's, so the old app's
/// settings, App Group files and Keychain items are still there; nothing of them is migrated. On the first
/// launch, before anything is built, they are removed, and the launch says so, so the alert pipeline also
/// withdraws whatever the old app left scheduled.
///
/// The one file kept is this app's own ledger, should it somehow exist: the old app's is a different file
/// (`remote-bolus-ledger.json`), so one named `bolus-ledger.json` was written by this app, and an unknown
/// outcome in it must keep blocking (R2) rather than vanish in a wipe.
public struct FirstLaunchWipe {
    /// Set once the wipe has run. Kept in the standard defaults, after their old contents are removed.
    public static let doneKey = "fabolus.firstLaunchWipe.v2"
    public static let keptFiles: Set<String> = ["bolus-ledger.json"]

    let standard: UserDefaults
    /// The standard defaults' domain (the bundle ID).
    let standardDomain: String?
    let appGroup: UserDefaults?
    let appGroupID: String?
    let appGroupDirectory: URL?
    /// Removes every Keychain item the app can reach.
    let clearKeychain: () -> Void

    public init(
        standard: UserDefaults = .standard, standardDomain: String? = Bundle.main.bundleIdentifier,
        appGroupID: String?, appGroupDirectory: URL?,
        clearKeychain: @escaping () -> Void = FirstLaunchWipe.clearAppKeychain
    ) {
        self.standard = standard
        self.standardDomain = standardDomain
        self.appGroupID = appGroupID
        self.appGroup = appGroupID.flatMap(UserDefaults.init(suiteName:))
        self.appGroupDirectory = appGroupDirectory
        self.clearKeychain = clearKeychain
    }

    public var isNeeded: Bool { !standard.bool(forKey: Self.doneKey) }

    /// Runs the wipe when this is the first launch. Returns whether it ran.
    @discardableResult
    public func runIfNeeded() -> Bool {
        guard isNeeded else { return false }
        if let standardDomain { standard.removePersistentDomain(forName: standardDomain) }
        if let appGroupID { appGroup?.removePersistentDomain(forName: appGroupID) }
        if let appGroupDirectory { removeFiles(in: appGroupDirectory) }
        clearKeychain()
        standard.set(true, forKey: Self.doneKey)
        appLog.notice("first launch: the earlier app's data was removed")
        return true
    }

    private func removeFiles(in directory: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items where !Self.keptFiles.contains(item.lastPathComponent) {
            // The system's own folders in a group container (Library) hold the old app's caches and
            // preferences too; they are recreated as needed.
            do { try fm.removeItem(at: item) } catch {
                appLog.error("first launch: \(item.lastPathComponent, privacy: .public) not removed: \(error)")
            }
        }
    }

    /// Every password and key item in the app's Keychain, synchronizable or not: the old app's pump
    /// pairing, CGM credentials and remote passcodes, whatever service each used.
    public static func clearAppKeychain() {
        for cls in [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassKey] {
            SecItemDelete(
                [kSecClass as String: cls, kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
                    as CFDictionary)
        }
    }
}
