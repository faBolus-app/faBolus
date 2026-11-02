import Foundation
import RemoteProtocol
import os

/// Where the host keeps the watch's last few dismiss results, so a copy of a clear that reaches a relaunched
/// phone gets the answer the first one did. Re-resolving it instead would clear the alert again if the pump
/// had raised it since: a pump alert is a bit, so the new one has the same ID.
public protocol DismissResultPersisting: Sendable {
    func load() -> [DismissResultPayload]
    func save(_ results: [DismissResultPayload]) throws
}

/// The results in a JSON file beside the ledger.
public struct FileDismissResultStore: DismissResultPersisting {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func url(in directory: URL) -> URL { directory.appendingPathComponent("watch-dismiss-results.json") }

    private struct Stored: Codable {
        let requestId: String
        let alertId: String
        let result: String
    }

    /// A missing or unreadable file is no results: the worst a lost one costs is the clear being judged
    /// again, as before results were kept.
    public func load() -> [DismissResultPayload] {
        guard let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode([Stored].self, from: data)
        else { return [] }
        return stored.compactMap { s in
            DismissResultToken(rawValue: s.result).map {
                DismissResultPayload(requestId: s.requestId, alertId: s.alertId, result: $0)
            }
        }
    }

    public func save(_ results: [DismissResultPayload]) throws {
        let stored = results.map { Stored(requestId: $0.requestId, alertId: $0.alertId, result: $0.result.rawValue) }
        try JSONEncoder().encode(stored).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

let hostLog = Logger(subsystem: "com.fabolus.app", category: "remote")
