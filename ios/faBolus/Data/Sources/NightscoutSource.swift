import Foundation
import faBolusCore

/// Nightscout follower — the universal fallback. Polls `/api/v1/entries.json` on a site the user
/// already feeds (from any uploader). Config: `nightscout.url` (UserDefaults) + optional
/// `nightscout.token` (Keychain). Read-only.
@MainActor
final class NightscoutSource: PollingGlucoseSource {
    init() { super.init(id: "nightscout", priority: 30) }

    private struct Entry: Decodable { let sgv: Int?; let date: Double?; let direction: String? }

    override func poll() async throws -> [GlucoseSample] {
        guard let base = GlucoseSourceConfig.string("nightscout.url") else {
            throw SourceError.needsSetup("Nightscout")
        }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        var comps = URLComponents(string: root + "/api/v1/entries.json")!
        var items = [URLQueryItem(name: "count", value: "48")]
        if let token = CredentialStore.get(account: "nightscout.token") {
            items.append(URLQueryItem(name: "token", value: token))
        }
        comps.queryItems = items

        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse else { throw SourceError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw SourceError.http(http.statusCode) }

        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return entries.compactMap { e in
            guard let sgv = e.sgv, sgv > 0, let ms = e.date else { return nil }
            return GlucoseSample(mgdl: sgv, date: Date(timeIntervalSince1970: ms / 1000),
                                 trend: CgmTrend.nightscout(e.direction), sourceID: id)
        }
    }
}
