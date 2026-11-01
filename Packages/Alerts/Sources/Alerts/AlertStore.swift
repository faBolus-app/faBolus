import Foundation
import faBolusCore
import os

let alertsLog = Logger(subsystem: "com.fabolus.app", category: "alerts")

/// Where the alert pipeline keeps what must survive a relaunch: the engine's state and the user's policy.
public protocol AlertPersisting: Sendable {
    func loadState() -> AlertEngine.State?
    func saveState(_ state: AlertEngine.State) throws
    func loadPolicy() -> AlertPolicy?
    func savePolicy(_ policy: AlertPolicy) throws
}

/// The state and the policy as two JSON files in the App Group, beside the bolus ledger.
public struct FileAlertStore: AlertPersisting {
    public let stateURL: URL
    public let policyURL: URL

    public init(directory: URL) {
        stateURL = directory.appendingPathComponent("alert-state.json")
        policyURL = directory.appendingPathComponent("alert-policy.json")
    }

    /// The App Group container, or Application Support when there is none (a test host).
    public static func defaultDirectory(appGroupID: String?) -> URL? {
        if let appGroupID,
            let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        {
            return group
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// Readable after the first unlock, like the ledger: a background relaunch before then must still be
    /// able to read what it owes the OS.
    static let writing: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    public func loadState() -> AlertEngine.State? { load(stateURL) }
    public func saveState(_ state: AlertEngine.State) throws { try save(state, to: stateURL) }
    public func loadPolicy() -> AlertPolicy? { load(policyURL) }
    public func savePolicy(_ policy: AlertPolicy) throws { try save(policy, to: policyURL) }

    private func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            alertsLog.error("\(url.lastPathComponent, privacy: .public) unreadable: \(String(describing: error))")
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: Self.writing)
    }
}
